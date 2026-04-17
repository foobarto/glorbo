defmodule Glorbo.CLI.Parsers.CodexJsonlTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Parsers.CodexJsonl

  @fixture "test/fixtures/codex_rollout_sample.jsonl"

  # Fixture has 3 cumulative token_count events; Pitfall 10 requires the LAST.
  test "uses LAST token_count event cumulative totals (NOT summed)" do
    assert {:ok, %{prompt_tokens: 18_535, completion_tokens: 318, model: nil}} =
             CodexJsonl.parse({:jsonl_file, @fixture})
  end

  test "summing across events would overshoot — verifies last-event semantics" do
    {:ok, usage} = CodexJsonl.parse({:jsonl_file, @fixture})
    refute usage.prompt_tokens >= 26_535
    assert usage.prompt_tokens == 18_535
    assert usage.completion_tokens == 318
  end

  test "zero token_count events returns {:error, :no_token_count}" do
    path = Path.join(System.tmp_dir!(), "codex_empty_#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, """
    {"timestamp":"2026-04-13T00:00:00Z","type":"event_msg","payload":{"type":"user_message","info":{"text":"hi"}}}
    """)

    on_exit(fn -> File.rm(path) end)

    assert {:error, :no_token_count} = CodexJsonl.parse({:jsonl_file, path})
  end

  test "malformed NDJSON line is skipped; remaining events processed" do
    path =
      Path.join(System.tmp_dir!(), "codex_malformed_#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, File.read!(@fixture) <> "garbage-line\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{prompt_tokens: 18_535, completion_tokens: 318}} =
             CodexJsonl.parse({:jsonl_file, path})
  end

  test "missing file returns {:error, :enoent}" do
    assert {:error, :enoent} = CodexJsonl.parse({:jsonl_file, "/nonexistent/rollout.jsonl"})
  end

  test "stdout source is not supported" do
    assert {:error, :stdout_not_supported} = CodexJsonl.parse({:stdout, "{}"})
  end
end
