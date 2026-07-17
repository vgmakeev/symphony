defmodule SymphonyElixir.Tracker.Markdown do
  @moduledoc """
  File-based tracker adapter compatible with Backlog.md format and simple YAML tasks.

  Reads tasks from a `backlog/tasks/` directory. Each `.md` file uses YAML
  front matter with fields: id, title, status, priority, dependencies, labels.
  `.yaml` and `.yml` files use the same fields directly, with an optional
  `description` string.

  Status is stored in the task file (not via directory structure). State
  transitions update the `status` field in-place. Completed tasks can optionally
  be moved to `backlog/completed/` by the user.

  Compatible with: https://github.com/MrLesk/Backlog.md
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  # Maps our internal states to Backlog.md status values
  @state_to_status %{
    "Todo" => "To Do",
    "In Progress" => "In Progress",
    "Review" => "Review",
    "Rework" => "Rework",
    "Done" => "Done",
    "Cancelled" => "Cancelled"
  }

  @status_to_state %{
    "to do" => "Todo",
    "in progress" => "In Progress",
    "review" => "Review",
    "rework" => "Rework",
    "done" => "Done",
    "cancelled" => "Cancelled",
    "canceled" => "Cancelled"
  }

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    issues =
      scan_dirs()
      |> Enum.flat_map(&list_md_files/1)
      |> Enum.map(&parse_issue/1)

    {:ok, issues}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok, issues} = fetch_candidate_issues()

    {:ok,
     Enum.filter(issues, fn %Issue{state: state} ->
       MapSet.member?(normalized, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted = MapSet.new(issue_ids)
    {:ok, issues} = fetch_candidate_issues()

    {:ok,
     Enum.filter(issues, fn %Issue{id: id} ->
       MapSet.member?(wanted, id)
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    case find_issue_file(issue_id) do
      {:ok, path} ->
        comment_path = path <> ".comments"
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
        entry = "\n---\n_#{timestamp}_\n\n#{body}\n"
        File.write(comment_path, entry, [:append])
        :ok

      :error ->
        {:error, :issue_not_found}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, new_state) do
    backlog_status = Map.get(@state_to_status, new_state, new_state)

    case find_issue_file(issue_id) do
      {:ok, path} ->
        content = File.read!(path)
        updated = update_task_status(path, content, backlog_status)
        File.write!(path, updated)
        :ok

      :error ->
        {:error, :issue_not_found}
    end
  end

  # --- Private ---

  defp tasks_root do
    Config.markdown_tasks_dir()
  end

  defp scan_dirs do
    root = tasks_root()
    backlog_tasks = Path.join(Path.dirname(root), "backlog/tasks")
    backlog_completed = Path.join(Path.dirname(root), "backlog/completed")

    [root, backlog_tasks, backlog_completed]
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
  end

  defp list_md_files(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&task_file?/1)
    |> Enum.sort()
    |> Enum.map(&Path.join(dir, &1))
  end

  defp task_file?(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    ext in [".md", ".yaml", ".yml"]
  end

  defp parse_issue(path) do
    content = File.read!(path)
    filename = path |> Path.basename() |> Path.rootname()

    {front_matter, body} = extract_task_payload(path, content)
    {title, description} = extract_title_and_description(body)

    raw_status = Map.get(front_matter, "status", "To Do")
    state = status_to_state(raw_status)
    identifier = front_matter |> Map.get("id", filename) |> to_string()
    priority = parse_priority(Map.get(front_matter, "priority"))
    dependencies = Map.get(front_matter, "dependencies", []) || []
    blocked_by = parse_blocked_by(dependencies)
    labels = normalize_labels(Map.get(front_matter, "labels", []) || [])

    %Issue{
      id: identifier,
      identifier: identifier,
      title: Map.get(front_matter, "title") || title || filename,
      description: task_description(Map.get(front_matter, "description"), description),
      state: state,
      branch_name: "auto/#{identifier}",
      url: "file://#{path}",
      priority: priority,
      labels: labels,
      blocked_by: blocked_by,
      assigned_to_worker: true
    }
  end

  defp status_to_state(status) when is_binary(status) do
    Map.get(@status_to_state, String.downcase(String.trim(status)), "Todo")
  end

  defp status_to_state(_), do: "Todo"

  defp parse_priority("high"), do: 1
  defp parse_priority("medium"), do: 2
  defp parse_priority("low"), do: 3
  defp parse_priority(val) when is_integer(val), do: val
  defp parse_priority(_), do: nil

  defp extract_front_matter(content) do
    case Regex.run(~r/\A---\n(.*?\n)---\n(.*)\z/s, content) do
      [_, yaml_str, body] ->
        case YamlElixir.read_from_string(yaml_str) do
          {:ok, parsed} when is_map(parsed) -> {parsed, body}
          _ -> {%{}, content}
        end

      _ ->
        {%{}, content}
    end
  end

  defp extract_task_payload(path, content) do
    case path |> Path.extname() |> String.downcase() do
      ".yaml" -> extract_yaml_task(content)
      ".yml" -> extract_yaml_task(content)
      _ -> extract_front_matter(content)
    end
  end

  defp extract_yaml_task(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, parsed} when is_map(parsed) ->
        {parsed, to_string(Map.get(parsed, "description", ""))}

      _ ->
        {%{}, content}
    end
  end

  defp parse_blocked_by(deps) when is_list(deps) do
    deps
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn dep_id ->
      dep_str = to_string(dep_id) |> String.trim()
      %{id: dep_str, state: find_blocker_state(dep_str)}
    end)
  end

  defp parse_blocked_by(_), do: []

  defp find_blocker_state(blocker_id) do
    {:ok, issues} = fetch_candidate_issues_raw()

    case Enum.find(issues, fn {_path, fm, _body} ->
           id = Map.get(fm, "id", "")
           to_string(id) == blocker_id
         end) do
      {_path, fm, _body} -> status_to_state(Map.get(fm, "status", "To Do"))
      nil -> "Todo"
    end
  end

  defp fetch_candidate_issues_raw do
    results =
      scan_dirs()
      |> Enum.flat_map(&list_md_files/1)
      |> Enum.map(fn path ->
        content = File.read!(path)
        {fm, body} = extract_task_payload(path, content)
        {path, fm, body}
      end)

    {:ok, results}
  end

  defp update_front_matter_status(content, new_status) do
    case Regex.run(~r/\A(---\n)(.*?\n)(---\n)(.*)\z/s, content) do
      [_, open, yaml_str, close, body] ->
        updated_yaml =
          yaml_str
          |> String.replace(~r/^status:\s*.*$/m, "status: '#{new_status}'")

        if updated_yaml == yaml_str and not String.contains?(yaml_str, "status:") do
          open <> yaml_str <> "status: '#{new_status}'\n" <> close <> body
        else
          open <> updated_yaml <> close <> body
        end

      _ ->
        "---\nstatus: '#{new_status}'\n---\n" <> content
    end
  end

  defp update_task_status(path, content, new_status) do
    case path |> Path.extname() |> String.downcase() do
      ".yaml" -> update_yaml_status(content, new_status)
      ".yml" -> update_yaml_status(content, new_status)
      _ -> update_front_matter_status(content, new_status)
    end
  end

  defp update_yaml_status(content, new_status) do
    if String.match?(content, ~r/^status:\s*.*$/m) do
      String.replace(content, ~r/^status:\s*.*$/m, "status: '#{new_status}'")
    else
      "status: '#{new_status}'\n" <> content
    end
  end

  defp normalize_labels(labels) when is_list(labels), do: Enum.map(labels, &to_string/1)

  defp normalize_labels(labels) when is_binary(labels) do
    labels
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_labels(_labels), do: []

  defp task_description(nil, fallback), do: fallback
  defp task_description(description, _fallback) when is_binary(description), do: description
  defp task_description(description, _fallback), do: to_string(description)

  defp extract_title_and_description(content) do
    lines = String.split(content, "\n")

    case Enum.find_index(lines, &String.match?(&1, ~r/^#\s+/)) do
      nil ->
        {nil, String.trim(content)}

      idx ->
        title =
          lines
          |> Enum.at(idx)
          |> String.replace(~r/^#\s+/, "")
          |> String.trim()

        desc =
          lines
          |> List.delete_at(idx)
          |> Enum.join("\n")
          |> String.trim()

        {title, desc}
    end
  end

  defp find_issue_file(issue_id) do
    result =
      scan_dirs()
      |> Enum.flat_map(&list_md_files/1)
      |> Enum.find(fn path ->
        content = File.read!(path)
        {fm, _body} = extract_task_payload(path, content)
        id = Map.get(fm, "id", path |> Path.basename() |> Path.rootname())
        to_string(id) == to_string(issue_id)
      end)

    case result do
      nil -> :error
      path -> {:ok, path}
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp normalize_state(_), do: ""
end
