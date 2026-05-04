defmodule Glorbo.CLI.Registry.BuiltinProvidersTest do
  @moduledoc """
  Canary test against the three shipped `priv/providers/*.toml` files.
  Catches schema drift (e.g. referencing a deleted parser name, or
  forgetting to update TOML when the Provider struct grows a field).

  Tests are explicit about the exact expected shape — when these fail
  because of an intentional change to a shipped provider, update the
  assertion rather than loosen it.
  """

  use ExUnit.Case, async: true

  alias Glorbo.CLI.Registry.Loader
  alias Glorbo.CLI.Registry.Provider

  setup_all do
    {:ok, providers} =
      Loader.load_all(
        builtin_dir: Path.expand("priv/providers"),
        user_file: nil
      )

    {:ok, providers: Map.new(providers, &{&1.name, &1})}
  end

  test "all built-in providers load without error", %{providers: p} do
    assert map_size(p) == 9

    for name <- ~w(claude-code codex gemini-cli hermes opencode pi openai openrouter stado) do
      assert Map.has_key?(p, name), "missing built-in provider: #{name}"
    end

    for name <- ~w(claude-code codex gemini-cli hermes opencode pi stado) do
      assert p[name].kind == :cli, "#{name} must stay on the CLI registry path"
    end

    for name <- ~w(openai openrouter) do
      assert p[name].kind == :native, "#{name} must stay on the native registry path"
    end
  end

  test "stado provider declares prompt_mode :acp (GEP-45)", %{providers: p} do
    stado = p["stado"]
    assert stado.kind == :cli
    assert stado.prompt_mode == :acp
    assert stado.binary == "stado"
    assert stado.args == ["acp", "--tools"]
    # Both auth_binds present: config (ro) + state (rw).
    modes = Enum.map(stado.auth_binds, & &1.mode) |> Enum.sort()
    assert modes == [:ro, :rw]
  end

  test "untracked providers bind to parsers.none", %{providers: p} do
    for name <- ~w(hermes opencode pi) do
      prov = p[name]
      assert prov.usage_parser == "none", "#{name} must be untracked"
      assert prov.usage_path == nil
    end
  end

  test "claude-code binds to claude_jsonl parser + slash_to_dash transform", %{providers: p} do
    claude = p["claude-code"]
    assert claude.binary == "claude"
    assert claude.usage_parser == "claude_jsonl"
    assert claude.usage_path.kind == :jsonl_latest_in_dir
    assert [%{name: "encoded_workspace", transform: "slash_to_dash"}] = claude.path_transforms
  end

  test "bundled providers with auth needs declare auth_binds", %{providers: p} do
    claude = p["claude-code"]

    # claude-code reads creds from both ~/.claude/ (dir) and
    # ~/.claude.json (file at home root, not inside the dir). Both
    # bind into the sandbox HOME (= /workspace) as siblings.
    assert [
             %{host: "~/.claude", sandbox: "/workspace/.claude", mode: :ro},
             %{host: "~/.claude.json", sandbox: "/workspace/.claude.json", mode: :ro}
           ] = claude.auth_binds

    codex = p["codex"]
    assert [%{host: "~/.codex", mode: :ro}] = codex.auth_binds

    gemini = p["gemini-cli"]
    assert [%{host: "~/.gemini", mode: :ro}] = gemini.auth_binds
  end

  test "codex reads rollouts from sessions dir with codex_jsonl parser", %{providers: p} do
    codex = p["codex"]
    assert codex.binary == "codex"
    assert codex.prompt_mode == :stdin_dash
    assert codex.usage_parser == "codex_jsonl"
    assert codex.usage_path.kind == :jsonl_latest_in_dir
    assert codex.env == %{"CODEX_HOME" => "{workspace}/.glorbo-codex"}
  end

  test "gemini-cli uses stdout parser (not a file)", %{providers: p} do
    gemini = p["gemini-cli"]
    assert gemini.binary == "gemini"
    assert gemini.usage_parser == "gemini_stdout"
    assert gemini.usage_path.kind == :stdout
    assert gemini.env == %{}
  end

  test "native built-ins use the harness usage contract", %{providers: p} do
    for name <- ~w(openai openrouter) do
      prov = p[name]
      assert prov.binary == nil
      assert prov.reply_dir == "{workspace}/.glorbo/outbox"
      assert prov.reply_filename_template == "{timestamp}-{invocation_id}.md"
      assert prov.usage_parser == "native-v1"

      assert prov.usage_path == %{
               kind: :json_file,
               path: "{workspace}/.glorbo-run/{task_id}/usage.json"
             }

      assert prov.model_list == %{shape: :openai, path: "/v1/models", models: []}
    end
  end

  test "built-ins keep the shared reply cap; CLI built-ins still opt into version probes", %{
    providers: p
  } do
    for {_name, %Provider{} = prov} <- p do
      assert prov.source == :builtin

      assert prov.reply_max_bytes == 1_048_576,
             "built-in #{prov.name} reply cap must match default"
    end

    for name <- ~w(claude-code codex gemini-cli hermes opencode pi) do
      prov = p[name]
      assert prov.allow_version_probe == true, "built-in #{prov.name} must allow probes"
      assert prov.version_flag == "--version"
      assert prov.version_regex == "(\\d+\\.\\d+\\.\\d+)"
    end
  end
end
