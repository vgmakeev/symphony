defmodule SymphonyElixir.TrackerMarkdownStatusUpdatesTest do
  use SymphonyElixir.TestSupport

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-markdown-status-updates-#{System.unique_integer([:positive])}"
      )

    tasks_dir = Path.join(test_root, "tasks")
    File.mkdir_p!(tasks_dir)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "file",
      tracker_tasks_dir: tasks_dir
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    {:ok, tasks_dir: tasks_dir}
  end

  test "replaces existing markdown front matter status with backlog status", %{tasks_dir: tasks_dir} do
    task_path = Path.join(tasks_dir, "existing-status.md")

    File.write!(task_path, """
    ---
    id: TASK-EXISTING
    title: Existing status
    status: In Progress
    priority: medium
    ---
    # Existing status

    Body stays in place.
    """)

    assert :ok = Tracker.update_issue_state("TASK-EXISTING", "Todo")

    assert File.read!(task_path) == """
           ---
           id: TASK-EXISTING
           title: Existing status
           status: 'To Do'
           priority: medium
           ---
           # Existing status

           Body stays in place.
           """
  end

  test "inserts missing markdown status into existing front matter", %{tasks_dir: tasks_dir} do
    task_path = Path.join(tasks_dir, "missing-status.md")

    File.write!(task_path, """
    ---
    id: TASK-MISSING
    title: Missing status
    labels:
      - backend
    ---
    # Missing status

    Body stays in place.
    """)

    assert :ok = Tracker.update_issue_state("TASK-MISSING", "Review")

    assert File.read!(task_path) == """
           ---
           id: TASK-MISSING
           title: Missing status
           labels:
             - backend
           status: 'Review'
           ---
           # Missing status

           Body stays in place.
           """
  end

  test "prepends status front matter to markdown without front matter", %{tasks_dir: tasks_dir} do
    task_path = Path.join(tasks_dir, "plain-markdown.md")

    File.write!(task_path, """
    # Plain markdown

    Body stays in place.
    """)

    assert :ok = Tracker.update_issue_state("plain-markdown", "Done")

    assert File.read!(task_path) == """
           ---
           status: 'Done'
           ---
           # Plain markdown

           Body stays in place.
           """
  end

  test "prepends backlog status to YAML task without status", %{tasks_dir: tasks_dir} do
    task_path = Path.join(tasks_dir, "missing-status.yml")

    File.write!(task_path, """
    id: TASK-YAML
    title: YAML missing status
    priority: low
    description: |
      Body stays in place.
    """)

    assert :ok = Tracker.update_issue_state("TASK-YAML", "Todo")

    assert File.read!(task_path) == """
           status: 'To Do'
           id: TASK-YAML
           title: YAML missing status
           priority: low
           description: |
             Body stays in place.
           """
  end
end
