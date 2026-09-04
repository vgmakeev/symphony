defmodule SymphonyElixir.EconomicOSTrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.EconomicOS

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "economic_os",
      tracker_endpoint: "https://economic-os.example",
      tracker_api_token: "worker-token",
      tracker_tenant: "surf"
    )

    :ok
  end

  test "selects active agent agendas and new manager inputs awaiting review" do
    stub_agendas([
      agenda(1, "open"),
      agenda(2, "in_progress"),
      agenda(3, "answered"),
      agenda(7, "open", "pending"),
      human_input_agenda(4, "new-input", nil),
      human_input_agenda(5, "reviewed-input", "reviewed-input"),
      human_input_agenda(6, "newer-input", "old-input")
    ])

    assert Tracker.adapter() == EconomicOS
    assert {:ok, issues} = EconomicOS.fetch_candidate_issues()

    assert Enum.map(issues, &{&1.id, &1.state}) == [
             {"1", "Todo"},
             {"2", "In Progress"},
             {"4", "Todo"},
             {"6", "Todo"}
           ]

    assert hd(issues).identifier == "EOS-AGENDA-1"
    assert hd(issues).labels == ["economic-os", "weekly"]
    assert hd(issues).description =~ "economic_os_submit_analysis"
    assert hd(issues).description =~ "agent_preparation"
    human_issue = Enum.find(issues, &(&1.id == "4"))
    assert human_issue.labels == ["economic-os", "weekly", "human-input-review"]
    assert human_issue.description =~ "response_data"
    assert human_issue.description =~ "needs_revision"
    assert human_issue.description =~ "follow_up_question"
  end

  test "fetches terminal states and exact agenda ids without owning their state" do
    stub_agendas([agenda(1, "open"), agenda(2, "answered"), agenda(3, "waived")])

    assert {:ok, done} = EconomicOS.fetch_issues_by_states(["Done"])
    assert Enum.map(done, & &1.id) == ["2"]

    assert {:ok, selected} = EconomicOS.fetch_issue_states_by_ids(["3"])
    assert [%{state: "Cancelled"}] = selected
  end

  test "reports reviewed human input as terminal to the orchestrator" do
    stub_agendas([human_input_agenda(5, "reviewed-input", "reviewed-input")])

    assert {:ok, selected} = EconomicOS.fetch_issue_states_by_ids(["5"])
    assert [%{state: "Done"}] = selected
  end

  test "paginates agendas within the Economic OS page limit" do
    parent = self()

    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn options ->
      send(parent, {:request, options})
      offset = Keyword.get(options[:params], :offset, 0)

      case offset do
        0 ->
          {:ok,
           %{
             status: 200,
             body: %{"data" => [agenda(1, "open")], "meta" => %{"has_more" => true}}
           }}

        1 ->
          {:ok,
           %{
             status: 200,
             body: %{"data" => [agenda(2, "open")], "meta" => %{"has_more" => false}}
           }}
      end
    end)

    assert {:ok, issues} = EconomicOS.fetch_candidate_issues()
    assert Enum.map(issues, & &1.id) == ["1", "2"]

    assert_receive {:request, first}
    assert first[:params] == [limit: 200, offset: 0, sort: "due_date,id"]
    assert_receive {:request, second}
    assert second[:params] == [limit: 200, offset: 1, sort: "due_date,id"]
  end

  test "claims an agenda through its mini state machine" do
    parent = self()
    stub_request(parent)

    assert :ok = EconomicOS.update_issue_state("7", "In Progress")
    assert_receive {:request, options}
    assert options[:method] == :post
    assert options[:url] =~ "/revenue_management_agendas/7:transition"
    assert options[:json].transition == "claim"
    assert {"authorization", "Bearer worker-token"} in options[:headers]
    assert {"x-mini-tenant", "surf"} in options[:headers]

    assert :ok = EconomicOS.update_issue_state("7", "Review")
    refute_receive {:request, _options}
  end

  test "stores a tracker comment only as an agenda response" do
    parent = self()
    stub_request(parent)

    assert :ok = EconomicOS.create_comment("7", "Cited result")
    assert_receive {:request, options}
    assert options[:method] == :patch
    assert options[:json] == %{response: "Cited result"}
  end

  test "submits an answered analysis atomically through the agenda transition" do
    parent = self()
    stub_request(parent)
    response_data = %{"_answer_quality_review" => %{"status" => "accepted"}}

    assert :ok = EconomicOS.submit_analysis("7", "Cited result", response_data, "answered")
    assert_receive {:request, options}
    assert options[:method] == :post
    assert options[:url] =~ "/revenue_management_agendas/7:transition"
    assert options[:json].transition == "answer"
    assert options[:json].values == %{response: "Cited result", response_data: response_data}

    assert {"idempotency-key", "symphony:agenda:7:submit:" <> digest} =
             Enum.find(options[:headers], fn {name, _value} -> name == "idempotency-key" end)

    assert byte_size(digest) == 64
  end

  test "records needs revision without closing the agenda" do
    parent = self()
    stub_request(parent)
    response_data = %{"_quality_review" => %{"status" => "needs_revision"}}

    assert :ok = EconomicOS.submit_analysis("8", "One concrete gap", response_data, "needs_revision")
    assert_receive {:request, options}
    assert options[:method] == :post
    assert options[:url] =~ "/revenue_management_agendas/8:transition"
    assert options[:json].transition == "reopen"

    assert options[:json].values == %{
             response: "One concrete gap",
             response_data: response_data
           }
  end

  test "retains Economic OS error details for a rejected analysis" do
    response_body = %{
      "detail" => "Management agenda response is incomplete: portfolio: response is required"
    }

    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn _options ->
      {:ok, %{status: 422, body: response_body}}
    end)

    assert {:error, {:economic_os_api_status, 422, ^response_body}} =
             EconomicOS.submit_analysis("7", "Cited result", %{}, "answered")
  end

  test "canonicalizes the reviewed manager input digest before submission" do
    parent = self()
    stub_request(parent)

    response_data = %{
      "_manager_input" => %{"digest" => "current-input"},
      "_manager_review" => %{
        "status" => "needs_revision",
        "manager_input_digest" => "current-input"
      }
    }

    assert :ok =
             EconomicOS.submit_analysis(
               "8",
               "One concrete gap",
               response_data,
               "needs_revision"
             )

    assert_receive {:request, options}
    review = options[:json].values.response_data["_manager_review"]
    assert review["input_digest"] == "current-input"
    refute Map.has_key?(review, "manager_input_digest")
  end

  test "rejects a manager review bound to a stale input" do
    parent = self()
    stub_request(parent)

    response_data = %{
      "_manager_input" => %{"digest" => "current-input"},
      "_manager_review" => %{
        "status" => "needs_revision",
        "input_digest" => "old-input"
      }
    }

    assert {:error, {:invalid_manager_input_review, "current-input"}} =
             EconomicOS.submit_analysis(
               "8",
               "One concrete gap",
               response_data,
               "needs_revision"
             )

    refute_receive {:request, _options}
  end

  test "records an idempotent agent run start through the bounded internal contract" do
    parent = self()
    stub_request(parent)
    started_at = ~U[2026-08-29 10:00:00Z]

    assert :ok =
             EconomicOS.record_agent_run_start("7", %{
               run_key: "run-0123456789abcdef",
               attempt: 1,
               started_at: started_at
             })

    assert_receive {:request, options}
    assert options[:method] == :post
    assert options[:url] =~ "/api/internal/economic-os/agent-runs:start"

    assert options[:json] == %{
             run_key: "run-0123456789abcdef",
             agenda_id: 7,
             attempt: 1,
             started_at: "2026-08-29T10:00:00Z"
           }

    assert {"idempotency-key", "symphony:agent-run:run-0123456789abcdef:start"} in options[:headers]
  end

  test "records terminal telemetry without forwarding private log payloads" do
    parent = self()
    stub_request(parent)

    assert :ok =
             EconomicOS.record_agent_run_finish("7", %{
               run_key: "run-0123456789abcdef",
               attempt: 1,
               started_at: ~U[2026-08-29 10:00:00Z],
               finished_at: ~U[2026-08-29 10:00:12Z],
               duration_ms: 12_000,
               status: "succeeded",
               thread_id: "thread-1",
               session_id: "thread-1-turn-2",
               input_tokens: nil,
               output_tokens: nil,
               total_tokens: nil,
               turn_count: 2,
               outcome: "completed",
               summary: "Agent task completed",
               diagnostic: nil,
               evidence_refs: %{symphony_issue_identifier: "EOS-AGENDA-7"},
               prompt: "must not cross the boundary",
               stdout: "must not cross the boundary",
               provider_payload: %{secret: true}
             })

    assert_receive {:request, options}
    assert options[:url] =~ "/api/internal/economic-os/agent-runs:finish"
    refute Map.has_key?(options[:json], :prompt)
    refute Map.has_key?(options[:json], :stdout)
    refute Map.has_key?(options[:json], :provider_payload)
    assert options[:json].agenda_id == 7
    assert options[:json].input_tokens == nil
    assert options[:json].turn_count == 2

    assert {"idempotency-key", "symphony:agent-run:run-0123456789abcdef:finish"} in options[:headers]
  end

  test "validates the dedicated Economic OS token" do
    assert Config.validate!() == :ok

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "economic_os",
      tracker_endpoint: "https://economic-os.example",
      tracker_api_token: nil
    )

    assert Config.validate!() == {:error, :missing_economic_os_api_token}
  end

  defp stub_agendas(agendas) do
    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn options ->
      refute Keyword.has_key?(options[:params], :execution_mode)
      {:ok, %{status: 200, body: %{"data" => agendas}}}
    end)
  end

  defp stub_request(parent) do
    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn options ->
      send(parent, {:request, options})
      {:ok, %{status: 200, body: %{}}}
    end)
  end

  defp agenda(id, status, preparation_status \\ "prepared") do
    %{
      "id" => id,
      "agenda_key" => "weekly:2099-01-05:agent_review:not_required:none",
      "cadence" => "weekly",
      "period_start" => "2099-01-05",
      "period_end" => "2099-01-11",
      "execution_mode" => "agent_review",
      "title" => "Weekly Codex analysis agenda",
      "status" => status,
      "due_date" => "2099-01-06",
      "items" => [%{"code" => "portfolio_anomalies"}],
      "evidence" => %{},
      "source_freshness" => %{},
      "agent_preparation_status" => preparation_status,
      "agent_preparation" => %{"repositories" => []}
    }
  end

  defp human_input_agenda(id, input_digest, reviewed_digest) do
    agenda(id, "open")
    |> Map.put("execution_mode", "human_review")
    |> Map.put("response_data", %{
      "_manager_input" => %{"digest" => input_digest, "comments" => []},
      "_manager_review" => %{"input_digest" => reviewed_digest}
    })
  end
end
