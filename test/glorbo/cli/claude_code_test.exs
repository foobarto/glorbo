defmodule Glorbo.CLI.Adapter.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Spec
  alias Glorbo.CLI.Adapter.ClaudeCode

  @fixture "test/fixtures/claude_session_sample.jsonl"

  defp spec do
    %Spec{
      slug: "engineer",
      company: "acme",
      role: "x",
      provider: "claude-code",
      model: "claude-opus-4-6",
      permissions: [],
      heartbeat: nil,
      network: :none,
      skills: [],
      budget_usd_cents_month: nil,
      timeout_seconds: 300,
      file_path: "/tmp/agent.md"
    }
  end

  # ---------------------------------------------------------------------------
  # CC1 — binary/0
  # ---------------------------------------------------------------------------

  test "CC1: binary/0 returns the executable path or nil" do
    # On dev host claude is installed; in CI it may or may not be. Accept either
    # a non-empty binary path or nil.
    case ClaudeCode.binary() do
      nil -> assert true
      path -> assert is_binary(path) and String.length(path) > 0
    end
  end

  # ---------------------------------------------------------------------------
  # CC2 — args/3
  # ---------------------------------------------------------------------------

  test "CC2: args/3 returns --print --model <model> --output-format text" do
    argv = ClaudeCode.args(spec(), "/ws/.glorbo-run/t1/task-prompt.md", [])
    assert argv == ["--print", "--model", "claude-opus-4-6", "--output-format", "text"]
  end

  # ---------------------------------------------------------------------------
  # CC3 — env/2
  # ---------------------------------------------------------------------------

  test "CC3: env/2 returns CLAUDE_CONFIG_DIR under workspace" do
    env = ClaudeCode.env(spec(), "/workspace")
    assert env == %{"CLAUDE_CONFIG_DIR" => "/workspace/.glorbo-claude"}
  end

  # ---------------------------------------------------------------------------
  # CC4 — usage_path/2
  # ---------------------------------------------------------------------------

  test "CC4: usage_path/2 returns {:jsonl_dir, <encoded path>}" do
    assert {:jsonl_dir, dir} = ClaudeCode.usage_path(spec(), "/workspace")
    assert dir == "/workspace/.glorbo-claude/projects/-workspace"
  end

  # ---------------------------------------------------------------------------
  # CC5 — parse_usage/1 against live-shaped JSONL fixture
  # ---------------------------------------------------------------------------

  test "CC5: parse_usage/1 sums input + cache_creation + cache_read + output_tokens" do
    assert {:ok, %{prompt_tokens: 46_337, completion_tokens: 73, model: "claude-opus-4-6"}} =
             ClaudeCode.parse_usage({:jsonl_file, @fixture})
  end

  # ---------------------------------------------------------------------------
  # CC6 — malformed lines skipped
  # ---------------------------------------------------------------------------

  test "CC6: malformed JSONL line is skipped, remaining totals returned" do
    path =
      Path.join(System.tmp_dir!(), "claude_malformed_#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, File.read!(@fixture) <> "not-json\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{prompt_tokens: 46_337, completion_tokens: 73}} =
             ClaudeCode.parse_usage({:jsonl_file, path})
  end

  # ---------------------------------------------------------------------------
  # CC7 — nonexistent path
  # ---------------------------------------------------------------------------

  test "CC7: parse_usage/1 on missing file returns {:error, :enoent}" do
    assert {:error, :enoent} =
             ClaudeCode.parse_usage({:jsonl_file, "/nonexistent/claude.jsonl"})
  end

  # ---------------------------------------------------------------------------
  # CC8 — fixture contains the expected real-shaped fields
  # ---------------------------------------------------------------------------

  test "CC8: fixture contains cache_creation_input_tokens + assistant turns" do
    contents = File.read!(@fixture)
    assert contents =~ "cache_creation_input_tokens"
    assert contents =~ ~s|"type":"assistant"|
    # At least 3 assistant turns
    assistant_count =
      contents |> String.split("\n") |> Enum.count(&String.contains?(&1, ~s|"type":"assistant"|))

    assert assistant_count >= 3
  end
end
