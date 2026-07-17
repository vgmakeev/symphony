defmodule SymphonyElixir.TrackerFacadeTest do
  use SymphonyElixir.TestSupport

  describe "adapter/0" do
    test "tracker kinds route to their adapters" do
      selections = [
        {"memory", SymphonyElixir.Tracker.Memory},
        {"markdown", SymphonyElixir.Tracker.Markdown},
        {"file", SymphonyElixir.Tracker.Markdown},
        {"yaml", SymphonyElixir.Tracker.Markdown},
        {"yml", SymphonyElixir.Tracker.Markdown},
        {"linear", SymphonyElixir.Linear.Adapter}
      ]

      for {tracker_kind, expected_adapter} <- selections do
        write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: tracker_kind)

        assert Config.tracker_kind() == tracker_kind
        assert Tracker.adapter() == expected_adapter
      end
    end
  end

  describe "delegation" do
    test "facade calls through the selected adapter" do
      issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      assert {:ok, [^issue]} = Tracker.fetch_candidate_issues()
      assert {:ok, [^issue]} = Tracker.fetch_issues_by_states([" in progress "])
      assert {:ok, [^issue]} = Tracker.fetch_issue_states_by_ids(["issue-1"])

      assert :ok = Tracker.create_comment("issue-1", "comment")
      assert :ok = Tracker.update_issue_state("issue-1", "Done")

      assert_receive {:memory_tracker_comment, "issue-1", "comment"}
      assert_receive {:memory_tracker_state_update, "issue-1", "Done"}
    end
  end
end
