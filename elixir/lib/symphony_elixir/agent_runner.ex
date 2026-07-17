defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single issue in an isolated workspace using a coding agent.

  Supports two backends selected by `codex.command` in WORKFLOW.md:
  - Claude Code CLI (`claude`) — stream-json over stdio
  - Codex app-server (`codex ... app-server`) — JSON-RPC 2.0 over stdio
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    maybe_move_to_in_progress(issue)

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- run_claude_turns(workspace, issue, codex_update_recipient, opts) do
            maybe_move_to_review(issue, workspace)
            :ok
          else
            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp run_claude_turns(workspace, issue, codex_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    do_run_claude_turns(workspace, issue, codex_update_recipient, opts, issue_state_fetcher, _session_id = nil, 1, max_turns)
  end

  defp do_run_claude_turns(workspace, issue, codex_update_recipient, opts, issue_state_fetcher, session_id, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    case coding_agent().run(
           workspace,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue),
           session_id: session_id,
           max_turns: 50
         ) do
      {:ok, result} ->
        returned_session_id = result[:session_id] || session_id

        Logger.info("Completed turn for #{issue_context(issue)} session_id=#{returned_session_id} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        # For markdown tracker: if DONE.md exists, move to Review immediately and stop turns
        if markdown_tracker?() and File.regular?(Path.join(workspace, "DONE.md")) do
          Logger.info("Markdown tracker: DONE.md detected after turn #{turn_number}, moving to Review")
          maybe_move_to_review(issue, workspace)
        end

        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_claude_turns(
              workspace,
              refreshed_issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              returned_session_id,
              turn_number + 1,
              max_turns
            )

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

            :ok

          {:done, _refreshed_issue} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Claude Code turn completed normally, but the issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this session, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp markdown_tracker? do
    Config.file_tracker?()
  end

  defp maybe_move_to_in_progress(%Issue{state: state} = issue) when is_binary(state) do
    normalized = String.downcase(String.trim(state))

    if markdown_tracker?() and normalized in ["todo", "rework"] do
      Logger.info("Markdown tracker: moving #{issue_context(issue)} from #{state} to In Progress")
      Tracker.update_issue_state(issue.id, "In Progress")
    end
  end

  defp maybe_move_to_in_progress(_issue), do: :ok

  defp maybe_move_to_review(%Issue{} = issue, workspace) do
    if markdown_tracker?() do
      has_commits = has_git_commits?(workspace)
      has_done_marker = File.regular?(Path.join(workspace, "DONE.md"))

      if has_commits or has_done_marker do
        Logger.info("Markdown tracker: moving #{issue_context(issue)} to Review (commits=#{has_commits} done_marker=#{has_done_marker})")

        Tracker.update_issue_state(issue.id, "Review")
      else
        Logger.info("Markdown tracker: no commits or DONE.md found for #{issue_context(issue)}, keeping current state")
      end
    end
  end

  defp has_git_commits?(workspace) do
    case System.cmd("git", ["log", "--oneline", "-1"], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp coding_agent do
    if String.contains?(Config.codex_command(), "app-server") do
      SymphonyElixir.Codex.AppServer
    else
      SymphonyElixir.ClaudeCode
    end
  end
end
