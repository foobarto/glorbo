defmodule Glorbo.CLI.Adapter.CodexTest do
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Spec
  alias Glorbo.CLI.Adapter.Codex

  @fixture "test/fixtures/codex_rollout_sample.jsonl"

  defp spec do
    %Spec{
      slug: "coder",
      company: "acme",
      role: "x",
      provider: "codex",
      model: "gpt-5",
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
  # CX1 — binary/0
  # ---------------------------------------------------------------------------

  test "CX1: binary/0 returns path or nil" do
    case Codex.binary() do
      nil -> assert true
      path -> assert is_binary(path)
    end
  end

  # ---------------------------------------------------------------------------
  # CX2 — args/3
  # ---------------------------------------------------------------------------

  test "CX2: args/3 returns exec --json --model <m> --skip-git-repo-check -" do
    argv = Codex.args(spec(), "/ws/prompt.md", [])
    assert argv == ["exec", "--json", "--model", "gpt-5", "--skip-git-repo-check", "-"]
  end

  # ---------------------------------------------------------------------------
  # CX3 — env/2
  # ---------------------------------------------------------------------------

  test "CX3: env/2 returns CODEX_HOME under workspace" do
    assert Codex.env(spec(), "/workspace") == %{"CODEX_HOME" => "/workspace/.glorbo-codex"}
  end

  # ---------------------------------------------------------------------------
  # CX4 — usage_path/2
  # ---------------------------------------------------------------------------

  test "CX4: usage_path/2 returns {:jsonl_dir, .../sessions}" do
    assert Codex.usage_path(spec(), "/workspace") ==
             {:jsonl_dir, "/workspace/.glorbo-codex/sessions"}
  end

  # ---------------------------------------------------------------------------
  # CX5 + CX6 — Pitfall 10: LAST token_count event, not summed
  # ---------------------------------------------------------------------------

  test "CX5+CX6: parse_usage uses LAST token_count event cumulative totals (NOT summed)" do
    # Fixture has 3 cumulative events:
    #   1st: {input=1000, cached=0, output=50, reasoning=10}
    #   2nd: {input=5000, cached=2000, output=120, reasoning=30}
    #   3rd: {input=12007, cached=6528, output=274, reasoning=44}
    # Adapter must use ONLY the 3rd: prompt = 12007+6528 = 18535, completion = 274+44 = 318.
    assert {:ok, %{prompt_tokens: 18_535, completion_tokens: 318, model: nil}} =
             Codex.parse_usage({:jsonl_file, @fixture})
  end

  test "CX5 negative: summing all events would exceed the last-event figures" do
    # Sanity: the sum across all events would be input=18007, cached=8528,
    # output=444, reasoning=84 → prompt 26535, completion 528.
    # A correct LAST-event adapter returns the smaller {18535, 318}.
    {:ok, usage} = Codex.parse_usage({:jsonl_file, @fixture})

    # If summed: prompt would be >= 26535
    refute usage.prompt_tokens >= 26_535
    # Exact last-event values
    assert usage.prompt_tokens == 18_535
    assert usage.completion_tokens == 318
  end

  # ---------------------------------------------------------------------------
  # CX7 — no token_count events
  # ---------------------------------------------------------------------------

  test "CX7: parse_usage with zero token_count events returns {:error, :no_token_count}" do
    path = Path.join(System.tmp_dir!(), "codex_empty_#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, """
    {"timestamp":"2026-04-13T00:00:00Z","type":"event_msg","payload":{"type":"user_message","info":{"text":"hi"}}}
    """)

    on_exit(fn -> File.rm(path) end)

    assert {:error, :no_token_count} = Codex.parse_usage({:jsonl_file, path})
  end

  # ---------------------------------------------------------------------------
  # CX8 — malformed line tolerated
  # ---------------------------------------------------------------------------

  test "CX8: malformed NDJSON line is skipped; remaining events processed" do
    path =
      Path.join(System.tmp_dir!(), "codex_malformed_#{System.unique_integer([:positive])}.jsonl")

    content = File.read!(@fixture) <> "garbage-line\n"
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{prompt_tokens: 18_535, completion_tokens: 318}} =
             Codex.parse_usage({:jsonl_file, path})
  end

  # ---------------------------------------------------------------------------
  # Missing file
  # ---------------------------------------------------------------------------

  test "parse_usage on nonexistent path returns {:error, :enoent}" do
    assert {:error, :enoent} = Codex.parse_usage({:jsonl_file, "/nonexistent/rollout.jsonl"})
  end
end
