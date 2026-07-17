defmodule SymphonyElixir.TrackerMarkdownYamlTest do
  use SymphonyElixir.TestSupport

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-tracker-markdown-yaml-#{System.unique_integer([:positive])}"
      )

    tasks_dir = Path.join(test_root, "tasks")
    File.mkdir_p!(tasks_dir)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "file",
      tracker_tasks_dir: tasks_dir
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    %{tasks_dir: tasks_dir}
  end

  test ".yml task files are parsed the same way as .yaml task files", %{tasks_dir: tasks_dir} do
    write_yaml_task!(tasks_dir, "task-yaml.yaml", "YAML-1")
    write_yaml_task!(tasks_dir, "task-yml.yml", "YML-1")

    assert {:ok, issues} = Tracker.fetch_candidate_issues()

    yaml_issue = issue_by_id(issues, "YAML-1")
    yml_issue = issue_by_id(issues, "YML-1")

    assert issue_fields(yml_issue) == issue_fields(yaml_issue)
    assert yml_issue.url == "file://#{Path.join(tasks_dir, "task-yml.yml")}"
  end

  test "bad YAML task content falls back to file-derived issue fields", %{tasks_dir: tasks_dir} do
    invalid_yaml_path = Path.join(tasks_dir, "invalid-yaml.yml")
    non_map_yaml_path = Path.join(tasks_dir, "non-map-yaml.yaml")

    File.write!(invalid_yaml_path, """
    # Invalid YAML task
    id: [broken
    This content is kept as the fallback description.
    """)

    File.write!(non_map_yaml_path, """
    - list
    - content
    """)

    assert {:ok, issues} = Tracker.fetch_candidate_issues()

    invalid_yaml_issue = issue_by_id(issues, "invalid-yaml")
    non_map_yaml_issue = issue_by_id(issues, "non-map-yaml")

    assert invalid_yaml_issue.title == "Invalid YAML task"
    assert invalid_yaml_issue.description =~ "This content is kept as the fallback description."
    assert invalid_yaml_issue.state == "Todo"

    assert non_map_yaml_issue.title == "non-map-yaml"
    assert non_map_yaml_issue.description == "- list\n- content"
    assert non_map_yaml_issue.state == "Todo"
  end

  test ".yml status updates rewrite the YAML status field", %{tasks_dir: tasks_dir} do
    task_path = Path.join(tasks_dir, "status-update.yml")

    File.write!(task_path, """
    id: YML-STATUS
    title: Status update task
    status: To Do
    description: Keep status updates in YAML files.
    """)

    assert :ok = Tracker.update_issue_state("YML-STATUS", "Review")

    assert File.read!(task_path) == """
           id: YML-STATUS
           title: Status update task
           status: 'Review'
           description: Keep status updates in YAML files.
           """
  end

  defp write_yaml_task!(tasks_dir, filename, id) do
    File.write!(Path.join(tasks_dir, filename), """
    id: #{id}
    title: YAML backed task
    status: In Progress
    priority: medium
    labels:
      - backend
      - coverage
    description: |
      Parse task content from YAML files.
    """)
  end

  defp issue_by_id(issues, id) do
    Enum.find(issues, &(&1.id == id))
  end

  defp issue_fields(issue) do
    %{
      title: issue.title,
      description: issue.description,
      state: issue.state,
      priority: issue.priority,
      labels: issue.labels
    }
  end
end
