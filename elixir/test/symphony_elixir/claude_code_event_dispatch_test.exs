defmodule SymphonyElixir.ClaudeCodeEventDispatchTest do
  use SymphonyElixir.TestSupport

  test "dispatches stream-json events and builds completion results" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-events-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-227")
      fake_claude = Path.join(test_root, "fake-claude-events")
      File.mkdir_p!(workspace)

      write_fake_claude!(fake_claude, [
        %{"type" => "system", "subtype" => "init", "session_id" => "sess-events-1"},
        %{
          "type" => "tool_use",
          "id" => "toolu-1",
          "tool_name" => "Bash",
          "input" => %{"command" => "pwd"}
        },
        %{
          "type" => "tool_result",
          "tool_use_id" => "toolu-1",
          "content" => "workspace"
        },
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "No usage here"}]}
        },
        %{"progress" => "still-working"},
        %{
          "type" => "result",
          "subtype" => "completion",
          "usage" => %{
            "input_tokens" => 11,
            "output_tokens" => 7,
            "cache_read_input_tokens" => 3,
            "cache_creation_input_tokens" => 2
          },
          "cost_usd" => 0.012,
          "duration_ms" => 345,
          "duration_api_ms" => 123,
          "num_turns" => 2,
          "result" => "finished"
        }
      ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fake_claude
      )

      collector = start_supervised!({Agent, fn -> [] end})

      issue = %Issue{
        id: "issue-227",
        identifier: "MT-227",
        title: "Cover Claude Code event dispatch",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-227",
        labels: ["backendcoverageclaude-code"]
      }

      on_message = fn message ->
        Agent.update(collector, &[message | &1])
      end

      assert {:ok, result} =
               ClaudeCode.run(workspace, "dispatch events", issue, on_message: on_message)

      messages = Agent.get(collector, &Enum.reverse/1)

      assert Enum.map(messages, & &1.event) == [
               :session_started,
               :system_init,
               :tool_use,
               :tool_result,
               :assistant_message,
               :notification,
               :turn_completed
             ]

      assert result == %{
               session_id: "sess-events-1",
               usage: %{
                 input_tokens: 11,
                 output_tokens: 7,
                 cache_read_input_tokens: 3,
                 cache_creation_input_tokens: 2
               },
               cost_usd: 0.012,
               duration_ms: 345,
               duration_api_ms: 123,
               num_turns: 2,
               result_text: "finished"
             }

      tool_use = event!(messages, :tool_use)
      assert tool_use.tool == "Bash"
      assert tool_use.payload["id"] == "toolu-1"
      assert tool_use.session_id == "sess-events-1"

      tool_result = event!(messages, :tool_result)
      assert tool_result.payload["tool_use_id"] == "toolu-1"
      assert tool_result.session_id == "sess-events-1"

      assistant = event!(messages, :assistant_message)
      assert assistant.usage == %{}

      notification = event!(messages, :notification)
      assert notification.type == "unknown"
      assert notification.payload["progress"] == "still-working"
      refute Map.has_key?(notification, :usage)

      turn_completed = event!(messages, :turn_completed)
      assert turn_completed.payload["subtype"] == "completion"
      assert turn_completed.result == result
    after
      File.rm_rf(test_root)
    end
  end

  defp write_fake_claude!(path, events) do
    stream =
      Enum.map(events, fn event ->
        "printf '%s\\n' '#{Jason.encode!(event)}'\n"
      end)

    File.write!(path, ["#!/bin/sh\n", "cat > /dev/null\n", stream])
    File.chmod!(path, 0o755)
  end

  defp event!(messages, event) do
    Enum.find(messages, &(&1.event == event)) || flunk("missing #{inspect(event)} event")
  end
end
