defmodule SymphonyElixir.TrackerMarkdownFrontmatterTest do
  use SymphonyElixir.TestSupport

  describe "markdown front matter parsing" do
    test "valid front matter controls title, status, and description" do
      tasks_dir = configure_tasks_dir!()

      write_task!(tasks_dir, "valid-frontmatter.md", """
      ---
      id: FM-1
      title: Front matter title
      status: Review
      description: Front matter description.
      ---
      # Body title

      Body description should not win.
      """)

      assert {:ok, [issue]} = Tracker.fetch_candidate_issues()
      assert issue.id == "FM-1"
      assert issue.identifier == "FM-1"
      assert issue.title == "Front matter title"
      assert issue.state == "Review"
      assert issue.description == "Front matter description."
      assert issue.branch_name == "auto/FM-1"
      assert issue.url == "file://#{Path.join(tasks_dir, "valid-frontmatter.md")}"
    end

    test "invalid front matter falls back safely to body content" do
      tasks_dir = configure_tasks_dir!()

      write_task!(tasks_dir, "invalid-frontmatter.md", """
      ---
      title: [broken
      ---
      # Body fallback title

      Body fallback description.
      """)

      assert {:ok, [issue]} = Tracker.fetch_candidate_issues()
      assert issue.id == "invalid-frontmatter"
      assert issue.identifier == "invalid-frontmatter"
      assert issue.title == "Body fallback title"
      assert issue.state == "Todo"
      assert issue.description =~ "title: [broken"
      assert issue.description =~ "Body fallback description."
    end

    test "missing front matter derives a usable issue from the file and body" do
      tasks_dir = configure_tasks_dir!()

      write_task!(tasks_dir, "body-only.md", """
      # Body only title

      Body only description.
      """)

      assert {:ok, [issue]} = Tracker.fetch_candidate_issues()
      assert issue.id == "body-only"
      assert issue.identifier == "body-only"
      assert issue.title == "Body only title"
      assert issue.state == "Todo"
      assert issue.description == "Body only description."
      assert issue.branch_name == "auto/body-only"
    end

    test "scalar front matter descriptions are coerced to strings" do
      tasks_dir = configure_tasks_dir!()

      write_task!(tasks_dir, "scalar-description.md", """
      ---
      id: FM-2
      title: Scalar description task
      status: To Do
      description: 123
      ---
      # Body title

      Body fallback description.
      """)

      assert {:ok, [issue]} = Tracker.fetch_candidate_issues()
      assert issue.id == "FM-2"
      assert issue.title == "Scalar description task"
      assert issue.description == "123"
    end
  end

  defp configure_tasks_dir! do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-markdown-frontmatter-#{System.unique_integer([:positive])}"
      )

    tasks_dir = Path.join(test_root, "tasks")
    File.mkdir_p!(tasks_dir)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "file",
      tracker_tasks_dir: tasks_dir
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    tasks_dir
  end

  defp write_task!(tasks_dir, filename, content) do
    File.write!(Path.join(tasks_dir, filename), content)
  end
end
