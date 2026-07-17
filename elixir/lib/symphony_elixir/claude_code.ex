defmodule SymphonyElixir.ClaudeCode do
  @moduledoc """
  Runs Claude Code CLI as an Erlang Port with stream-json output.

  Replaces `Codex.AppServer` — no JSON-RPC, no bidirectional approval flow.
  Uses `--session-id` + `--resume` for multi-turn context preservation.
  Prompt is piped via env var (`_SYMPHONY_PROMPT`) to avoid shell injection.
  """

  require Logger
  alias SymphonyElixir.{Config, Workspace}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @graceful_shutdown_timeout_ms 15_000

  @type run_result :: {:ok, map()} | {:error, term()}

  @doc """
  Runs a single Claude Code turn in the given workspace.

  Options:
    - `:on_message` — callback `(map() -> any())` for streaming events
    - `:session_id` — reuse a session (enables `--resume` for turns 2+)
    - `:max_turns` — Claude Code `--max-turns` (default 50)

  Returns `{:ok, result_map}` with `:session_id`, `:usage`, `:cost_usd`,
  `:duration_ms`, `:num_turns` on success.
  """
  @spec run(Path.t(), String.t(), map(), keyword()) :: run_result()
  def run(workspace, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session_id = Keyword.get(opts, :session_id)
    max_turns = Keyword.get(opts, :max_turns, 50)

    with :ok <- validate_workspace(workspace),
         {:ok, port, os_pid} <- start_port(workspace, prompt, issue, session_id, max_turns) do
      metadata = %{claude_code_pid: to_string(os_pid)}

      emit(
        on_message,
        :session_started,
        %{
          session_id: session_id,
          issue_id: Map.get(issue, :id),
          issue_identifier: Map.get(issue, :identifier)
        },
        metadata
      )

      case receive_loop(port, on_message, metadata, Config.codex_turn_timeout_ms(), "") do
        {:ok, result} ->
          returned_session_id = result[:session_id] || session_id
          Logger.info("Claude Code completed for #{issue_label(issue)} session_id=#{returned_session_id}")
          {:ok, Map.put(result, :session_id, returned_session_id)}

        {:error, reason} ->
          Logger.warning("Claude Code failed for #{issue_label(issue)}: #{inspect(reason)}")
          emit(on_message, :turn_ended_with_error, %{reason: reason}, metadata)
          {:error, reason}
      end
    end
  end

  @doc """
  Gracefully stops a Claude Code process by OS pid (SIGTERM, then SIGKILL).
  """
  @spec stop(String.t() | integer()) :: :ok
  def stop(os_pid) when is_binary(os_pid), do: stop(String.to_integer(os_pid))

  def stop(os_pid) when is_integer(os_pid) do
    System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

    Task.async(fn ->
      Process.sleep(@graceful_shutdown_timeout_ms)
      System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    end)

    :ok
  rescue
    _ -> :ok
  end

  def stop(_), do: :ok

  # ---------------------------------------------------------------------------
  # Port management
  # ---------------------------------------------------------------------------

  defp validate_workspace(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())
    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace, :outside_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp start_port(workspace, prompt, issue, session_id, max_turns) do
    claude_cmd = Config.codex_command()
    args = build_args(session_id, max_turns)

    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      claude_args = Enum.join([claude_cmd | args], " ")

      # Pipe prompt via env var to avoid shell injection.
      # printf '%s' "$_SYMPHONY_PROMPT" closes stdin when done.
      full_command = ~s[printf '%s' "$_SYMPHONY_PROMPT" | #{claude_args}]

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(full_command)],
            cd: String.to_charlist(Path.expand(workspace)),
            env: port_env(workspace, issue, [{"_SYMPHONY_PROMPT", prompt}, {"CLAUDECODE", ""}]),
            line: @port_line_bytes
          ]
        )

      os_pid =
        case :erlang.port_info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> 0
        end

      {:ok, port, os_pid}
    end
  end

  defp port_env(workspace, issue, extra_env) do
    workspace
    |> Workspace.runtime_env(issue)
    |> Kernel.++(extra_env)
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(to_string(value))} end)
  end

  defp build_args(session_id, max_turns) do
    base = [
      "-p",
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      "bypassPermissions",
      "--max-turns",
      to_string(max_turns)
    ]

    session_args =
      if is_binary(session_id) and session_id != "" do
        ["--session-id", session_id, "--resume"]
      else
        []
      end

    base ++ session_args
  end

  # ---------------------------------------------------------------------------
  # Stream-JSON receive loop
  # ---------------------------------------------------------------------------

  defp receive_loop(port, on_message, metadata, timeout_ms, pending) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending <> to_string(chunk)
        handle_line(port, on_message, metadata, timeout_ms, line)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, metadata, timeout_ms, pending <> to_string(chunk))

      {^port, {:exit_status, 0}} ->
        # Normal exit without a result message — treat as success
        {:ok, %{session_id: nil, usage: %{}, cost_usd: nil, duration_ms: nil, num_turns: nil}}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, metadata, timeout_ms, line) do
    case Jason.decode(line) do
      {:ok, parsed} ->
        handle_event(port, on_message, metadata, timeout_ms, parsed)

      {:error, _} ->
        log_non_json(line)
        emit(on_message, :malformed, %{raw: line}, metadata)
        receive_loop(port, on_message, metadata, timeout_ms, "")
    end
  end

  defp handle_event(port, on_message, metadata, timeout_ms, %{"type" => "system", "subtype" => "init"} = event) do
    session_id = get_in(event, ["session_id"])
    metadata = Map.put(metadata, :session_id, session_id)
    emit(on_message, :system_init, %{session_id: session_id, payload: event}, metadata)
    receive_loop(port, on_message, metadata, timeout_ms, "")
  end

  defp handle_event(port, on_message, metadata, timeout_ms, %{"type" => "assistant"} = event) do
    usage = extract_usage(event)
    metadata = maybe_put_usage(metadata, usage)
    emit(on_message, :assistant_message, %{payload: event, usage: usage}, metadata)
    receive_loop(port, on_message, metadata, timeout_ms, "")
  end

  defp handle_event(port, on_message, metadata, timeout_ms, %{"type" => "tool_use"} = event) do
    tool_name = get_in(event, ["tool_name"]) || get_in(event, ["name"])
    emit(on_message, :tool_use, %{tool: tool_name, payload: event}, metadata)
    receive_loop(port, on_message, metadata, timeout_ms, "")
  end

  defp handle_event(port, on_message, metadata, timeout_ms, %{"type" => "tool_result"} = event) do
    emit(on_message, :tool_result, %{payload: event}, metadata)
    receive_loop(port, on_message, metadata, timeout_ms, "")
  end

  defp handle_event(_port, on_message, metadata, _timeout_ms, %{"type" => "result"} = event) do
    case event do
      %{"subtype" => "success"} ->
        result = build_result(event, metadata)
        emit(on_message, :turn_completed, %{payload: event, result: result}, metadata)
        {:ok, result}

      %{"subtype" => "error"} ->
        error_msg = get_in(event, ["error"]) || "unknown error"
        emit(on_message, :turn_failed, %{payload: event, error: error_msg}, metadata)
        {:error, {:claude_code_error, error_msg}}

      _ ->
        # Treat unknown result subtypes as success
        result = build_result(event, metadata)
        emit(on_message, :turn_completed, %{payload: event, result: result}, metadata)
        {:ok, result}
    end
  end

  defp handle_event(port, on_message, metadata, timeout_ms, event) when is_map(event) do
    type = Map.get(event, "type", "unknown")
    emit(on_message, :notification, %{type: type, payload: event}, metadata)
    receive_loop(port, on_message, metadata, timeout_ms, "")
  end

  # ---------------------------------------------------------------------------
  # Result building
  # ---------------------------------------------------------------------------

  defp build_result(event, metadata) do
    usage = extract_result_usage(event)

    %{
      session_id: metadata[:session_id],
      usage: usage,
      cost_usd: get_in(event, ["total_cost_usd"]) || get_in(event, ["cost_usd"]),
      duration_ms: get_in(event, ["duration_ms"]),
      duration_api_ms: get_in(event, ["duration_api_ms"]),
      num_turns: get_in(event, ["num_turns"]),
      result_text: get_in(event, ["result"])
    }
  end

  defp extract_result_usage(event) do
    usage = Map.get(event, "usage") || %{}

    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      cache_read_input_tokens: Map.get(usage, "cache_read_input_tokens", 0),
      cache_creation_input_tokens: Map.get(usage, "cache_creation_input_tokens", 0)
    }
  end

  defp extract_usage(%{"message" => %{"usage" => usage}}) when is_map(usage) do
    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0)
    }
  end

  defp extract_usage(_), do: %{}

  # ---------------------------------------------------------------------------
  # Event emission
  # ---------------------------------------------------------------------------

  defp emit(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())
      |> maybe_merge_usage(details)

    on_message.(message)
  end

  defp maybe_merge_usage(message, %{usage: usage}) when is_map(usage) and map_size(usage) > 0 do
    Map.put(message, :usage, usage)
  end

  defp maybe_merge_usage(message, _), do: message

  defp maybe_put_usage(metadata, usage) when is_map(usage) and map_size(usage) > 0 do
    Map.put(metadata, :usage, usage)
  end

  defp maybe_put_usage(metadata, _), do: metadata

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp issue_label(issue) do
    id = Map.get(issue, :id)
    identifier = Map.get(issue, :identifier)
    "issue_id=#{id} issue_identifier=#{identifier}"
  end

  defp log_non_json(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude Code output: #{text}")
      else
        Logger.debug("Claude Code output: #{text}")
      end
    end
  end

  defp default_on_message(_message), do: :ok
end
