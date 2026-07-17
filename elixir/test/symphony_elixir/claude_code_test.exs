defmodule SymphonyElixir.ClaudeCodeTest do
  use SymphonyElixir.TestSupport

  test "rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure Claude Code refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace, :workspace_root, _path}} =
               ClaudeCode.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace, :outside_root, _path, _root}} =
               ClaudeCode.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "parses stream-json result event and returns session data" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-stream-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-100")
      fake_claude = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      # Create a fake claude script that outputs stream-json
      File.write!(fake_claude, """
      #!/bin/sh
      # Read stdin (prompt)
      cat > /dev/null
      # Output stream-json events
      echo '{"type":"system","subtype":"init","session_id":"sess-abc-123"}'
      echo '{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50}}}'
      echo '{"type":"result","subtype":"success","session_id":"sess-abc-123","usage":{"input_tokens":200,"output_tokens":100},"total_cost_usd":0.005,"duration_ms":1234,"num_turns":1}'
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fake_claude
      )

      issue = %Issue{
        id: "issue-100",
        identifier: "MT-100",
        title: "Test stream parsing",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-100",
        labels: []
      }

      events = :ets.new(:claude_test_events, [:bag, :public])

      on_message = fn message ->
        :ets.insert(events, {message[:event], message})
      end

      assert {:ok, result} =
               ClaudeCode.run(workspace, "do something", issue,
                 on_message: on_message,
                 session_id: nil
               )

      assert result[:session_id] == "sess-abc-123"
      assert result[:cost_usd] == 0.005
      assert result[:duration_ms] == 1234
      assert result[:num_turns] == 1
      assert result[:usage][:input_tokens] == 200
      assert result[:usage][:output_tokens] == 100

      # Verify events were emitted
      assert length(:ets.lookup(events, :system_init)) == 1
      assert length(:ets.lookup(events, :assistant_message)) == 1
      assert length(:ets.lookup(events, :turn_completed)) == 1

      :ets.delete(events)
    after
      File.rm_rf(test_root)
    end
  end

  test "handles error result from Claude Code" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-error-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-101")
      fake_claude = Path.join(test_root, "fake-claude-err")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      cat > /dev/null
      echo '{"type":"system","subtype":"init","session_id":"sess-err-1"}'
      echo '{"type":"result","subtype":"error","error":"Rate limit exceeded"}'
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fake_claude
      )

      issue = %Issue{
        id: "issue-101",
        identifier: "MT-101",
        title: "Test error",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-101",
        labels: []
      }

      assert {:error, {:claude_code_error, "Rate limit exceeded"}} =
               ClaudeCode.run(workspace, "do something", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "builds correct args with session_id for resume" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-resume-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-102")
      fake_claude = Path.join(test_root, "fake-claude-resume")
      trace_file = Path.join(test_root, "claude-args.trace")
      File.mkdir_p!(workspace)

      # Script that writes its own invocation args to a trace file
      File.write!(fake_claude, """
      #!/bin/sh
      echo "$0 $@" > "#{trace_file}"
      cat > /dev/null
      echo '{"type":"result","subtype":"success","session_id":"sess-resume","usage":{"input_tokens":10,"output_tokens":5},"num_turns":1}'
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fake_claude
      )

      issue = %Issue{
        id: "issue-102",
        identifier: "MT-102",
        title: "Test resume",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-102",
        labels: []
      }

      assert {:ok, _result} =
               ClaudeCode.run(workspace, "continue work", issue, session_id: "existing-session-42")

      args_line = File.read!(trace_file)
      assert args_line =~ "--session-id"
      assert args_line =~ "existing-session-42"
      assert args_line =~ "--resume"
      assert args_line =~ "--permission-mode"
      assert args_line =~ "bypassPermissions"
    after
      File.rm_rf(test_root)
    end
  end

  test "handles non-zero exit status" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-exit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-103")
      fake_claude = Path.join(test_root, "fake-claude-crash")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      cat > /dev/null
      exit 1
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fake_claude
      )

      issue = %Issue{
        id: "issue-103",
        identifier: "MT-103",
        title: "Test crash",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-103",
        labels: []
      }

      assert {:error, {:exit_status, 1}} =
               ClaudeCode.run(workspace, "do something", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "stop accepts binary pid input and schedules graceful shutdown signals" do
    with_fake_kill(fn trace_file ->
      assert :ok = ClaudeCode.stop("2147483647")
      assert_kill_trace(trace_file, ["-TERM 2147483647", "-KILL 2147483647"])
    end)
  end

  test "stop accepts integer pid input and rescues kill command failures" do
    with_fake_kill(fn trace_file ->
      assert :ok = ClaudeCode.stop(2_147_483_647)
      assert_kill_trace(trace_file, ["-TERM 2147483647", "-KILL 2147483647"])
    end)

    without_kill_on_path(fn ->
      assert :ok = ClaudeCode.stop(2_147_483_647)
    end)
  end

  test "stop returns ok for invalid inputs" do
    assert :ok = ClaudeCode.stop(nil)
    assert :ok = ClaudeCode.stop(:not_a_pid)
    assert :ok = ClaudeCode.stop(%{})
    assert :ok = ClaudeCode.stop("not-a-pid")
  end

  test "invalid max_turns falls back to zero in Claude Code args" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-104")
      fake_claude = Path.join(test_root, "fake-claude-max-turns")
      trace_file = Path.join(test_root, "claude-args.trace")
      File.mkdir_p!(workspace)

      File.write!(
        fake_claude,
        """
        #!/bin/sh
        echo "$@" > "#{trace_file}"
        cat > /dev/null
        echo '{"type":"result","subtype":"success","session_id":"sess-max-turns","usage":{"input_tokens":1,"output_tokens":1},"num_turns":1}'
        """
      )

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fake_claude
      )

      issue = %Issue{
        id: "issue-104",
        identifier: "MT-104",
        title: "Test max turns fallback",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-104",
        labels: []
      }

      assert {:ok, _result} = ClaudeCode.run(workspace, "do something", issue, max_turns: "invalid")

      assert File.read!(trace_file) =~ ~r/(^|\s)--max-turns 0(\s|$)/
    after
      File.rm_rf(test_root)
    end
  end

  test "falls back to zero pid metadata when port os pid is unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-port-info-#{System.unique_integer([:positive])}"
      )

    previous_port_info = Application.get_env(:symphony_elixir, :claude_code_port_info_fun, :unset)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-105")
      fake_claude = Path.join(test_root, "fake-claude-port-info")
      File.mkdir_p!(workspace)

      File.write!(
        fake_claude,
        """
        #!/bin/sh
        cat > /dev/null
        echo '{"type":"result","subtype":"success","session_id":"sess-port-info","usage":{"input_tokens":1,"output_tokens":1},"num_turns":1}'
        """
      )

      File.chmod!(fake_claude, 0o755)

      Application.put_env(:symphony_elixir, :claude_code_port_info_fun, fn _port, :os_pid -> nil end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fake_claude
      )

      issue = %Issue{
        id: "issue-105",
        identifier: "MT-105",
        title: "Test os pid fallback",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-105",
        labels: []
      }

      parent = self()
      on_message = fn message -> send(parent, {:claude_code_event, message}) end

      assert {:ok, _result} = ClaudeCode.run(workspace, "do something", issue, on_message: on_message)
      assert_received {:claude_code_event, %{event: :session_started, claude_code_pid: "0"}}
    after
      restore_app_env(:claude_code_port_info_fun, previous_port_info)
      File.rm_rf(test_root)
    end
  end

  defp with_fake_kill(fun) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-kill-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")

    previous_timeout =
      Application.get_env(:symphony_elixir, :claude_code_graceful_shutdown_timeout_ms, :unset)

    try do
      bin_dir = Path.join(test_root, "bin")
      fake_kill = Path.join(bin_dir, "kill")
      trace_file = Path.join(test_root, "kill.trace")

      File.mkdir_p!(bin_dir)

      File.write!(
        fake_kill,
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"#{trace_file}\"\n"
      )

      File.chmod!(fake_kill, 0o755)
      System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
      Application.put_env(:symphony_elixir, :claude_code_graceful_shutdown_timeout_ms, 0)

      fun.(trace_file)
    after
      restore_env("PATH", previous_path)
      restore_app_env(:claude_code_graceful_shutdown_timeout_ms, previous_timeout)
      File.rm_rf(test_root)
    end
  end

  defp without_kill_on_path(fun) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-no-kill-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root)
      fun.()
    after
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end
  end

  defp assert_kill_trace(trace_file, expected_lines) do
    expected_trace = Enum.join(expected_lines, "\n") <> "\n"

    assert wait_for_trace(trace_file, length(expected_lines)) == expected_trace
  end

  defp wait_for_trace(trace_file, expected_line_count, retries \\ 50)

  defp wait_for_trace(trace_file, expected_line_count, retries) when retries > 0 do
    trace =
      case File.read(trace_file) do
        {:ok, contents} -> contents
        {:error, _reason} -> ""
      end

    if trace |> String.split("\n", trim: true) |> length() >= expected_line_count do
      trace
    else
      Process.sleep(10)
      wait_for_trace(trace_file, expected_line_count, retries - 1)
    end
  end

  defp wait_for_trace(trace_file, _expected_line_count, 0), do: File.read!(trace_file)

  defp restore_app_env(key, :unset), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
