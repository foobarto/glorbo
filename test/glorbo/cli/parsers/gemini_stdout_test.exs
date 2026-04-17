defmodule Glorbo.CLI.Parsers.GeminiStdoutTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Parsers.GeminiStdout

  @fixture "test/fixtures/gemini_stdout_sample.json"

  test "sums prompt+cached and candidates+thoughts+tool" do
    blob = File.read!(@fixture)

    assert {:ok, %{prompt_tokens: 46_202, completion_tokens: 174, model: "gemini-2.5-pro"}} =
             GeminiStdout.parse({:stdout, blob})
  end

  test "non-JSON returns {:error, :json_decode_error}" do
    assert {:error, :json_decode_error} = GeminiStdout.parse({:stdout, "not json"})
  end

  test "JSON without stats returns {:error, :no_stats}" do
    assert {:error, :no_stats} = GeminiStdout.parse({:stdout, ~s|{"response":"hi"}|})
  end

  test "multi-model stats are summed across all model keys" do
    multi =
      ~s"""
      {"stats":{"models":{
        "a":{"tokens":{"prompt":100,"candidates":10,"cached":50,"thoughts":5,"tool":2}},
        "b":{"tokens":{"prompt":200,"candidates":20,"cached":100,"thoughts":10,"tool":3}}
      }}}
      """

    assert {:ok, %{prompt_tokens: 450, completion_tokens: 50}} =
             GeminiStdout.parse({:stdout, multi})
  end

  test "jsonl source is not supported" do
    assert {:error, :jsonl_not_supported} = GeminiStdout.parse({:jsonl_file, "/nope.jsonl"})
  end
end
