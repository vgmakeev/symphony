defmodule SymphonyElixir.EconomicOSTelegramWorkItemTrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Tracker.EconomicOSTelegramWorkItem

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "economic_os_telegram_work_item",
      tracker_endpoint: "https://economic-os.example",
      tracker_api_token: "telegram-worker-token",
      tracker_tenant: "surf"
    )

    :ok
  end

  test "selects only the bounded prepared work-item projection" do
    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn options ->
      assert options[:url] =~ "/telegram-work-items:next"
      {:ok, %{status: 200, body: %{"data" => %{"work_item" => work_item()}}}}
    end)

    assert Tracker.adapter() == EconomicOSTelegramWorkItem
    assert {:ok, [issue]} = EconomicOSTelegramWorkItem.fetch_candidate_issues()
    assert issue.id == "7"
    assert issue.identifier == "T-7ABCD"
    assert issue.labels == ["economic-os-telegram-work-item"]
    assert issue.description =~ "economic_os_submit_telegram_work_item"
    assert issue.description =~ String.duplicate("a", 64)
  end

  test "refreshes, submits and records run telemetry with server-bound identity" do
    parent = self()

    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn options ->
      send(parent, {:request, options})
      body = if options[:url] =~ ":get", do: %{"data" => %{"work_item" => work_item()}}, else: %{}
      {:ok, %{status: 200, body: body}}
    end)

    assert {:ok, [%{state: "Todo"}]} =
             EconomicOSTelegramWorkItem.fetch_issue_states_by_ids(["7"])

    assert_receive {:request, get}
    assert get[:json] == %{work_item_id: 7}

    result = result()
    assert :ok = EconomicOSTelegramWorkItem.submit_result("7", result)
    assert_receive {:request, submit}
    assert submit[:json] == %{work_item_id: 7, result: result}

    assert :ok =
             EconomicOSTelegramWorkItem.record_agent_run_start("7", %{
               run_key: "run-0123456789abcdef",
               attempt: 1,
               started_at: DateTime.utc_now()
             })

    assert_receive {:request, start}

    assert start[:json] == %{
             work_item_id: 7,
             run_key: "run-0123456789abcdef",
             attempt: 1
           }

    assert :ok =
             EconomicOSTelegramWorkItem.record_agent_run_finish("7", %{
               run_key: "run-0123456789abcdef",
               attempt: 1,
               duration_ms: 1200,
               status: "succeeded",
               thread_id: "thread",
               turn_count: 1,
               prompt: "must not cross"
             })

    assert_receive {:request, finish}
    refute Map.has_key?(finish[:json], :prompt)
  end

  test "exposes one typed server-bound tool and rejects model-selected identity" do
    assert [tool] = DynamicTool.tool_specs()
    assert tool["name"] == "economic_os_submit_telegram_work_item"

    assert MapSet.new(tool["inputSchema"]["required"]) ==
             MapSet.new(Map.keys(tool["inputSchema"]["properties"]))

    parent = self()

    response =
      DynamicTool.execute(
        "economic_os_submit_telegram_work_item",
        Map.put(result(), "work_item_id", 99),
        issue: %{id: "7"},
        telegram_work_item_submitter: fn issue_id, payload ->
          send(parent, {:submitted, issue_id, payload})
          :ok
        end
      )

    refute response["success"]
    refute_receive {:submitted, _, _}

    response =
      DynamicTool.execute(
        "economic_os_submit_telegram_work_item",
        result(),
        issue: %{id: "7"},
        telegram_work_item_submitter: fn issue_id, payload ->
          send(parent, {:submitted, issue_id, payload})
          :ok
        end
      )

    assert response["success"]
    assert_receive {:submitted, "7", payload}
    assert payload == result()
  end

  test "requires the dedicated tracker token" do
    assert Config.validate!() == :ok

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "economic_os_telegram_work_item",
      tracker_endpoint: "https://economic-os.example",
      tracker_api_token: nil
    )

    assert Config.validate!() == {:error, :missing_economic_os_api_token}
  end

  test "filters candidate states and handles an empty projection" do
    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn _options ->
      {:ok, %{status: 200, body: %{"data" => %{"work_item" => work_item()}}}}
    end)

    assert {:ok, [_issue]} =
             EconomicOSTelegramWorkItem.fetch_issues_by_states([" TODO "])

    assert {:ok, []} = EconomicOSTelegramWorkItem.fetch_issues_by_states(["Done"])
    assert :ok = EconomicOSTelegramWorkItem.create_comment("7", "ignored")
    assert :ok = EconomicOSTelegramWorkItem.update_issue_state("7", "In Progress")

    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn _options ->
      {:ok, %{status: 200, body: nil}}
    end)

    assert {:ok, []} = EconomicOSTelegramWorkItem.fetch_candidate_issues()
  end

  test "normalizes atom-keyed and terminal work items and omits an unset tenant" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "economic_os_telegram_work_item",
      tracker_endpoint: "https://economic-os.example",
      tracker_api_token: "telegram-worker-token",
      tracker_tenant: nil
    )

    parent = self()

    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn options ->
      send(parent, {:request, options})
      atom_item = Map.new(work_item(), fn {key, value} -> {String.to_atom(key), value} end)
      {:ok, %{status: 200, body: %{work_item: atom_item}}}
    end)

    assert {:ok, [%{id: "7"}]} = EconomicOSTelegramWorkItem.fetch_candidate_issues()
    assert_receive {:request, request}
    refute Enum.any?(request[:headers], fn {name, _value} -> name == "x-mini-tenant" end)

    for {status, state} <- [
          {"queued", "Todo"},
          {"preparing", "Todo"},
          {"cancelled", "Cancelled"},
          {"completed", "Done"}
        ] do
      issue =
        work_item()
        |> Map.put("status", status)
        |> EconomicOSTelegramWorkItem.normalize_work_item_for_test()

      assert issue.state == state
    end

    assert %{identifier: "TELEGRAM-WORK-ITEM-8"} =
             EconomicOSTelegramWorkItem.normalize_work_item_for_test(%{
               id: 8,
               title: "Minimal item",
               status: "failed"
             })
  end

  test "treats absent and deleted work-item states as absent" do
    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn options ->
      case options[:json].work_item_id do
        7 -> {:ok, %{status: 200, body: %{"data" => %{"work_item" => nil}}}}
        8 -> {:ok, %{status: 404, body: %{"error" => "not found"}}}
      end
    end)

    assert {:ok, []} =
             EconomicOSTelegramWorkItem.fetch_issue_states_by_ids(["7", "8"])
  end

  test "returns bounded provider and validation failures" do
    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn _options ->
      {:ok, %{status: 503, body: %{"error" => "unavailable"}}}
    end)

    assert {:error, {:economic_os_api_status, 503, %{"error" => "unavailable"}}} =
             EconomicOSTelegramWorkItem.fetch_issue_states_by_ids(["7"])

    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn _options ->
      {:ok, %{status: 503}}
    end)

    assert {:error, {:economic_os_api_status, 503}} =
             EconomicOSTelegramWorkItem.fetch_candidate_issues()

    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn _options ->
      {:error, :timeout}
    end)

    assert {:error, {:economic_os_api_request, :timeout}} =
             EconomicOSTelegramWorkItem.fetch_candidate_issues()

    assert {:error, :invalid_telegram_work_item_id} =
             EconomicOSTelegramWorkItem.submit_result("invalid", result())

    assert {:error, {:invalid_agent_run_field, :run_key}} =
             EconomicOSTelegramWorkItem.record_agent_run_start("7", %{attempt: 1})

    assert {:error, {:invalid_agent_run_field, :attempt}} =
             EconomicOSTelegramWorkItem.record_agent_run_start("7", %{
               run_key: "run-key",
               attempt: 0
             })

    assert {:error, {:invalid_agent_run_field, :duration_ms}} =
             EconomicOSTelegramWorkItem.record_agent_run_finish("7", %{
               run_key: "run-key",
               attempt: 1,
               duration_ms: -1,
               status: "failed"
             })

    assert {:error, {:invalid_agent_run_field, :status}} =
             EconomicOSTelegramWorkItem.record_agent_run_finish("7", %{
               run_key: "run-key",
               attempt: 1,
               duration_ms: 0,
               status: "running"
             })
  end

  defp work_item do
    %{
      "id" => 7,
      "public_id" => "T-7ABCD",
      "title" => "Inspect margin",
      "goal" => "Inspect the cited margin deviation",
      "capability_profile" => "read_only",
      "bounded_context" => %{},
      "repository_manifest" => %{"manifest_path" => "/safe/manifest.json"},
      "manifest_digest" => String.duplicate("a", 64),
      "status" => "running",
      "attempt" => 0
    }
  end

  defp result do
    %{
      "schema_version" => "telegram-work-item-result-v1",
      "manifest_digest" => String.duplicate("a", 64),
      "outcome" => "completed",
      "summary" => "Done",
      "artifact_refs" => [],
      "evidence_refs" => ["manifest"],
      "interaction" => nil
    }
  end
end
