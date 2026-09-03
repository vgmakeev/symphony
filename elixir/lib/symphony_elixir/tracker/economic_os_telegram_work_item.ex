defmodule SymphonyElixir.Tracker.EconomicOSTelegramWorkItem do
  @moduledoc """
  Tracker adapter for prepared Telegram work items owned by Economic OS.

  Work-item and recipient identities are server-bound. Symphony owns only one
  bounded Codex run and its retries; Mini owns lifecycle, delivery and human
  decisions.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @next_path "/api/internal/economic-os/telegram-work-items:next"
  @get_path "/api/internal/economic-os/telegram-work-items:get"
  @submit_path "/api/internal/economic-os/telegram-work-items:submit"
  @run_start_path "/api/internal/economic-os/telegram-work-item-runs:start"
  @run_finish_path "/api/internal/economic-os/telegram-work-item-runs:finish"

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, body} <- request(:post, @next_path, %{}),
         item <- response_work_item(body) do
      {:ok, if(is_map(item), do: [to_issue(item)], else: [])}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    wanted = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()

    with {:ok, issues} <- fetch_candidate_issues() do
      {:ok, Enum.filter(issues, &MapSet.member?(wanted, normalize_state(&1.state)))}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    issue_ids
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, issues} ->
      case fetch_issue_state(issue_id) do
        {:ok, nil} -> {:cont, {:ok, issues}}
        {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(_issue_id, _body), do: :ok

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(_issue_id, _state_name), do: :ok

  @spec submit_result(String.t(), map()) :: :ok | {:error, term()}
  def submit_result(issue_id, result) when is_binary(issue_id) and is_map(result) do
    with {:ok, id} <- work_item_id(issue_id),
         {:ok, _body} <-
           request(
             :post,
             @submit_path,
             %{work_item_id: id, result: result},
             idempotency_key: submission_idempotency_key(issue_id, result)
           ) do
      :ok
    end
  end

  @spec record_agent_run_start(String.t(), map()) :: :ok | {:error, term()}
  def record_agent_run_start(issue_id, attributes)
      when is_binary(issue_id) and is_map(attributes) do
    with {:ok, id} <- work_item_id(issue_id),
         {:ok, run_key} <- required_binary(attributes, :run_key),
         {:ok, attempt} <- required_positive_integer(attributes, :attempt),
         {:ok, _body} <-
           request(
             :post,
             @run_start_path,
             %{work_item_id: id, run_key: run_key, attempt: attempt},
             idempotency_key: "symphony:telegram-work-item-run:#{run_key}:start"
           ) do
      :ok
    end
  end

  @spec record_agent_run_finish(String.t(), map()) :: :ok | {:error, term()}
  def record_agent_run_finish(issue_id, attributes)
      when is_binary(issue_id) and is_map(attributes) do
    with {:ok, id} <- work_item_id(issue_id),
         {:ok, run_key} <- required_binary(attributes, :run_key),
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
          :diagnostic
        ])
        |> Map.merge(%{
          work_item_id: id,
          run_key: run_key,
          attempt: attempt,
          duration_ms: duration_ms,
          status: status
        })

      with {:ok, _body} <-
             request(
               :post,
               @run_finish_path,
               payload,
               idempotency_key: "symphony:telegram-work-item-run:#{run_key}:finish"
             ) do
        :ok
      end
    end
  end

  @doc false
  @spec normalize_work_item_for_test(map()) :: Issue.t()
  def normalize_work_item_for_test(item), do: to_issue(item)

  defp to_issue(item) do
    id = to_string(field(item, "id"))

    %Issue{
      id: id,
      identifier: field(item, "public_id") || "TELEGRAM-WORK-ITEM-#{id}",
      title: field(item, "title"),
      description: item_description(item),
      priority: 1,
      state: issue_state(field(item, "status")),
      branch_name: "symphony/telegram-work-item-#{id}",
      url: nil,
      labels: ["economic-os-telegram-work-item"],
      assigned_to_worker: true
    }
  end

  defp item_description(item) do
    Jason.encode!(
      %{
        public_id: field(item, "public_id"),
        goal: field(item, "goal"),
        capability_profile: field(item, "capability_profile"),
        bounded_context: field(item, "bounded_context") || %{},
        repository_manifest: field(item, "repository_manifest") || %{},
        manifest_digest: field(item, "manifest_digest"),
        human_response: field(item, "human_response"),
        completion: "Submit exactly one typed result through economic_os_submit_telegram_work_item. Work-item and recipient identities are bound by Symphony; never include them in tool arguments."
      },
      pretty: true
    )
  end

  defp issue_state(status) when status in ["running"], do: "Todo"
  defp issue_state(status) when status in ["queued", "preparing"], do: "Todo"
  defp issue_state("cancelled"), do: "Cancelled"
  defp issue_state(_status), do: "Done"

  defp fetch_issue_state(issue_id) do
    with {:ok, id} <- work_item_id(issue_id),
         {:ok, body} <- request(:post, @get_path, %{work_item_id: id}) do
      case response_work_item(body) do
        item when is_map(item) -> {:ok, to_issue(item)}
        _ -> {:ok, nil}
      end
    else
      {:error, {:economic_os_api_status, 404, _body}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, path, body, opts \\ []) do
    headers =
      [
        {"authorization", "Bearer #{Config.tracker_api_token()}"},
        {"content-type", "application/json"}
      ]
      |> maybe_idempotency_header(Keyword.get(opts, :idempotency_key))
      |> maybe_tenant_header(Config.tracker_tenant())

    request_fun =
      Application.get_env(:symphony_elixir, :economic_os_request_fun, &Req.request/1)

    case request_fun.(method: method, url: endpoint() <> path, headers: headers, json: body) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:economic_os_api_status, status, response_body}}

      {:ok, %{status: status}} ->
        {:error, {:economic_os_api_status, status}}

      {:error, reason} ->
        {:error, {:economic_os_api_request, reason}}
    end
  end

  defp response_work_item(body) do
    body
    |> field("data")
    |> case do
      nil -> field(body, "work_item")
      data -> field(data, "work_item")
    end
  end

  defp endpoint, do: String.trim_trailing(Config.tracker_endpoint(), "/")

  defp maybe_idempotency_header(headers, nil), do: headers

  defp maybe_idempotency_header(headers, idempotency_key),
    do: [{"idempotency-key", idempotency_key} | headers]

  defp maybe_tenant_header(headers, nil), do: headers
  defp maybe_tenant_header(headers, tenant), do: [{"x-mini-tenant", tenant} | headers]

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, fn {candidate, value} ->
        if to_string(candidate) == key, do: value
      end)
  end

  defp normalize_state(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp work_item_id(issue_id) do
    case Integer.parse(issue_id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_telegram_work_item_id}
    end
  end

  defp required_binary(attributes, key) do
    case Map.get(attributes, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
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

  defp submission_idempotency_key(issue_id, result) do
    digest =
      :sha256
      |> :crypto.hash(Jason.encode!(result))
      |> Base.encode16(case: :lower)

    "symphony:telegram-work-item:#{issue_id}:submit:#{digest}"
  end
end
