defmodule SymphonyElixir.TrackerMarkdownDependenciesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Markdown

  test "normalizes dependency ids into blocker refs with resolved states" do
    tasks_dir = new_tasks_dir!()

    write_task!(tasks_dir, "dependent.md", """
    ---
    id: TASK-1
    title: Dependent task
    status: To Do
    dependencies:
      - " BLOCKED-OPEN "
      - BLOCKED-DONE
      - MISSING-BLOCKER
      - null
    ---
    # Dependent task
    """)

    write_task!(tasks_dir, "open.md", """
    ---
    id: BLOCKED-OPEN
    title: Open blocker
    status: In Progress
    ---
    # Open blocker
    """)

    write_task!(tasks_dir, "done.yaml", """
    id: BLOCKED-DONE
    title: Done blocker
    status: Done
    description: Terminal blocker.
    """)

    configure_file_tracker!(tasks_dir)

    assert {:ok, issues} = Markdown.fetch_candidate_issues()
    dependent = issue_by_id!(issues, "TASK-1")

    assert dependent.blocked_by == [
             %{id: "BLOCKED-OPEN", state: "In Progress"},
             %{id: "BLOCKED-DONE", state: "Done"},
             %{id: "MISSING-BLOCKER", state: "Todo"}
           ]
  end

  test "non-list dependencies produce no blocker refs" do
    tasks_dir = new_tasks_dir!()

    write_task!(tasks_dir, "dependent.md", """
    ---
    id: TASK-2
    title: Scalar dependency task
    status: To Do
    dependencies: BLOCKED-OPEN
    ---
    # Scalar dependency task
    """)

    write_task!(tasks_dir, "open.md", """
    ---
    id: BLOCKED-OPEN
    title: Open blocker
    status: In Progress
    ---
    # Open blocker
    """)

    configure_file_tracker!(tasks_dir)

    assert {:ok, issues} = Markdown.fetch_candidate_issues()
    dependent = issue_by_id!(issues, "TASK-2")

    assert dependent.blocked_by == []
  end

  defp configure_file_tracker!(tasks_dir) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "file",
      tracker_tasks_dir: tasks_dir
    )
  end

  defp new_tasks_dir! do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-markdown-deps-#{System.unique_integer([:positive])}"
      )

    tasks_dir = Path.join(test_root, "tasks")
    File.mkdir_p!(tasks_dir)

    on_exit(fn -> File.rm_rf(test_root) end)

    tasks_dir
  end

  defp write_task!(tasks_dir, filename, contents) do
    File.write!(Path.join(tasks_dir, filename), contents)
  end

  defp issue_by_id!(issues, id) do
    Enum.find(issues, &(&1.id == id)) || flunk("expected issue #{id}")
  end
end
