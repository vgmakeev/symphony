defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.Config

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      workspace = workspace_path_for_issue(safe_id)

      with :ok <- validate_workspace_path(workspace),
           {:ok, created?} <- ensure_workspace(workspace, safe_id, issue_context),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?),
           :ok <- maybe_run_compose_up(workspace, issue_context) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, safe_id, issue_context) do
    case Config.workspace_strategy() do
      "git_worktree" -> ensure_git_worktree(workspace, safe_id, issue_context)
      _ -> ensure_directory_workspace(workspace)
    end
  end

  defp ensure_directory_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_git_worktree(workspace, safe_id, issue_context) do
    cond do
      File.dir?(workspace) and git_workspace?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_git_worktree(workspace, safe_id, issue_context)

      true ->
        create_git_worktree(workspace, safe_id, issue_context)
    end
  end

  defp git_workspace?(workspace) do
    File.exists?(Path.join(workspace, ".git"))
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  defp create_git_worktree(workspace, safe_id, issue_context) do
    with {:ok, source} <- validate_git_worktree_source(Config.workspace_source()),
         :ok <- create_workspace_parent(workspace),
         :ok <-
           run_git_worktree_add(
             source,
             workspace,
             worktree_branch_name(safe_id),
             Config.workspace_base_ref(),
             issue_context
           ) do
      {:ok, true}
    end
  end

  defp create_workspace_parent(workspace) do
    workspace
    |> Path.dirname()
    |> File.mkdir_p!()

    :ok
  end

  defp validate_git_worktree_source(nil), do: {:error, :missing_workspace_source}

  defp validate_git_worktree_source(source) when is_binary(source) do
    case System.cmd("git", ["-C", source, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} ->
        {:ok, String.trim(root)}

      {output, status} ->
        {:error, {:invalid_git_worktree_source, source, status, output}}
    end
  end

  defp run_git_worktree_add(source, workspace, branch_name, base_ref, issue_context) do
    Logger.info("Creating git worktree #{issue_log_context(issue_context)} source=#{source} workspace=#{workspace} branch=#{branch_name} base_ref=#{base_ref}")

    args =
      if git_branch_exists?(source, branch_name) do
        ["-C", source, "worktree", "add", workspace, branch_name]
      else
        ["-C", source, "worktree", "add", "-b", branch_name, workspace, base_ref]
      end

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, {:git_worktree_add_failed, status, output}}
    end
  end

  defp git_branch_exists?(source, branch_name) do
    case System.cmd("git", ["-C", source, "show-ref", "--verify", "--quiet", "refs/heads/#{branch_name}"]) do
      {_output, 0} -> true
      _ -> false
    end
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            maybe_run_compose_down(workspace)
            remove_workspace_path(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = Path.join(Config.workspace_root(), safe_id)

    remove(workspace)
    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:before_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:after_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  @spec runtime_env(Path.t(), map() | String.t() | nil) :: [{String.t(), String.t()}]
  def runtime_env(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    compose_project_name = compose_project_name_for_context(issue_context)

    [
      {"SYMPHONY_WORKSPACE", Path.expand(workspace)},
      {"SYMPHONY_ISSUE_ID", to_string(issue_context.issue_id || "")},
      {"SYMPHONY_ISSUE_IDENTIFIER", to_string(issue_context.issue_identifier || "issue")},
      {"COMPOSE_PROJECT_NAME", compose_project_name},
      {"SYMPHONY_COMPOSE_PROJECT_NAME", compose_project_name}
    ]
    |> maybe_add_playwright_env(workspace)
  end

  @spec compose_project_name(map() | String.t() | nil) :: String.t()
  def compose_project_name(issue_or_identifier) do
    issue_or_identifier
    |> issue_context()
    |> compose_project_name_for_context()
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Path.join(Config.workspace_root(), safe_id)
  end

  defp worktree_branch_name(safe_id) do
    Config.workspace_branch_prefix() <> safe_id
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp compose_project_name_for_context(issue_context) do
    prefix = Config.compose_project_name_prefix()
    issue_part = safe_identifier(issue_context.issue_identifier)

    "#{prefix}_#{issue_part}"
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "_")
    |> String.trim("_-")
    |> ensure_compose_project_prefix()
  end

  defp ensure_compose_project_prefix(""), do: "symphony_issue"

  defp ensure_compose_project_prefix(value) do
    if String.match?(value, ~r/^[a-z0-9]/) do
      value
    else
      "symphony_" <> value
    end
  end

  defp maybe_add_playwright_env(env, workspace) do
    if Config.playwright_isolated?() do
      browsers_path = Config.playwright_browsers_path(workspace)

      [
        {"PLAYWRIGHT_BROWSERS_PATH", browsers_path},
        {"SYMPHONY_PLAYWRIGHT_BROWSERS_PATH", browsers_path}
        | env
      ]
    else
      env
    end
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    case created? do
      true ->
        case Config.workspace_hooks()[:after_create] do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    case File.dir?(workspace) do
      true ->
        case Config.workspace_hooks()[:before_remove] do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command],
          cd: workspace,
          stderr_to_stdout: true,
          env: runtime_env(workspace, issue_context)
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp maybe_run_compose_up(workspace, issue_context) do
    if Config.compose_enabled?() do
      run_compose_command(workspace, issue_context, Config.compose_up_command(), "up")
    else
      :ok
    end
  end

  defp maybe_run_compose_down(workspace) do
    if Config.compose_enabled?() do
      issue_context = %{issue_id: nil, issue_identifier: Path.basename(workspace)}

      case run_compose_command(workspace, issue_context, Config.compose_down_command(), "down") do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Ignoring compose down failure workspace=#{workspace} reason=#{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp run_compose_command(workspace, issue_context, command, phase) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]
    shell_command = compose_shell_command(issue_context, command)

    Logger.info("Running compose #{phase} #{issue_log_context(issue_context)} workspace=#{workspace} project=#{compose_project_name_for_context(issue_context)}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", shell_command],
          cd: workspace,
          stderr_to_stdout: true,
          env: runtime_env(workspace, issue_context)
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        sanitized_output = sanitize_hook_output_for_log(output)
        Logger.warning("Compose #{phase} failed workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")
        {:error, {:compose_failed, phase, status, output}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("Compose #{phase} timed out workspace=#{workspace} timeout_ms=#{timeout_ms}")
        {:error, {:compose_timeout, phase, timeout_ms}}
    end
  end

  defp compose_shell_command(issue_context, command) do
    project_arg = "-p " <> shell_quote(compose_project_name_for_context(issue_context))
    file_arg = compose_file_arg(Config.compose_file())
    "docker compose #{project_arg}#{file_arg} #{command}"
  end

  defp compose_file_arg(nil), do: ""
  defp compose_file_arg(""), do: ""
  defp compose_file_arg(file), do: " -f " <> shell_quote(file)

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp remove_workspace_path(workspace) do
    if Config.workspace_strategy() == "git_worktree" and File.exists?(Path.join(workspace, ".git")) do
      remove_git_worktree(workspace)
    else
      File.rm_rf(workspace)
    end
  end

  defp remove_git_worktree(workspace) do
    case Config.workspace_source() do
      nil ->
        File.rm_rf(workspace)

      source ->
        case System.cmd("git", ["-C", source, "worktree", "remove", "--force", workspace], stderr_to_stdout: true) do
          {_output, 0} ->
            {:ok, [workspace]}

          {output, status} ->
            Logger.warning("git worktree remove failed workspace=#{workspace} status=#{status} output=#{inspect(sanitize_hook_output_for_log(output))}")
            File.rm_rf(workspace)
        end
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    root_prefix = root <> "/"

    cond do
      expanded_workspace == root ->
        {:error, {:workspace_equals_root, expanded_workspace, root}}

      String.starts_with?(expanded_workspace <> "/", root_prefix) ->
        ensure_no_symlink_components(expanded_workspace, root)

      true ->
        {:error, {:workspace_outside_root, expanded_workspace, root}}
    end
  end

  defp ensure_no_symlink_components(workspace, root) do
    workspace
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current_path ->
      next_path = Path.join(current_path, segment)

      case File.lstat(next_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:workspace_symlink_escape, next_path, root}}}

        {:ok, _stat} ->
          {:cont, next_path}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:workspace_path_unreadable, next_path, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _reason} = error -> error
      _final_path -> :ok
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(%{issue_id: _issue_id, issue_identifier: _identifier} = issue_context) do
    issue_context
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
