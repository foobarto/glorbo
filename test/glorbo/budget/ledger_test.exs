defmodule Glorbo.Budget.LedgerTest do
  use Glorbo.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Glorbo.Budget
  alias Glorbo.Budget.Ledger

  # ---------------------------------------------------------------------------
  # compute_cost_cents/4 (Tests 1–6)
  # ---------------------------------------------------------------------------

  describe "compute_cost_cents/4" do
    test "Test 1: opus-4-6 input-only 1 Mtok -> 1500 cents" do
      # 1_000_000 input tokens * $15/Mtok = $15.00 = 1500 cents
      assert Ledger.compute_cost_cents("claude-code", "claude-opus-4-6", 1_000_000, 0) == 1500
    end

    test "Test 2: opus-4-6 output-only 1 Mtok -> 7500 cents" do
      # 1_000_000 output tokens * $75/Mtok = $75.00 = 7500 cents
      assert Ledger.compute_cost_cents("claude-code", "claude-opus-4-6", 0, 1_000_000) == 7500
    end

    test "Test 3: opus-4-6 mixed 2.5M in + 0.5M out -> 7500 cents" do
      # 2.5 * 15 * 100 = 3750 cents input
      # 0.5 * 75 * 100 = 3750 cents output
      # total = 7500 cents
      assert Ledger.compute_cost_cents("claude-code", "claude-opus-4-6", 2_500_000, 500_000) ==
               7500
    end

    test "Test 4: gemini-2.5-pro 500k input -> 63 cents (half-up rounding)" do
      # 0.5 * 1.25 * 100 = 62.5 -> trunc(x + 0.5) = trunc(63.0) = 63
      assert Ledger.compute_cost_cents("gemini-cli", "gemini-2.5-pro", 500_000, 0) == 63
    end

    test "Test 5: unknown provider returns 0 and emits a warning" do
      log =
        capture_log(fn ->
          assert Ledger.compute_cost_cents("unknown-provider", "some-model", 1000, 1000) == 0
        end)

      assert log =~ "unknown-provider"
    end

    test "Test 6: known provider + unlisted model returns 0 and warns" do
      log =
        capture_log(fn ->
          assert Ledger.compute_cost_cents("claude-code", "unlisted-model", 1000, 1000) == 0
        end)

      assert log =~ "unlisted-model"
    end
  end

  # ---------------------------------------------------------------------------
  # month_bucket/1 (Tests 7–9)
  # ---------------------------------------------------------------------------

  describe "month_bucket/1" do
    test "Test 7: DateTime mid-month -> YYYY-MM" do
      assert Ledger.month_bucket(~U[2026-04-16 12:00:00Z]) == "2026-04"
    end

    test "Test 8: DateTime year-end edge" do
      assert Ledger.month_bucket(~U[2026-12-31 23:59:59Z]) == "2026-12"
    end

    test "Test 9: plain Date" do
      assert Ledger.month_bucket(~D[2026-01-01]) == "2026-01"
    end
  end

  # ---------------------------------------------------------------------------
  # record!/1 + fetch/2 (Tests 10–14)
  # ---------------------------------------------------------------------------

  describe "record!/1" do
    test "Test 10: inserts a new row when none exists" do
      usage = %{
        agent_slug: "alice",
        provider: "claude-code",
        model: "claude-opus-4-6",
        prompt_tokens: 100,
        completion_tokens: 50,
        year_month: "2026-04",
        cost_usd_cents: 10
      }

      Ledger.record!(usage)

      row = Repo.get_by(Budget, agent_slug: "alice", year_month: "2026-04")
      assert row
      assert row.prompt_tokens == 100
      assert row.completion_tokens == 50
      assert row.cost_usd_cents == 10
    end

    test "Test 11: two calls for same {slug, ym} produce ONE row with summed totals" do
      base = %{
        agent_slug: "bob",
        provider: "claude-code",
        model: "claude-opus-4-6",
        year_month: "2026-04"
      }

      Ledger.record!(
        Map.merge(base, %{prompt_tokens: 100, completion_tokens: 50, cost_usd_cents: 10})
      )

      Ledger.record!(
        Map.merge(base, %{prompt_tokens: 200, completion_tokens: 300, cost_usd_cents: 25})
      )

      count =
        Budget
        |> where([b], b.agent_slug == "bob")
        |> Repo.aggregate(:count)

      assert count == 1

      row = Repo.get_by(Budget, agent_slug: "bob", year_month: "2026-04")
      assert row.prompt_tokens == 300
      assert row.completion_tokens == 350
      assert row.cost_usd_cents == 35
    end

    test "Test 12: concurrent writes from 10 Tasks sum correctly (atomic upsert)" do
      # Switch sandbox to shared mode so async Tasks share our connection.
      Sandbox.mode(Glorbo.Repo, {:shared, self()})

      base = %{
        agent_slug: "carol",
        provider: "claude-code",
        model: "claude-opus-4-6",
        year_month: "2026-04"
      }

      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Ledger.record!(
              Map.merge(base, %{prompt_tokens: 1000, completion_tokens: 1000, cost_usd_cents: 1})
            )
          end)
        end

      Enum.each(tasks, &Task.await(&1, 10_000))

      count =
        Budget
        |> where([b], b.agent_slug == "carol")
        |> Repo.aggregate(:count)

      assert count == 1

      row = Repo.get_by(Budget, agent_slug: "carol", year_month: "2026-04")
      assert row.prompt_tokens == 10_000
      assert row.completion_tokens == 10_000
      assert row.cost_usd_cents == 10
    end

    test "Test 13: fetch/2 returns row or nil" do
      usage = %{
        agent_slug: "dave",
        provider: "claude-code",
        model: "claude-opus-4-6",
        prompt_tokens: 5,
        completion_tokens: 5,
        year_month: "2026-04",
        cost_usd_cents: 1
      }

      Ledger.record!(usage)

      assert %Budget{agent_slug: "dave"} = Ledger.fetch("dave", "2026-04")
      assert Ledger.fetch("dave", "2025-01") == nil
    end

    test "Test 14: negative prompt_tokens raises" do
      usage = %{
        agent_slug: "eve",
        provider: "claude-code",
        model: "claude-opus-4-6",
        prompt_tokens: -1,
        completion_tokens: 0,
        year_month: "2026-04",
        cost_usd_cents: 0
      }

      assert_raise Ecto.InvalidChangesetError, fn -> Ledger.record!(usage) end
    end
  end
end
