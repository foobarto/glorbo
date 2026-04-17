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

  test "all three built-in providers load without error", %{providers: p} do
    assert map_size(p) == 3
    assert Map.has_key?(p, "claude-code")
    assert Map.has_key?(p, "codex")
    assert Map.has_key?(p, "gemini-cli")
  end

  test "claude-code binds to claude_jsonl parser + slash_to_dash transform", %{providers: p} do
    claude = p["claude-code"]
    assert claude.binary == "claude"
    assert claude.usage_parser == "claude_jsonl"
    assert claude.usage_path.kind == :jsonl_latest_in_dir
    assert [%{name: "encoded_workspace", transform: "slash_to_dash"}] = claude.path_transforms
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

  test "all built-ins opt into version probes and set a 1 MiB reply cap", %{providers: p} do
    for {_name, %Provider{} = prov} <- p do
      assert prov.source == :builtin
      assert prov.allow_version_probe == true, "built-in #{prov.name} must allow probes"
      assert prov.reply_max_bytes == 1_048_576, "built-in #{prov.name} reply cap must match default"
      assert prov.version_flag == "--version"
      assert prov.version_regex == "(\\d+\\.\\d+\\.\\d+)"
    end
  end
end
