defmodule SymphonyElixir.Tracker.EconomicOS do
  @moduledoc """
  Thin tracker adapter for agent analysis and human-input quality agendas
  owned by Economic OS.

  The adapter reads and claims work. Codex can submit only the current agenda's
  cited analysis through Symphony's bounded dynamic tool; Economic OS remains
  the owner and validator of business state and results.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @resource_path "/api/admin/revenue_management_agendas"
  @run_start_path "/api/internal/economic-os/agent-runs:start"
  @run_finish_path "/api/internal/economic-os/agent-runs:finish"
  @active_statuses ~w(open in_progress)
  @page_limit 200
  @max_agendas 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, agendas} <- fetch_agendas() do
      {:ok, agendas |> Enum.filter(&candidate?/1) |> to_issues()}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    wanted = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()

    with {:ok, agendas} <- fetch_agendas() do
      {:ok,
       agendas
       |> to_issues()
       |> Enum.filter(&MapSet.member?(wanted, normalize_state(&1.state)))}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted = MapSet.new(issue_ids)

    with {:ok, agendas} <- fetch_agendas() do
      {:ok,
       agendas
       |> to_issues()
       |> Enum.filter(&MapSet.member?(wanted, &1.id))}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    request(:patch, "/#{issue_id}", %{response: body})
  end

  @spec submit_analysis(String.t(), String.t(), map(), String.t()) :: :ok | {:error, term()}
  def submit_analysis(issue_id, response, response_data, outcome)
      when is_binary(issue_id) and is_binary(response) and is_map(response_data) do
    response_data = canonicalize_manager_review(response_data)
    values = %{response: response, response_data: response_data}
    idempotency_key = submission_idempotency_key(issue_id, values, outcome)

    with :ok <- validate_manager_review_binding(response_data) do
      case outcome do
        "answered" ->
          request(
            :post,
            "/#{issue_id}:transition",
            %{transition: "answer", context: %{}, values: values},
            idempotency_key: idempotency_key
          )

        "needs_revision" ->
          request(:patch, "/#{issue_id}", values, idempotency_key: idempotency_key)

        _ ->
          {:error, :invalid_analysis_outcome}
      end
    end
  end

  @spec record_agent_run_start(String.t(), map()) :: :ok | {:error, term()}
  def record_agent_run_start(issue_id, attributes)
      when is_binary(issue_id) and is_map(attributes) do
    with {:ok, agenda_id} <- agenda_id(issue_id),
         {:ok, run_key} <- required_binary(attributes, :run_key),
         {:ok, started_at} <- required_datetime(attributes, :started_at),
         {:ok, attempt} <- required_positive_integer(attributes, :attempt) do
      request_path(
        :post,
        @run_start_path,
        %{
          run_key: run_key,
          agenda_id: agenda_id,
          attempt: attempt,
          started_at: DateTime.to_iso8601(started_at)
        },
        idempotency_key: "symphony:agent-run:#{run_key}:start"
      )
    end
  end

  @spec record_agent_run_finish(String.t(), map()) :: :ok | {:error, term()}
  def record_agent_run_finish(issue_id, attributes)
      when is_binary(issue_id) and is_map(attributes) do
    with {:ok, agenda_id} <- agenda_id(issue_id),
         {:ok, run_key} <- required_binary(attributes, :run_key),
         {:ok, started_at} <- required_datetime(attributes, :started_at),
         {:ok, finished_at} <- required_datetime(attributes, :finished_at),
         {:ok, attempt} <- required_positive_integer(attributes, :attempt),
         {:ok, duration_ms} <- required_non_negative_integer(attributes, :duration_ms),
         {:ok, status} <- terminal_status(attributes[:status]) do
      payload =
        attributes
        |> Map.take([
          :thread_id,
          :session_id,
          :input_tokens,
          :output_tokens,
          :total_tokens,
          :turn_count,
          :outcome,
          :summary,
          :diagnostic,
          :evidence_refs
        ])
        |> Map.merge(%{
          run_key: run_key,
          agenda_id: agenda_id,
          attempt: attempt,
          started_at: DateTime.to_iso8601(started_at),
          finished_at: DateTime.to_iso8601(finished_at),
          duration_ms: duration_ms,
          status: status
        })

      request_path(
        :post,
        @run_finish_path,
        payload,
        idempotency_key: "symphony:agent-run:#{run_key}:finish"
      )
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, new_state) do
    case normalize_state(new_state) do
      "in progress" ->
        request(:post, "/#{issue_id}:transition", %{
          transition: "claim",
          context: %{},
          values: %{}
        })

      _ ->
        :ok
    end
  end

  @doc false
  @spec normalize_agenda_for_test(map()) :: Issue.t()
  def normalize_agenda_for_test(agenda), do: to_issue(agenda)

  defp fetch_agendas, do: fetch_agendas(0, [])

  defp fetch_agendas(offset, agendas) do
    limit = min(@page_limit, @max_agendas - length(agendas))

    case request(:get, "", nil, params: [limit: limit, offset: offset, sort: "due_date,id"]) do
      {:ok, body} when is_map(body) ->
        page = field(body, "data") || []
        combined = agendas ++ page
        has_more? = field(field(body, "meta") || %{}, "has_more") == true

        if has_more? and page != [] and length(combined) < @max_agendas do
          fetch_agendas(offset + length(page), combined)
        else
          {:ok, combined}
        end

      other ->
        other
    end
  end

  defp to_issues(agendas), do: Enum.map(agendas, &to_issue/1)

  defp to_issue(agenda) do
    id = to_string(field(agenda, "id"))

    %Issue{
      id: id,
      identifier: "EOS-AGENDA-#{id}",
      title: field(agenda, "title"),
      description: agenda_description(agenda),
      priority: priority(agenda),
      state: issue_state(agenda),
      branch_name: "symphony/agenda-#{id}",
      url: endpoint() <> @resource_path <> "/#{id}",
      labels: agenda_labels(agenda),
      assigned_to_worker: true
    }
  end

  defp agenda_description(agenda) do
    Jason.encode!(
      %{
        agenda_key: field(agenda, "agenda_key"),
        period: [field(agenda, "period_start"), field(agenda, "period_end")],
        due_date: field(agenda, "due_date"),
        items: field(agenda, "items") || [],
        evidence: field(agenda, "evidence") || %{},
        manager_response: field(agenda, "response"),
        response_data: field(agenda, "response_data") || %{},
        source_freshness: field(agenda, "source_freshness") || %{},
        agent_preparation_status: field(agenda, "agent_preparation_status"),
        agent_preparation: field(agenda, "agent_preparation") || %{},
        completion: completion_instruction(agenda)
      },
      pretty: true
    )
  end

  defp issue_state(agenda) do
    status = field(agenda, "status")

    cond do
      status in @active_statuses and not candidate?(agenda) -> "Done"
      status == "open" -> "Todo"
      status == "in_progress" -> "In Progress"
      status == "waived" -> "Cancelled"
      true -> "Done"
    end
  end

  defp candidate?(agenda) do
    field(agenda, "status") in @active_statuses and
      (agent_review_ready?(agenda) or manager_input_ready?(agenda))
  end

  defp agent_review_ready?(agenda) do
    field(agenda, "execution_mode") == "agent_review" and
      field(agenda, "agent_preparation_status") == "prepared"
  end

  defp manager_input_ready?(agenda) do
    response_data = field(agenda, "response_data") || %{}
    manager_input = field(response_data, "_manager_input") || %{}
    manager_review = field(response_data, "_manager_review") || %{}
    input_digest = field(manager_input, "digest")

    field(agenda, "execution_mode") == "human_review" and
      is_binary(input_digest) and input_digest != "" and
      field(manager_review, "input_digest") != input_digest
  end

  defp agenda_labels(agenda) do
    base = ["economic-os", to_string(field(agenda, "cadence"))]
    if field(agenda, "execution_mode") == "human_review", do: base ++ ["human-input-review"], else: base
  end

  defp completion_instruction(agenda) do
    if field(agenda, "execution_mode") == "human_review" do
      "Critically review the new raw manager input against cited evidence, prior context and every material response contract. Structure only facts and commitments the human actually supplied; do not invent or silently rewrite them. Set _manager_review.input_digest exactly equal to _manager_input.digest. Submit answered only with accepted quality evidence. Otherwise leave needs_revision open with _manager_review.status=needs_revision and exactly one highest-leverage collegial follow_up_question."
    else
      "Submit the cited response and structured response_data once through economic_os_submit_analysis with outcome=answered."
    end
  end

  defp priority(agenda) do
    if field(agenda, "due_date") < Date.to_iso8601(Date.utc_today()), do: 1, else: 2
  end

  defp request(method, suffix, body, opts \\ []) do
    request_path(method, @resource_path <> suffix, body, opts)
  end

  defp request_path(method, path, body, opts) do
    request_options = [
      method: method,
      url: endpoint() <> path,
      headers: headers(Keyword.get(opts, :idempotency_key)),
      params: Keyword.get(opts, :params, [])
    ]

    request_options = if is_nil(body), do: request_options, else: request_options ++ [json: body]

    request_fun =
      Application.get_env(:symphony_elixir, :economic_os_request_fun, &Req.request/1)

    case request_fun.(request_options) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        if method == :get, do: {:ok, response_body}, else: :ok

      {:ok, %{status: status}} ->
        {:error, {:economic_os_api_status, status}}

      {:error, reason} ->
        {:error, {:economic_os_api_request, reason}}
    end
  end

  defp endpoint, do: String.trim_trailing(Config.tracker_endpoint(), "/")

  defp headers(idempotency_key) do
    [
      {"authorization", "Bearer #{Config.tracker_api_token()}"},
      {"content-type", "application/json"}
    ]
    |> maybe_idempotency_header(idempotency_key)
    |> maybe_tenant_header(Config.tracker_tenant())
  end

  defp maybe_idempotency_header(headers, nil), do: headers

  defp maybe_idempotency_header(headers, idempotency_key),
    do: [{"idempotency-key", idempotency_key} | headers]

  defp maybe_tenant_header(headers, nil), do: headers
  defp maybe_tenant_header(headers, tenant), do: [{"x-mini-tenant", tenant} | headers]

  defp field(map, key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn {candidate, value} ->
        if to_string(candidate) == key, do: value
      end)
  end

  defp canonicalize_manager_review(response_data) do
    manager_review = field(response_data, "_manager_review")

    if is_map(manager_review) do
      canonical_digest =
        field(manager_review, "input_digest") || field(manager_review, "manager_input_digest")

      canonical_review =
        manager_review
        |> Map.delete("manager_input_digest")
        |> Map.delete(:manager_input_digest)
        |> Map.delete(:input_digest)
        |> maybe_put_input_digest(canonical_digest)

      response_data
      |> Map.delete(:_manager_review)
      |> Map.put("_manager_review", canonical_review)
    else
      response_data
    end
  end

  defp maybe_put_input_digest(manager_review, nil), do: manager_review

  defp maybe_put_input_digest(manager_review, digest),
    do: Map.put(manager_review, "input_digest", digest)

  defp validate_manager_review_binding(response_data) do
    manager_input = field(response_data, "_manager_input")

    if is_map(manager_input) do
      input_digest = field(manager_input, "digest")
      manager_review = field(response_data, "_manager_review") || %{}

      if is_binary(input_digest) and input_digest != "" and
           field(manager_review, "input_digest") != input_digest do
        {:error, {:invalid_manager_input_review, input_digest}}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp normalize_state(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp agenda_id(issue_id) do
    case Integer.parse(issue_id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_economic_os_agenda_id}
    end
  end

  defp required_binary(attributes, key) do
    case Map.get(attributes, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_agent_run_field, key}}
    end
  end

  defp required_datetime(attributes, key) do
    case Map.get(attributes, key) do
      %DateTime{} = value -> {:ok, value}
      _ -> {:error, {:invalid_agent_run_field, key}}
    end
  end

  defp required_positive_integer(attributes, key) do
    case Map.get(attributes, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_agent_run_field, key}}
    end
  end

  defp required_non_negative_integer(attributes, key) do
    case Map.get(attributes, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_agent_run_field, key}}
    end
  end

  defp terminal_status(value) when value in ["succeeded", "failed", "cancelled"],
    do: {:ok, value}

  defp terminal_status(_value), do: {:error, {:invalid_agent_run_field, :status}}

  defp submission_idempotency_key(issue_id, values, outcome) do
    digest =
      :sha256
      |> :crypto.hash(Jason.encode!(%{values: values, outcome: outcome}))
      |> Base.encode16(case: :lower)

    "symphony:agenda:#{issue_id}:submit:#{digest}"
  end
end
