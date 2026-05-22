defmodule Glorbo.CLI.Parsers.NativeV1Test do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Parsers.NativeV1

  test "parses tracked usage from json_file" do
    path =
      tmp_json!(~s({
        "tracked": true,
        "prompt_tokens": 12,
        "completion_tokens": 34,
        "model": "gpt-4.1",
        "tool_calls": {"read_file": 2},
        "audit_events": [
          {
            "action": "tool.read_file",
            "target": "notes.md",
            "detail": {"ok": true, "bytes": 42}
          }
        ]
      }))

    assert {:ok, usage} = NativeV1.parse({:json_file, path})
    assert usage.tracked == true
    assert usage.prompt_tokens == 12
    assert usage.completion_tokens == 34
    assert usage.model == "gpt-4.1"
    assert usage.tool_calls == %{"read_file" => 2}

    assert usage.audit_events == [
             %{
               action: "tool.read_file",
               target: "notes.md",
               detail: %{"ok" => true, "bytes" => 42}
             }
           ]
  end

  test "drops unknown or malformed audit events" do
    path =
      tmp_json!(~s({
        "tracked": true,
        "prompt_tokens": 1,
        "completion_tokens": 2,
        "tool_calls": {"write_file": 1, "made_up": 99},
        "audit_events": [
          {"action": "tool.write_file", "target": "notes.md", "detail": {"ok": true}},
          {"action": "tool.made_up", "target": "bad.md", "detail": {"ok": true}},
          {"action": "tool.grep", "detail": {"ok": true, "nested": {"nope": 1}}}
        ]
      }))

    assert {:ok, usage} = NativeV1.parse({:json_file, path})

    assert usage.audit_events == [
             %{action: "tool.write_file", target: "notes.md", detail: %{"ok" => true}},
             %{action: "tool.grep", detail: %{"ok" => true}}
           ]

    assert usage.tool_calls == %{"write_file" => 1}
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

  # C-032: usage.json is written by the sandboxed CLI and is
  # attacker-controlled. A planted multi-MB file must be refused by
  # the size cap before it is slurped into the dispatcher heap, not
  # decoded.
  test "refuses an oversized usage.json instead of reading it into memory" do
    # > 1 MiB cap; valid JSON so the only thing that can reject it is
    # the byte cap, not a decode error.
    padding = String.duplicate(" ", 1_048_576 + 1024)
    path = tmp_json!(~s({"tracked":true,"prompt_tokens":1,"completion_tokens":2}#{padding}))

    assert {:error, {:file_too_large, size, 1_048_576}} =
             NativeV1.parse({:json_file, path})

    assert size > 1_048_576
  end

  # C-032: a usage.json symlink (e.g. pointing at a host file or
  # /dev/zero) must be refused — the bounded reader lstat-gates.
  test "refuses a symlinked usage.json" do
    target = tmp_json!(~s({"tracked":true,"prompt_tokens":1,"completion_tokens":2}))

    link =
      Path.join(
        System.tmp_dir!(),
        "native-v1-link-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    File.ln_s!(target, link)
    on_exit(fn -> File.rm(link) end)

    assert {:error, {:not_regular_file, :symlink}} = NativeV1.parse({:json_file, link})
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
