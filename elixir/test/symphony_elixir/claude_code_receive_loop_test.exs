defmodule SymphonyElixir.ClaudeCodeReceiveLoopTest do
  use SymphonyElixir.TestSupport

  @tmp_prefix "symphony-claude-code-receive-loop"

  test "accumulates partial chunks before handling a stream event" do
    content_bytes = 1_049_000

    script = """
    #!/bin/sh
    cat > /dev/null
    printf '{"type":"assistant","message":{"content":"'
    perl -e 'print "x" x #{content_bytes}'
    printf '","usage":{"input_tokens":7,"output_tokens":11}}}\\n'
    printf '%s\\n' '{"type":"result","subtype":"success","usage":{"input_tokens":13,"output_tokens":17},"num_turns":1}'
    """

    with_fake_claude("partial", script, fn workspace, issue ->
      parent = self()
      on_message = fn message -> send(parent, {:claude_event, message}) end

      assert {:ok, result} = ClaudeCode.run(workspace, "stream a long line", issue, on_message: on_message)
      assert %{input_tokens: 13, output_tokens: 17} = result[:usage]
      assert result[:num_turns] == 1

      assistant = receive_event(:assistant_message)

      assert assistant[:usage] == %{input_tokens: 7, output_tokens: 11}
      assert byte_size(get_in(assistant, [:payload, "message", "content"])) == content_bytes
    end)
  end

  test "returns default success when the process exits cleanly without a result event" do
    script = """
    #!/bin/sh
    cat > /dev/null
    exit 0
    """

    with_fake_claude("zero-exit", script, fn workspace, issue ->
      assert {:ok, result} = ClaudeCode.run(workspace, "finish without output", issue)

      assert result == %{
               session_id: nil,
               usage: %{},
               cost_usd: nil,
               duration_ms: nil,
               num_turns: nil
             }
    end)
  end

  test "returns timeout errors when the stream is silent too long" do
    script = """
    #!/bin/sh
    cat > /dev/null
    sleep 0.5
    """

    with_fake_claude("timeout", script, [codex_turn_timeout_ms: 25], fn workspace, issue ->
      parent = self()
      on_message = fn message -> send(parent, {:claude_event, message}) end

      log =
        capture_log(fn ->
          assert {:error, :turn_timeout} =
                   ClaudeCode.run(workspace, "wait for output", issue, on_message: on_message)
        end)

      assert log =~ "Claude Code failed"
      assert log =~ ":turn_timeout"

      assert %{reason: :turn_timeout} = receive_event(:turn_ended_with_error)
    end)
  end

  test "emits malformed events and classifies warning and debug non-json output" do
    script = """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' 'warning: recoverable stream issue'
    printf '%s\\n' 'plain diagnostics'
    printf '%s\\n' '{"type":"result","subtype":"success","usage":{"input_tokens":1,"output_tokens":2},"num_turns":1}'
    """

    with_fake_claude("malformed", script, fn workspace, issue ->
      parent = self()
      on_message = fn message -> send(parent, {:claude_event, message}) end

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, result} =
                   ClaudeCode.run(workspace, "handle diagnostics", issue, on_message: on_message)

          assert %{input_tokens: 1, output_tokens: 2} = result[:usage]
        end)

      assert log =~ "Claude Code output: warning: recoverable stream issue"
      assert log =~ "Claude Code output: plain diagnostics"

      assert %{raw: "warning: recoverable stream issue"} = receive_event(:malformed)
      assert %{raw: "plain diagnostics"} = receive_event(:malformed)
    end)
  end

  defp with_fake_claude(name, script, fun) do
    with_fake_claude(name, script, [], fun)
  end

  defp with_fake_claude(name, script, workflow_overrides, fun) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "#{@tmp_prefix}-#{name}-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-RECEIVE")
      fake_claude = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)
      File.write!(fake_claude, script)
      File.chmod!(fake_claude, 0o755)

      workflow_overrides =
        Keyword.merge(
          [workspace_root: workspace_root, codex_command: fake_claude],
          workflow_overrides
        )

      write_workflow_file!(Workflow.workflow_file_path(), workflow_overrides)

      fun.(workspace, issue_fixture(name))
    after
      File.rm_rf(test_root)
    end
  end

  defp receive_event(event) do
    receive do
      {:claude_event, %{event: ^event} = message} -> message
    after
      1_000 -> flunk("expected #{inspect(event)} event")
    end
  end

  defp issue_fixture(name) do
    %Issue{
      id: "issue-receive-loop-#{name}",
      identifier: "MT-RECEIVE",
      title: "Receive loop coverage",
      description: "Exercise Claude Code receive-loop branches",
      state: "In Progress",
      url: "https://example.org/issues/MT-RECEIVE",
      labels: ["backendcoverageclaude-code"]
    }
  end
end
