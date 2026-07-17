defmodule SymphonyElixir.TrackerMarkdownMetadataTest do
  use SymphonyElixir.TestSupport

  test "yaml tracker normalizes status priority and labels metadata safely" do
    tasks_dir = unique_tasks_dir()

    try do
      File.mkdir_p!(tasks_dir)

      write_yaml_task!(tasks_dir, "medium.yaml", """
      id: META-MEDIUM
      title: Medium priority
      status: To Do
      priority: medium
      labels: "backend, , tracker, "
      """)

      write_yaml_task!(tasks_dir, "low.yaml", """
      id: META-LOW
      title: Low priority
      status: To Do
      priority: low
      labels:
        - backend
      """)

      write_yaml_task!(tasks_dir, "integer.yaml", """
      id: META-INTEGER
      title: Integer priority
      status: 42
      priority: 4
      labels: 12
      """)

      write_yaml_task!(tasks_dir, "unknown.yaml", """
      id: META-UNKNOWN
      title: Unknown priority
      status: To Do
      priority: urgent
      labels:
        nodes:
          - name: backend
      """)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "file",
        tracker_tasks_dir: tasks_dir
      )

      assert {:ok, issues} = Tracker.fetch_candidate_issues()
      issues_by_id = Map.new(issues, &{&1.id, &1})

      assert issues_by_id["META-MEDIUM"].priority == 2
      assert issues_by_id["META-MEDIUM"].labels == ["backend", "tracker"]

      assert issues_by_id["META-LOW"].priority == 3
      assert issues_by_id["META-LOW"].labels == ["backend"]

      assert issues_by_id["META-INTEGER"].priority == 4
      assert issues_by_id["META-INTEGER"].state == "Todo"
      assert issues_by_id["META-INTEGER"].labels == []

      assert issues_by_id["META-UNKNOWN"].priority == nil
      assert issues_by_id["META-UNKNOWN"].labels == []

      assert {:ok, todo_issues} = Tracker.fetch_issues_by_states([" todo ", 42])

      assert todo_issues
             |> Enum.map(& &1.id)
             |> Enum.sort() == ["META-INTEGER", "META-LOW", "META-MEDIUM", "META-UNKNOWN"]
    after
      File.rm_rf(tasks_dir)
    end
  end

  defp unique_tasks_dir do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-markdown-metadata-#{System.unique_integer([:positive])}"
    )
  end

  defp write_yaml_task!(tasks_dir, filename, content) do
    File.write!(Path.join(tasks_dir, filename), content)
  end
end
