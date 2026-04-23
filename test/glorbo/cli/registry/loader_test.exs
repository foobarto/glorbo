defmodule Glorbo.CLI.Registry.LoaderTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Registry.Loader
  alias Glorbo.CLI.Registry.Provider

  @moduletag :loader

  setup do
    tmp = Path.join(System.tmp_dir!(), "loader-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    builtin_dir = Path.join(tmp, "builtin")
    File.mkdir_p!(builtin_dir)
    user_file = Path.join(tmp, "providers.toml")
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp, builtin_dir: builtin_dir, user_file: user_file}
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  describe "happy path" do
    test "loads a minimal built-in provider", %{builtin_dir: dir} do
      write!(dir, "minimal.toml", """
      name   = "minimal"
      binary = "echo"
      args   = ["--hello"]

      reply_dir               = "{workspace}/.glorbo/outbox"
      reply_filename_template = "{invocation_id}.md"
      """)

      assert {:ok, [%Provider{} = p]} = Loader.load_all(builtin_dir: dir, user_file: nil)
      assert p.name == "minimal"
      assert p.binary == "echo"
      assert p.args == ["--hello"]
      assert p.prompt_mode == :stdin
      assert p.env == %{}
      assert p.reply_max_bytes == 1_048_576
      assert p.usage_parser == "none"
      assert p.source == :builtin
      assert p.allow_version_probe == true
    end

    test "parses all optional fields", %{builtin_dir: dir} do
      write!(dir, "full.toml", """
      name   = "full"
      binary = "claude"
      args   = ["--print", "--model", "{model}"]
      prompt_mode = "stdin_dash"

      reply_dir               = "{workspace}/.glorbo/outbox"
      reply_filename_template = "{timestamp}.md"
      reply_max_bytes         = 2_000_000

      version_flag  = "--version"
      version_regex = '(\\d+\\.\\d+\\.\\d+)'

      usage_parser = "claude_jsonl"
      usage_path   = { kind = "jsonl_latest_in_dir", path = "{workspace}/.glorbo-claude/projects/{encoded}" }

      [env]
      CLAUDE_CONFIG_DIR = "{workspace}/.glorbo-claude"

      [path_transforms.encoded]
      from      = "{workspace}"
      transform = "slash_to_dash"
      """)

      assert {:ok, [p]} = Loader.load_all(builtin_dir: dir, user_file: nil)
      assert p.prompt_mode == :stdin_dash
      assert p.env == %{"CLAUDE_CONFIG_DIR" => "{workspace}/.glorbo-claude"}
      assert p.reply_max_bytes == 2_000_000
      assert p.version_flag == "--version"
      assert p.version_regex == "(\\d+\\.\\d+\\.\\d+)"
      assert p.usage_parser == "claude_jsonl"

      assert p.usage_path == %{
               kind: :jsonl_latest_in_dir,
               path: "{workspace}/.glorbo-claude/projects/{encoded}"
             }

      assert [%{name: "encoded", from: "{workspace}", transform: "slash_to_dash"}] =
               p.path_transforms
    end

    test "parses a native provider with auth + model_list", %{builtin_dir: dir} do
      write!(dir, "native.toml", """
      name         = "lmstudio"
      kind         = "native"
      endpoint     = "http://127.0.0.1:1234/v1"
      auth         = "none"
      usage_parser = "native-v1"
      usage_path   = { kind = "json_file", path = "{workspace}/.glorbo/run/usage.json" }

      [model_list]
      path  = "/v1/models"
      shape = "openai"
      """)

      assert {:ok, [p]} = Loader.load_all(builtin_dir: dir, user_file: nil)
      assert p.kind == :native
      assert p.endpoint == "http://127.0.0.1:1234/v1"
      assert p.auth == :none
      assert p.usage_parser == "native-v1"
      assert p.usage_path == %{kind: :json_file, path: "{workspace}/.glorbo/run/usage.json"}
      assert p.model_list == %{shape: :openai, path: "/v1/models"}
      assert p.binary == nil
      assert p.args == []
      assert p.reply_dir == nil
      assert p.reply_filename_template == nil
    end

    test "parses auth_binds array-of-tables", %{builtin_dir: dir} do
      write!(dir, "with-auth.toml", """
      name   = "with-auth"
      binary = "claude"
      args   = ["--print"]

      reply_dir               = "{workspace}/.glorbo/outbox"
      reply_filename_template = "{timestamp}.md"

      [[auth_binds]]
      host    = "~/.claude"
      sandbox = "/workspace/.glorbo-claude"
      mode    = "ro"

      [[auth_binds]]
      host    = "~/.anthropic"
      sandbox = "/workspace/.anthropic"
      """)

      assert {:ok, [p]} = Loader.load_all(builtin_dir: dir, user_file: nil)

      assert [
               %{host: "~/.claude", sandbox: "/workspace/.glorbo-claude", mode: :ro},
               %{host: "~/.anthropic", sandbox: "/workspace/.anthropic", mode: :ro}
             ] = p.auth_binds
    end

    test "auth_binds rejects unknown mode", %{builtin_dir: dir} do
      write!(dir, "bad-mode.toml", """
      name   = "bad-mode"
      binary = "claude"
      args   = ["--print"]

      reply_dir               = "{workspace}/.glorbo/outbox"
      reply_filename_template = "{timestamp}.md"

      [[auth_binds]]
      host    = "~/.claude"
      sandbox = "/workspace/.glorbo-claude"
      mode    = "exec"
      """)

      assert {:error, {:invalid_auth_binds, _, msg}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)

      assert msg =~ "mode"
    end

    test "auth_binds rejects entry missing host or sandbox", %{builtin_dir: dir} do
      write!(dir, "missing-field.toml", """
      name   = "missing-field"
      binary = "claude"
      args   = ["--print"]

      reply_dir               = "{workspace}/.glorbo/outbox"
      reply_filename_template = "{timestamp}.md"

      [[auth_binds]]
      host = "~/.claude"
      """)

      assert {:error, {:invalid_auth_binds, _, _}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "parses fallback_paths as a list of strings", %{builtin_dir: dir} do
      write!(dir, "with-fallback.toml", """
      name   = "with-fallback"
      binary = "opencode"
      args   = ["--print"]
      fallback_paths = ["~/.opencode/bin/opencode", "/opt/opencode/bin/opencode"]

      reply_dir               = "{workspace}/.glorbo/outbox"
      reply_filename_template = "{timestamp}.md"
      """)

      assert {:ok, [p]} = Loader.load_all(builtin_dir: dir, user_file: nil)

      assert p.fallback_paths == [
               "~/.opencode/bin/opencode",
               "/opt/opencode/bin/opencode"
             ]
    end

    test "fallback_paths defaults to empty list", %{builtin_dir: dir} do
      write!(dir, "no-fallback.toml", minimal_toml("no-fallback"))
      assert {:ok, [p]} = Loader.load_all(builtin_dir: dir, user_file: nil)
      assert p.fallback_paths == []
    end

    test "fallback_paths rejects non-list value", %{builtin_dir: dir} do
      write!(dir, "bad.toml", """
      name   = "bad"
      binary = "x"
      args   = []
      fallback_paths = "~/.opencode/bin/opencode"

      reply_dir               = "x"
      reply_filename_template = "y"
      """)

      assert {:error, {:invalid_fallback_paths, _, msg}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)

      assert msg =~ "list"
    end

    test "fallback_paths rejects non-string entries", %{builtin_dir: dir} do
      write!(dir, "bad.toml", """
      name   = "bad"
      binary = "x"
      args   = []
      fallback_paths = ["ok", 42]

      reply_dir               = "x"
      reply_filename_template = "y"
      """)

      assert {:error, {:invalid_fallback_paths, _, msg}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)

      assert msg =~ "string"
    end

    test "user-file providers come through with source: :user", %{user_file: path} do
      File.write!(path, """
      [[providers]]
      name   = "my-pi"
      binary = "/usr/local/bin/pi"
      args   = ["--quiet"]

      reply_dir               = "{workspace}/.glorbo/outbox"
      reply_filename_template = "{invocation_id}.md"
      """)

      assert {:ok, [p]} =
               Loader.load_all(builtin_dir: tmp_empty(), user_file: path)

      assert p.source == :user
      assert p.allow_version_probe == false, "user entries default false (D13)"
    end

    test "user entries can opt in to version probes", %{user_file: path} do
      File.write!(path, """
      [[providers]]
      name   = "my-pi"
      binary = "/usr/local/bin/pi"
      args   = []
      reply_dir               = "x"
      reply_filename_template = "y"
      allow_version_probe     = true
      """)

      assert {:ok, [p]} = Loader.load_all(builtin_dir: tmp_empty(), user_file: path)
      assert p.allow_version_probe == true
    end

    test "missing user file is not an error", %{builtin_dir: dir} do
      assert {:ok, []} =
               Loader.load_all(builtin_dir: dir, user_file: "/nonexistent/providers.toml")
    end

    test "missing builtin dir is not an error" do
      assert {:ok, []} =
               Loader.load_all(builtin_dir: "/nonexistent/dir", user_file: nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Validation failures
  # ---------------------------------------------------------------------------

  describe "validation" do
    test "duplicate provider name across files", %{builtin_dir: dir} do
      write!(dir, "a.toml", minimal_toml("dup"))
      write!(dir, "b.toml", minimal_toml("dup"))

      assert {:error, {:duplicate_provider, "dup", f1, f2}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)

      assert f1 != f2
    end

    test "duplicate name across builtin + user", %{builtin_dir: dir, user_file: uf} do
      write!(dir, "a.toml", minimal_toml("dup"))
      File.write!(uf, "[[providers]]\n" <> minimal_toml("dup"))

      assert {:error, {:duplicate_provider, "dup", _, _}} =
               Loader.load_all(builtin_dir: dir, user_file: uf)
    end

    test "missing required field", %{builtin_dir: dir} do
      write!(dir, "m.toml", """
      name   = "missing-binary"
      args   = ["--x"]
      reply_dir               = "x"
      reply_filename_template = "y"
      """)

      assert {:error, {:missing_field, _, "binary"}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "invalid kind", %{builtin_dir: dir} do
      write!(dir, "bad-kind.toml", """
      name = "bad-kind"
      kind = "carrier-pigeon"
      """)

      assert {:error, {:invalid_kind, _, "carrier-pigeon"}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "native provider requires auth", %{builtin_dir: dir} do
      write!(dir, "missing-auth.toml", """
      name         = "native"
      kind         = "native"
      endpoint     = "http://127.0.0.1:1234/v1"
      usage_parser = "native-v1"
      """)

      assert {:error, {:missing_field, _, "auth"}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "native provider rejects auth outside closed set", %{builtin_dir: dir} do
      write!(dir, "bad-auth.toml", """
      name         = "native"
      kind         = "native"
      endpoint     = "http://127.0.0.1:1234/v1"
      auth         = "session-cookie"
      usage_parser = "native-v1"
      """)

      assert {:error, {:invalid_auth, _, "session-cookie"}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "native provider rejects usage_parser = none", %{builtin_dir: dir} do
      write!(dir, "bad-usage.toml", """
      name         = "native"
      kind         = "native"
      endpoint     = "http://127.0.0.1:1234/v1"
      auth         = "none"
      usage_parser = "none"
      """)

      assert {:error, {:invalid_native_usage_parser, _}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "native provider rejects invalid model_list shape", %{builtin_dir: dir} do
      write!(dir, "bad-model-list.toml", """
      name         = "native"
      kind         = "native"
      endpoint     = "http://127.0.0.1:1234/v1"
      auth         = "none"
      usage_parser = "native-v1"

      [model_list]
      path  = "/v1/models"
      shape = "vendor-secret"
      """)

      assert {:error, {:invalid_model_list, _, _}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "native provider requires model_list.path when shape != none", %{builtin_dir: dir} do
      write!(dir, "missing-model-list-path.toml", """
      name         = "native"
      kind         = "native"
      endpoint     = "http://127.0.0.1:1234/v1"
      auth         = "none"
      usage_parser = "native-v1"

      [model_list]
      shape = "openai"
      """)

      assert {:error, {:invalid_model_list, _, "path is required when shape != \"none\""}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "invalid version_regex", %{builtin_dir: dir} do
      write!(dir, "b.toml", """
      #{minimal_toml("bad-regex")}
      version_regex = '[unclosed'
      """)

      assert {:error, {:invalid_version_regex, _, _}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "unknown prompt_mode", %{builtin_dir: dir} do
      write!(dir, "b.toml", """
      #{minimal_toml("bad-mode")}
      prompt_mode = "smoke-signals"
      """)

      assert {:error, {:invalid_prompt_mode, _, "smoke-signals"}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "unknown usage_parser", %{builtin_dir: dir} do
      write!(dir, "b.toml", """
      #{minimal_toml("bad-parser")}
      usage_parser = "claudegpt_2500"
      """)

      assert {:error, {:unknown_usage_parser, _, "claudegpt_2500"}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "unknown path_transform", %{builtin_dir: dir} do
      write!(dir, "b.toml", """
      #{minimal_toml("bad-transform")}

      [path_transforms.oops]
      from      = "{workspace}"
      transform = "phlogiston"
      """)

      assert {:error, {:unknown_path_transform, _, "phlogiston"}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "reply_max_bytes must be positive int", %{builtin_dir: dir} do
      write!(dir, "b.toml", """
      #{minimal_toml("bad-bytes")}
      reply_max_bytes = -1
      """)

      assert {:error, {:invalid_reply_max_bytes, _, _}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "malformed toml", %{builtin_dir: dir} do
      write!(dir, "b.toml", "this = is [ not valid\n")

      assert {:error, {:toml_parse_error, _, _}} =
               Loader.load_all(builtin_dir: dir, user_file: nil)
    end

    test "load_all!/1 raises with formatted message", %{builtin_dir: dir} do
      write!(dir, "a.toml", minimal_toml("dup"))
      write!(dir, "b.toml", minimal_toml("dup"))

      assert_raise ArgumentError, ~r/duplicate provider "dup"/, fn ->
        Loader.load_all!(builtin_dir: dir, user_file: nil)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write!(dir, name, body), do: File.write!(Path.join(dir, name), body)

  defp minimal_toml(name) do
    """
    name   = "#{name}"
    binary = "echo"
    args   = []
    reply_dir               = "x"
    reply_filename_template = "y"
    """
  end

  defp tmp_empty do
    path = Path.join(System.tmp_dir!(), "empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit_for_pid(fn -> File.rm_rf!(path) end)
    path
  end

  defp on_exit_for_pid(fun) do
    ExUnit.Callbacks.on_exit(fun)
  end
end
