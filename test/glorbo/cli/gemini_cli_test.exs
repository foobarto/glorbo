defmodule Glorbo.CLI.Adapter.GeminiCliTest do
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Spec
  alias Glorbo.CLI.Adapter.GeminiCli

  @fixture "test/fixtures/gemini_stdout_sample.json"

  defp spec do
    %Spec{
      slug: "researcher",
      company: "acme",
      role: "x",
      provider: "gemini-cli",
      model: "gemini-2.5-pro",
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
  # G1 — binary/0
  # ---------------------------------------------------------------------------

  test "G1: binary/0 returns path or nil" do
    case GeminiCli.binary() do
      nil -> assert true
      path -> assert is_binary(path)
    end
  end

  # ---------------------------------------------------------------------------
  # G2 — args/3
  # ---------------------------------------------------------------------------

  test "G2: args/3 returns -m <model> --output-format json --approval-mode yolo" do
    assert GeminiCli.args(spec(), "/ws/prompt.md", []) ==
             ["-m", "gemini-2.5-pro", "--output-format", "json", "--approval-mode", "yolo"]
  end

  # ---------------------------------------------------------------------------
  # G3 — env/2 (empty until gemini documents an env-var equivalent)
  # ---------------------------------------------------------------------------

  test "G3: env/2 returns empty map (no documented env override)" do
    assert GeminiCli.env(spec(), "/workspace") == %{}
  end

  # ---------------------------------------------------------------------------
  # G4 — usage_path/2 returns :stdout
  # ---------------------------------------------------------------------------

  test "G4: usage_path/2 returns :stdout" do
    assert GeminiCli.usage_path(spec(), "/workspace") == :stdout
  end

  # ---------------------------------------------------------------------------
  # G5 — parse_usage against live-shaped stdout fixture
  # ---------------------------------------------------------------------------

  test "G5: parse_usage/1 sums prompt+cached and candidates+thoughts+tool" do
    blob = File.read!(@fixture)

    assert {:ok, %{prompt_tokens: 46_202, completion_tokens: 174, model: "gemini-2.5-pro"}} =
             GeminiCli.parse_usage({:stdout, blob})
  end

  # ---------------------------------------------------------------------------
  # G6 — invalid JSON
  # ---------------------------------------------------------------------------

  test "G6: parse_usage/1 on non-JSON returns {:error, :json_decode_error}" do
    assert {:error, :json_decode_error} = GeminiCli.parse_usage({:stdout, "not json"})
  end

  # ---------------------------------------------------------------------------
  # G7 — missing stats
  # ---------------------------------------------------------------------------

  test "G7: parse_usage/1 on JSON without stats returns {:error, :no_stats}" do
    assert {:error, :no_stats} = GeminiCli.parse_usage({:stdout, ~s|{"response":"hi"}|})
  end

  # ---------------------------------------------------------------------------
  # G8 — defensive multi-model summing
  # ---------------------------------------------------------------------------

  test "multi-model stats: totals are summed across all model keys" do
    multi =
      ~s"""
      {"stats":{"models":{
        "a":{"tokens":{"prompt":100,"candidates":10,"cached":50,"thoughts":5,"tool":2}},
        "b":{"tokens":{"prompt":200,"candidates":20,"cached":100,"thoughts":10,"tool":3}}
      }}}
      """

    assert {:ok, %{prompt_tokens: 450, completion_tokens: 50}} =
             GeminiCli.parse_usage({:stdout, multi})
  end
end
