defmodule SymphonyElixir.TrackerMarkdownTitleLookupTest do
  use SymphonyElixir.TestSupport

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-markdown-title-#{System.unique_integer([:positive, :monotonic])}"
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

  test "markdown body heading supplies title and following body supplies description", %{
    tasks_dir: tasks_dir
  } do
    write_task(tasks_dir, "body-heading.md", """
    ---
    id: BODY-HEADING
    status: To Do
    ---
    # Heading From Body

    First paragraph after the heading.

    ## Details

    More body text.
    """)

    assert {:ok, [issue]} = Tracker.fetch_candidate_issues()
    assert issue.id == "BODY-HEADING"
    assert issue.title == "Heading From Body"
    assert issue.description == "First paragraph after the heading.\n\n## Details\n\nMore body text."
  end

  test "markdown title falls back to front matter title and then filename", %{tasks_dir: tasks_dir} do
    write_task(tasks_dir, "filename-title.md", """
    Body-only description without a heading.
    """)

    write_task(tasks_dir, "front-matter-title.md", """
    ---
    id: FRONT-MATTER
    title: Front Matter Title
    description: Explicit front matter description.
    status: To Do
    ---
    # Body Heading

    Body description that should not replace explicit front matter.
    """)

    assert {:ok, issues} = Tracker.fetch_candidate_issues()
    issues_by_id = Map.new(issues, &{&1.id, &1})

    filename_issue = Map.fetch!(issues_by_id, "filename-title")
    assert filename_issue.title == "filename-title"
    assert filename_issue.description == "Body-only description without a heading."

    front_matter_issue = Map.fetch!(issues_by_id, "FRONT-MATTER")
    assert front_matter_issue.title == "Front Matter Title"
    assert front_matter_issue.description == "Explicit front matter description."
  end

  test "missing markdown issue id returns issue not found through public update API", %{
    tasks_dir: tasks_dir
  } do
    write_task(tasks_dir, "existing.md", """
    ---
    id: EXISTING
    status: To Do
    ---
    Existing task.
    """)

    assert {:error, :issue_not_found} = Tracker.update_issue_state("MISSING", "Done")
  end

  defp write_task(tasks_dir, filename, content) do
    File.write!(Path.join(tasks_dir, filename), content)
  end
end
