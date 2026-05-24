defmodule Glorbo.CLI.Harness.ToolsTest do
  use ExUnit.Case, async: false

  alias Glorbo.CLI.Harness.Tools

  setup do
    root = Path.join(System.tmp_dir!(), "glorbo-tools-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, workspace: workspace}
  end

  defp tool_call(name, args) do
    %{
      "function" => %{
        "name" => name,
        "arguments" => Jason.encode!(args)
      }
    }
  end

  defp config(workspace) do
    %{workspace: workspace}
  end

  # Codex deep-dive F3/F4: `resolve_tool_path` previously only did a
  # LEXICAL `Path.expand` containment check. If an agent created a
  # symlink at `workspace/escape` pointing to `/etc/`, a follow-up
  # `write_file` with `path = "escape/poc"` would canonicalise to
  # `<workspace>/escape/poc`, pass the string-prefix check, then
  # `File.write` would follow the symlink and write to `/etc/poc`.
  # Under bwrap the bind layout protects, but the unsandboxed
  # fallback (macOS, `--no-sandbox`) hits the host FS directly. Now
  # any ancestor-symlink crossing is refused at resolve time.
  describe "symlink-escape defense (codex F3/F4)" do
    test "write_file refuses a path under a symlinked workspace component",
         %{root: root, workspace: workspace} do
      # Plant a target dir OUTSIDE the workspace.
      escape_target = Path.join(root, "escape-target")
      File.mkdir_p!(escape_target)

      # Symlink `workspace/escape` → escape_target.
      File.ln_s!(escape_target, Path.join(workspace, "escape"))

      result =
        Tools.execute(
          tool_call("write_file", %{"path" => "escape/leak.txt", "contents" => "owned"}),
          config(workspace),
          []
        )

      assert result.payload["ok"] == false
      assert result.payload["error"] == "path_crosses_symlink"
      refute File.exists?(Path.join(escape_target, "leak.txt"))
    end

    test "edit_file refuses a path under a symlinked workspace component",
         %{root: root, workspace: workspace} do
      escape_target = Path.join(root, "escape-target")
      File.mkdir_p!(escape_target)
      File.write!(Path.join(escape_target, "victim.txt"), "original")
      File.ln_s!(escape_target, Path.join(workspace, "escape"))

      result =
        Tools.execute(
          tool_call("edit_file", %{
            "path" => "escape/victim.txt",
            "old_text" => "original",
            "new_text" => "owned"
          }),
          config(workspace),
          []
        )

      assert result.payload["ok"] == false
      assert result.payload["error"] == "path_crosses_symlink"
      assert File.read!(Path.join(escape_target, "victim.txt")) == "original"
    end

    test "read_file refuses a path under a symlinked workspace component",
         %{root: root, workspace: workspace} do
      escape_target = Path.join(root, "escape-target")
      File.mkdir_p!(escape_target)
      File.write!(Path.join(escape_target, "secret.txt"), "secret-content")
      File.ln_s!(escape_target, Path.join(workspace, "escape"))

      result =
        Tools.execute(
          tool_call("read_file", %{"path" => "escape/secret.txt"}),
          config(workspace),
          []
        )

      assert result.payload["ok"] == false
      assert result.payload["error"] == "path_crosses_symlink"
    end

    test "write_file still works for a normal path inside workspace",
         %{workspace: workspace} do
      result =
        Tools.execute(
          tool_call("write_file", %{"path" => "ok.txt", "contents" => "fine"}),
          config(workspace),
          []
        )

      assert result.payload["ok"] == true
      assert File.read!(Path.join(workspace, "ok.txt")) == "fine"
    end

    test "lexical `..` escapes still produce path_escapes_workspace",
         %{workspace: workspace} do
      result =
        Tools.execute(
          tool_call("write_file", %{"path" => "../escape.txt", "contents" => "x"}),
          config(workspace),
          []
        )

      assert result.payload["ok"] == false
      assert result.payload["error"] == "path_escapes_workspace"
    end
  end

  # PR #35 (gemini round-3 F2): the agent's `audit_events` were
  # forwarded into the audit log with `event.action` taken verbatim.
  # An agent could forge `agent.complete` (defeats LoopDetector),
  # `budget.usage` (poisons reindex sum), or `approval.granted`
  # (poisons approval rebuild). `valid_audit_action?/1` is the
  # whitelist gate that both `NativeV1.parse_audit_events/1` (parse
  # boundary) and `Dispatch.emit_tool_audits/5` (emission boundary)
  # use to reject forged actions.
  describe "valid_audit_action?/1 (gemini round-3 F2)" do
    test "accepts the canonical harness tool actions" do
      for action <- [
            "tool.read_file",
            "tool.write_file",
            "tool.edit_file",
            "tool.glob",
            "tool.grep",
            "tool.bash",
            "egress.web_fetch"
          ] do
        assert Tools.valid_audit_action?(action),
               "expected #{action} to be whitelisted"
      end
    end

    test "rejects forged system-owned actions" do
      for forged <- [
            "agent.complete",
            "agent.dispatch",
            "agent.loop_detected",
            "agent.loop_resolved",
            "budget.usage",
            "approval.granted",
            "approval.requested",
            "task.reassign",
            "system.boot",
            "audit.append"
          ] do
        refute Tools.valid_audit_action?(forged),
               "expected #{forged} to be REJECTED"
      end
    end

    test "rejects non-string and empty inputs" do
      refute Tools.valid_audit_action?(nil)
      refute Tools.valid_audit_action?(:agent_complete)
      refute Tools.valid_audit_action?(42)
      refute Tools.valid_audit_action?(%{})
      refute Tools.valid_audit_action?("")
    end

    test "case-sensitive — variants with different case are rejected" do
      refute Tools.valid_audit_action?("TOOL.BASH")
      refute Tools.valid_audit_action?("Tool.Bash")
      refute Tools.valid_audit_action?("tool.Bash")
    end
  end
end
