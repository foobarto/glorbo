defmodule Glorbo.CLI.Parsers.NativeV1Test do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Parsers.NativeV1

  test "parses tracked usage from json_file" do
    path =
      tmp_json!(
        ~s({"tracked":true,"prompt_tokens":12,"completion_tokens":34,"model":"gpt-4.1","tool_calls":{"read_file":2}})
      )

    assert {:ok, usage} = NativeV1.parse({:json_file, path})
    assert usage.tracked == true
    assert usage.prompt_tokens == 12
    assert usage.completion_tokens == 34
    assert usage.model == "gpt-4.1"
    assert usage.tool_calls == %{"read_file" => 2}
  end

  test "parses untracked usage from json_file" do
    path =
      tmp_json!(~s({"tracked":false,"prompt_tokens":0,"completion_tokens":0,"model":"llama3.1"}))

    assert {:ok, usage} = NativeV1.parse({:json_file, path})
    assert usage.tracked == false
    assert usage.prompt_tokens == 0
    assert usage.completion_tokens == 0
    assert usage.model == "llama3.1"
  end

  test "returns :enoent for missing files" do
    assert {:error, :enoent} = NativeV1.parse({:json_file, "/nonexistent/native-usage.json"})
  end

  test "bubbles json decode errors" do
    path = tmp_json!("not json")
    assert {:error, %Jason.DecodeError{}} = NativeV1.parse({:json_file, path})
  end

  test "rejects malformed usage shape" do
    path = tmp_json!(~s({"tracked":"yes","prompt_tokens":1,"completion_tokens":2}))
    assert {:error, :invalid_usage_json} = NativeV1.parse({:json_file, path})
  end

  test "rejects wrong source kinds" do
    assert {:error, :stdout_not_supported} = NativeV1.parse({:stdout, "{}"})
    assert {:error, :jsonl_not_supported} = NativeV1.parse({:jsonl_file, "/tmp/x.jsonl"})
  end

  defp tmp_json!(body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "native-v1-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
