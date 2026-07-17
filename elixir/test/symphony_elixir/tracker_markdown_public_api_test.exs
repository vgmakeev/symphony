defmodule SymphonyElixir.TrackerMarkdownPublicApiTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Markdown

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-markdown-public-api-#{System.unique_integer([:positive])}"
      )

    tasks_dir = Path.join(test_root, "tasks")
    File.mkdir_p!(tasks_dir)

    paths = write_tasks!(tasks_dir)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "file",
      tracker_tasks_dir: tasks_dir
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    {:ok, paths: paths}
  end

  test "fetch_issues_by_states returns only requested normalized states" do
    assert {:ok, issues} = Markdown.fetch_issues_by_states([" todo ", "DONE"])

    assert Map.new(issues, &{&1.id, &1.state}) == %{
             "TASK-MD-TODO" => "Todo",
             "TASK-YAML-DONE" => "Done"
           }
  end

  test "fetch_issue_states_by_ids returns only requested task ids" do
    assert {:ok, issues} = Markdown.fetch_issue_states_by_ids(["TASK-YAML-DONE", "missing"])

    assert Enum.map(issues, & &1.id) == ["TASK-YAML-DONE"]
    assert hd(issues).state == "Done"
  end

  test "create_comment appends to the task comments file", %{paths: paths} do
    comments_path = paths.todo_md <> ".comments"
    File.write!(comments_path, "existing comment\n")

    assert :ok = Markdown.create_comment("TASK-MD-TODO", "Public API note")

    comments = File.read!(comments_path)
    assert String.starts_with?(comments, "existing comment\n\n---\n_")
    assert comments =~ "Public API note\n"
  end

  test "create_comment and update_issue_state return issue_not_found for missing ids" do
    assert {:error, :issue_not_found} = Markdown.create_comment("TASK-MISSING", "No target")
    assert {:error, :issue_not_found} = Markdown.update_issue_state("TASK-MISSING", "Done")
  end

  defp write_tasks!(tasks_dir) do
    todo_md = Path.join(tasks_dir, "todo.md")
    progress_md = Path.join(tasks_dir, "progress.md")
    done_yaml = Path.join(tasks_dir, "done.yaml")

    File.write!(todo_md, """
    ---
    id: TASK-MD-TODO
    title: Markdown todo task
    status: To Do
    ---
    # Markdown todo task

    Exercise Markdown public API filtering.
    """)

    File.write!(progress_md, """
    ---
    id: TASK-MD-PROGRESS
    title: Markdown progress task
    status: In Progress
    ---
    # Markdown progress task
    """)

    File.write!(done_yaml, """
    id: TASK-YAML-DONE
    title: YAML done task
    status: Done
    description: Exercise YAML public API filtering.
    """)

    %{todo_md: todo_md, progress_md: progress_md, done_yaml: done_yaml}
  end
end
