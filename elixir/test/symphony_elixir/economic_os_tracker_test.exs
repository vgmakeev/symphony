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

  test "selects active agent agendas and confirmed manager goals awaiting review" do
    stub_agendas([
      agenda(1, "open"),
      agenda(2, "in_progress"),
      agenda(3, "answered"),
      human_goal_agenda(4, true, nil),
      human_goal_agenda(5, false, nil),
      human_goal_agenda(6, true, "needs_revision")
    ])

    assert Tracker.adapter() == EconomicOS
    assert {:ok, issues} = EconomicOS.fetch_candidate_issues()

    assert Enum.map(issues, &{&1.id, &1.state}) == [
             {"1", "Todo"},
             {"2", "In Progress"},
             {"4", "Todo"}
           ]

    assert hd(issues).identifier == "EOS-AGENDA-1"
    assert hd(issues).labels == ["economic-os", "weekly"]
    assert hd(issues).description =~ "mini_content_transition"
    human_issue = Enum.find(issues, &(&1.id == "4"))
    assert human_issue.labels == ["economic-os", "weekly", "goal-quality"]
    assert human_issue.description =~ "response_data"
    assert human_issue.description =~ "needs_revision"
  end

  test "fetches terminal states and exact agenda ids without owning their state" do
    stub_agendas([agenda(1, "open"), agenda(2, "answered"), agenda(3, "waived")])

    assert {:ok, done} = EconomicOS.fetch_issues_by_states(["Done"])
    assert Enum.map(done, & &1.id) == ["2"]

    assert {:ok, selected} = EconomicOS.fetch_issue_states_by_ids(["3"])
    assert [%{state: "Cancelled"}] = selected
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

  defp agenda(id, status) do
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
      "source_freshness" => %{}
    }
  end

  defp human_goal_agenda(id, confirmed, quality_status) do
    quality_review =
      if quality_status, do: %{"status" => quality_status}, else: nil

    agenda(id, "open")
    |> Map.put("execution_mode", "human_review")
    |> Map.put("response", "Хотим улучшить всё")
    |> Map.put("response_data", %{
      "items" => %{
        "project_week_goal:project:11" => %{
          "confirmed" => confirmed,
          "goal" => "Хотим улучшить всё",
          "_quality_review" => quality_review
        }
      }
    })
  end
end
