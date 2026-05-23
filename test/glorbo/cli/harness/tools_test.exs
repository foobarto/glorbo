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
end
