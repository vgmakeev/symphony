defmodule SymphonyElixir.EconomicOSMiniPRReviewTrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.EconomicOSMiniPRReview

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "economic_os_mini_pr_review",
      tracker_endpoint: "https://economic-os.example",
      tracker_api_token: "reviewer-token",
      tracker_tenant: "surf"
    )

    :ok
  end

  test "selects only the bounded prepared review projection" do
    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn options ->
      assert options[:url] =~ "/mini-pr-reviews:next"
      {:ok, %{status: 200, body: %{"data" => %{"review" => review()}}}}
    end)

    assert Tracker.adapter() == EconomicOSMiniPRReview
    assert {:ok, [issue]} = EconomicOSMiniPRReview.fetch_candidate_issues()
    assert issue.id == "7"
    assert issue.identifier == "MINI-PR-42-bbbbbbbb"
    assert issue.labels == ["economic-os-mini-pr-review"]
    assert issue.description =~ "economic_os_submit_mini_pr_review"
    assert issue.description =~ "/var/lib/surf-control/mini-pr-reviews/7"
  end

  test "claims and refreshes the exact server-owned review id" do
    parent = self()

    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn options ->
      send(parent, {:request, options})
      {:ok, %{status: 200, body: %{"data" => %{"review" => review("In Progress")}}}}
    end)

    assert :ok = EconomicOSMiniPRReview.update_issue_state("7", "In Progress")
    assert_receive {:request, claim}
    assert claim[:url] =~ "/mini-pr-reviews:claim"
    assert claim[:json] == %{review_id: 7}

    assert {:ok, [%{state: "In Progress"}]} =
             EconomicOSMiniPRReview.fetch_issue_states_by_ids(["7"])

    assert_receive {:request, refresh}
    assert refresh[:url] =~ "/mini-pr-reviews:get"
    assert refresh[:json] == %{review_id: 7}
  end

  test "submits typed result and records run telemetry without GitHub authority" do
    parent = self()

    Application.put_env(:symphony_elixir, :economic_os_request_fun, fn options ->
      send(parent, {:request, options})
      {:ok, %{status: 200, body: %{}}}
    end)

    result = review_result()
    assert :ok = EconomicOSMiniPRReview.submit_review("7", result)
    assert_receive {:request, submit}
    assert submit[:url] =~ "/mini-pr-reviews:submit"
    assert submit[:json] == %{review_id: 7, result: result}
    refute inspect(submit) =~ "github"

    assert :ok =
             EconomicOSMiniPRReview.record_agent_run_start("7", %{
               run_key: "run-0123456789abcdef",
               attempt: 1
             })

    assert_receive {:request, start}
    assert start[:url] =~ "/mini-pr-review-runs:start"

    assert :ok =
             EconomicOSMiniPRReview.record_agent_run_finish("7", %{
               run_key: "run-0123456789abcdef",
               attempt: 1,
               duration_ms: 1200,
               status: "succeeded",
               thread_id: "thread",
               turn_count: 1,
               prompt: "must not cross"
             })

    assert_receive {:request, finish}
    assert finish[:url] =~ "/mini-pr-review-runs:finish"
    refute Map.has_key?(finish[:json], :prompt)
  end

  test "requires the dedicated tracker token" do
    assert Config.validate!() == :ok

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "economic_os_mini_pr_review",
      tracker_endpoint: "https://economic-os.example",
      tracker_api_token: nil
    )

    assert Config.validate!() == {:error, :missing_economic_os_api_token}
  end

  defp review(state \\ "Todo") do
    %{
      "id" => 7,
      "identifier" => "MINI-PR-42-bbbbbbbb",
      "title" => "Reusable task primitive",
      "state" => state,
      "url" => "https://github.com/vgmakeev/mini/pull/42",
      "workspace_path" => "/var/lib/surf-control/mini-pr-reviews/7",
      "head_sha" => String.duplicate("b", 40),
      "policy_revision" => "mini-pr-review-v1",
      "policy_digest" => String.duplicate("a", 64),
      "manifest_digest" => String.duplicate("b", 64)
    }
  end

  defp review_result do
    %{
      "schema_version" => "mini-pr-review-result-v1",
      "head_sha" => String.duplicate("b", 40),
      "policy_revision" => "mini-pr-review-v1",
      "policy_digest" => String.duplicate("a", 64),
      "manifest_digest" => String.duplicate("b", 64),
      "verdict" => "approve",
      "summary" => "Reusable and correct",
      "checked_areas" => ["correctness", "architecture"],
      "reusable_assessment" => "General capability",
      "placement_assessment" => "Correct package boundary",
      "evidence" => ["Exact SHA CI"],
      "findings" => [],
      "complete" => true
    }
  end
end
