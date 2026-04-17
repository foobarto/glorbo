defmodule Glorbo.CLI.Parsers.ClaudeJsonlTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Parsers.ClaudeJsonl

  @fixture "test/fixtures/claude_session_sample.jsonl"

  test "sums input + cache_creation + cache_read + output_tokens" do
    assert {:ok, %{prompt_tokens: 46_337, completion_tokens: 73, model: "claude-opus-4-6"}} =
             ClaudeJsonl.parse({:jsonl_file, @fixture})
  end

  test "malformed JSONL line is skipped, remaining totals returned" do
    path =
      Path.join(
        System.tmp_dir!(),
        "claude_malformed_#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, File.read!(@fixture) <> "not-json\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{prompt_tokens: 46_337, completion_tokens: 73}} =
             ClaudeJsonl.parse({:jsonl_file, path})
  end

  test "missing file returns {:error, :enoent}" do
    assert {:error, :enoent} =
             ClaudeJsonl.parse({:jsonl_file, "/nonexistent/claude.jsonl"})
  end

  test "stdout source is not supported" do
    assert {:error, :stdout_not_supported} = ClaudeJsonl.parse({:stdout, "{}"})
  end
end
