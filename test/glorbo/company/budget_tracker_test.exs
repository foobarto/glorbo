defmodule Glorbo.Company.BudgetTrackerTest do
  use Glorbo.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Glorbo.Budget
  alias Glorbo.Budget.Ledger
  alias Glorbo.Company.BudgetTracker
  alias Glorbo.Test.TmpGlorboHome

  # Capturing audit fun — forwards every call to the test process mailbox.
  defp capturing_audit_fun(test_pid) do
    fn _server, entry -> send(test_pid, {:audit, entry}) end
  end

  # Helper — start a BudgetTracker with dep-injected budgets_fun + audit_fun.
  defp start_tracker!(caps, opts \\ []) do
    base = TmpGlorboHome.setup()
    company = "acme"
    # Scaffold the alerts dir so write! works.
    File.mkdir_p!(Path.join([base, "companies", company, "alerts"]))

    budgets_fun = fn slug -> Map.get(caps, slug) end
    test_pid = self()
    audit_fun = Keyword.get(opts, :audit_fun, capturing_audit_fun(test_pid))

    name = Glorbo.Test.UniqueName.gen("budget_tracker")

    pid =
      start_supervised!(
        {BudgetTracker,
         [
           name: name,
           company: company,
           base: base,
           budgets_fun: budgets_fun,
           audit_fun: audit_fun,
           alert_threshold_pct: Keyword.get(opts, :alert_threshold_pct, 80)
         ]}
      )

    # Share the Repo connection with the GenServer so its DB reads see our
    # sandbox writes.
    Sandbox.allow(Glorbo.Repo, self(), pid)

    {name, pid, base, company}
  end

  # ---------------------------------------------------------------------------
  # start_link + check_budget/2 basics (Tests 1–3)
  # ---------------------------------------------------------------------------

  test "Test 1: start_link/1 accepts required opts and process is alive" do
    {_name, pid, _base, _company} = start_tracker!(%{"alice" => 10_000})
    assert Process.alive?(pid)
  end

  test "Test 2: check_budget returns :ok when no prior usage" do
    {name, _pid, _base, _company} = start_tracker!(%{"alice" => 10_000})
    assert BudgetTracker.check_budget(name, "alice") == :ok
  end

  test "Test 3: check_budget returns :ok below alert threshold" do
    {name, _pid, _base, company} = start_tracker!(%{"alice" => 10_000})

    # Record 7000 cents usage (70% of 10000 — below 80% alert)
    ym = Ledger.month_bucket(DateTime.utc_now())

    Ledger.record!(%{
      company_slug: company,
      agent_slug: "alice",
      year_month: ym,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd_cents: 7_000
    })

    assert BudgetTracker.check_budget(name, "alice") == :ok
  end

  # ---------------------------------------------------------------------------
  # Alert threshold (Tests 4–5)
  # ---------------------------------------------------------------------------

  test "Test 4: check_budget returns {:alert, ...} at threshold + writes alert file + emits audit" do
    {name, _pid, base, company} = start_tracker!(%{"alice" => 10_000})

    ym = Ledger.month_bucket(DateTime.utc_now())

    Ledger.record!(%{
      company_slug: company,
      agent_slug: "alice",
      year_month: ym,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd_cents: 8_000
    })

    assert {:alert, 8_000, 10_000} = BudgetTracker.check_budget(name, "alice")

    alert_file = Path.join([base, "companies", company, "alerts", "alice-budget.md"])
    assert File.exists?(alert_file)

    content = File.read!(alert_file)
    assert content =~ "used_usd"
    assert content =~ "cap_usd"
    assert content =~ "threshold_pct: 80"
    assert content =~ "month: \"#{ym}\""

    assert_receive {:audit, %{action: "budget.alert"} = entry}, 500
    assert entry[:agent] == "alice" or entry["agent"] == "alice"
  end

  test "Test 5: second alert call same month is idempotent (no duplicate file write or audit)" do
    {name, _pid, base, company} = start_tracker!(%{"alice" => 10_000})

    ym = Ledger.month_bucket(DateTime.utc_now())

    Ledger.record!(%{
      company_slug: company,
      agent_slug: "alice",
      year_month: ym,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd_cents: 8_000
    })

    assert {:alert, _, _} = BudgetTracker.check_budget(name, "alice")

    # Drain first audit
    assert_receive {:audit, %{action: "budget.alert"}}, 500

    alert_file = Path.join([base, "companies", company, "alerts", "alice-budget.md"])
    first_mtime = File.stat!(alert_file).mtime

    # Second call — alert still returned but no new file write / no audit
    Process.sleep(1_100)
    assert {:alert, _, _} = BudgetTracker.check_budget(name, "alice")

    second_mtime = File.stat!(alert_file).mtime
    assert first_mtime == second_mtime

    refute_receive {:audit, %{action: "budget.alert"}}, 200
  end

  # ---------------------------------------------------------------------------
  # Hard stop (Test 6)
  # ---------------------------------------------------------------------------

  test "Test 6: check_budget returns {:stop, ...} at 100% + emits budget.hard_stop audit every call" do
    {name, _pid, _base, company} = start_tracker!(%{"alice" => 10_000})

    ym = Ledger.month_bucket(DateTime.utc_now())

    Ledger.record!(%{
      company_slug: company,
      agent_slug: "alice",
      year_month: ym,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd_cents: 10_000
    })

    assert {:stop, 10_000, 10_000} = BudgetTracker.check_budget(name, "alice")
    assert_receive {:audit, %{action: "budget.hard_stop"} = entry}, 500
    agent = entry[:agent] || entry["agent"]
    assert agent == "alice"

    # Second call also emits (denied dispatches deserve audit)
    assert {:stop, _, _} = BudgetTracker.check_budget(name, "alice")
    assert_receive {:audit, %{action: "budget.hard_stop"}}, 500
  end

  # ---------------------------------------------------------------------------
  # record/2 usage recording (Tests 7–9, 12)
  # ---------------------------------------------------------------------------

  test "Test 7: record/2 calls Ledger.record! with computed cost_usd_cents" do
    {name, _pid, _base, company} = start_tracker!(%{"alice" => 10_000})

    BudgetTracker.record(name, %{
      agent_slug: "alice",
      provider: "claude-code",
      model: "claude-opus-4-6",
      prompt_tokens: 1_000_000,
      completion_tokens: 0,
      task_id: "t-001"
    })

    # Synchronise — record/2 is cast; ping via a call so GenServer drains.
    BudgetTracker.reload_config(name)

    ym = Ledger.month_bucket(DateTime.utc_now())
    row = Repo.get_by(Budget, company_slug: company, agent_slug: "alice", year_month: ym)
    assert row
    assert row.prompt_tokens == 1_000_000
    assert row.cost_usd_cents == 1_500
  end

  test "Test 8: record/2 emits budget.usage audit with payload" do
    {name, _pid, _base, _company} = start_tracker!(%{"alice" => 10_000})

    BudgetTracker.record(name, %{
      agent_slug: "alice",
      provider: "claude-code",
      model: "claude-opus-4-6",
      prompt_tokens: 100,
      completion_tokens: 50,
      task_id: "t-002"
    })

    assert_receive {:audit, %{action: "budget.usage"} = entry}, 1_000
    agent = entry[:agent] || entry["agent"]
    task_id = entry[:task_id] || entry["task_id"]
    model = entry[:model] || entry["model"]
    prompt = entry[:prompt_tokens] || entry["prompt_tokens"]
    completion = entry[:completion_tokens] || entry["completion_tokens"]
    cost = entry[:cost_usd_cents] || entry["cost_usd_cents"]

    assert agent == "alice"
    assert task_id == "t-002"
    assert model == "claude-opus-4-6"
    assert prompt == 100
    assert completion == 50
    assert is_integer(cost) and cost >= 0
  end

  test "Test 9: record/2 with zero tokens still creates/updates a row" do
    {name, _pid, _base, company} = start_tracker!(%{"alice" => 10_000})

    BudgetTracker.record(name, %{
      agent_slug: "alice",
      provider: "claude-code",
      model: "claude-opus-4-6",
      prompt_tokens: 0,
      completion_tokens: 0,
      task_id: "t-003"
    })

    BudgetTracker.reload_config(name)

    ym = Ledger.month_bucket(DateTime.utc_now())
    row = Repo.get_by(Budget, company_slug: company, agent_slug: "alice", year_month: ym)
    assert row
    assert row.cost_usd_cents == 0
  end

  test "Test 12: concurrent record/2 from 20 Tasks produces summed totals" do
    {name, pid, _base, company} = start_tracker!(%{"alice" => 10_000})

    Sandbox.mode(Glorbo.Repo, {:shared, self()})
    # Re-allow the tracker's process now that we are shared.
    Sandbox.allow(Glorbo.Repo, self(), pid)

    tasks =
      for i <- 1..20 do
        Task.async(fn ->
          BudgetTracker.record(name, %{
            agent_slug: "alice",
            provider: "claude-code",
            model: "claude-opus-4-6",
            prompt_tokens: 100,
            completion_tokens: 50,
            task_id: "t-#{i}"
          })
        end)
      end

    Enum.each(tasks, &Task.await(&1, 10_000))

    # Drain — ensure all casts flushed.
    BudgetTracker.reload_config(name)

    ym = Ledger.month_bucket(DateTime.utc_now())
    row = Repo.get_by(Budget, company_slug: company, agent_slug: "alice", year_month: ym)
    assert row
    assert row.prompt_tokens == 20 * 100
    assert row.completion_tokens == 20 * 50
  end

  # ---------------------------------------------------------------------------
  # reload_config (Test 10)
  # ---------------------------------------------------------------------------

  test "Test 10: reload_config clears caps cache so budgets_fun is re-invoked" do
    # Use a mutable ETS table as the cap source.
    table = :ets.new(:caps, [:set, :public])
    :ets.insert(table, {"alice", 10_000})

    budgets_fun = fn slug ->
      case :ets.lookup(table, slug) do
        [{^slug, cap}] -> cap
        [] -> nil
      end
    end

    base = TmpGlorboHome.setup()
    company = "acme"
    File.mkdir_p!(Path.join([base, "companies", company, "alerts"]))

    test_pid = self()
    name = Glorbo.Test.UniqueName.gen("budget_tracker")

    pid =
      start_supervised!(
        {BudgetTracker,
         [
           name: name,
           company: company,
           base: base,
           budgets_fun: budgets_fun,
           audit_fun: capturing_audit_fun(test_pid),
           alert_threshold_pct: 80
         ]}
      )

    Sandbox.allow(Glorbo.Repo, self(), pid)

    ym = Ledger.month_bucket(DateTime.utc_now())

    # Start at 9_500 (under old cap 10_000 — 95% but over 80% alert threshold)
    Ledger.record!(%{
      company_slug: company,
      agent_slug: "alice",
      year_month: ym,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd_cents: 9_500
    })

    # Under old cap: alert (9500/10000 = 95%), not stop
    assert {:alert, 9_500, 10_000} = BudgetTracker.check_budget(name, "alice")

    # Raise the cap to 20_000
    :ets.insert(table, {"alice", 20_000})

    # Without reload — tracker still uses cached 10_000 cap
    # With reload — fresh cap 20_000 means 9500 < 16_000 (80% of 20_000) -> :ok
    assert :ok = BudgetTracker.reload_config(name)
    assert :ok = BudgetTracker.check_budget(name, "alice")
  end

  # ---------------------------------------------------------------------------
  # Crash recovery (Test 11)
  # ---------------------------------------------------------------------------

  test "Test 11: state rebuilds from Repo + filesystem after crash" do
    # Use plain start_link (unsupervised) so we control the lifecycle directly.
    # D-45 says BudgetTracker is stateless across crashes — rebuild from disk.
    caps = %{"alice" => 10_000}
    budgets_fun = fn slug -> Map.get(caps, slug) end
    base = TmpGlorboHome.setup()
    company = "acme"
    File.mkdir_p!(Path.join([base, "companies", company, "alerts"]))

    test_pid = self()

    start_tracker = fn name ->
      {:ok, pid} =
        BudgetTracker.start_link(
          name: name,
          company: company,
          base: base,
          budgets_fun: budgets_fun,
          audit_fun: capturing_audit_fun(test_pid)
        )

      # Unlink so a :kill on pid doesn't cascade to the test process.
      Process.unlink(pid)
      Sandbox.allow(Glorbo.Repo, self(), pid)
      pid
    end

    name1 = Glorbo.Test.UniqueName.gen("bt_crash_1")
    pid1 = start_tracker.(name1)

    ym = Ledger.month_bucket(DateTime.utc_now())

    Ledger.record!(%{
      company_slug: company,
      agent_slug: "alice",
      year_month: ym,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd_cents: 5_000
    })

    assert :ok = BudgetTracker.check_budget(name1, "alice")

    # Kill and wait for the process to actually terminate (releasing the name).
    ref = Process.monitor(pid1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}, 1_000

    # Fresh tracker — state rebuilds from Repo (5000 < 8000 alert threshold).
    name2 = Glorbo.Test.UniqueName.gen("bt_crash_2")
    pid2 = start_tracker.(name2)
    on_exit(fn -> if Process.alive?(pid2), do: Process.exit(pid2, :normal) end)
    assert pid2 != pid1
    assert :ok = BudgetTracker.check_budget(name2, "alice")
  end

  # ---------------------------------------------------------------------------
  # Wave 34: alert filename is canonical (defense-in-depth)
  # ---------------------------------------------------------------------------

  test "wave 34: rehydrate uses filename, not frontmatter, for the agent slug" do
    base = TmpGlorboHome.setup()
    company = "acme"
    alerts_dir = Path.join([base, "companies", company, "alerts"])
    File.mkdir_p!(alerts_dir)

    # Write a tampered alert file: filename says editor, frontmatter
    # claims agent: ceo. Pre-wave-34 this would have populated the
    # MapSet with {ceo, <month>}, suppressing real ceo alerts. Post-fix
    # it populates {editor, <month>} (the filename is canonical).
    ym = Ledger.month_bucket(DateTime.utc_now())

    File.write!(Path.join(alerts_dir, "editor-budget.md"), """
    ---
    agent: "ceo"
    month: "#{ym}"
    used_usd: 10.00
    cap_usd: 10.00
    threshold_pct: 80
    created_at: "2026-04-26T10:00:00Z"
    ---
    """)

    caps = %{"ceo" => 10_000, "editor" => 10_000}
    budgets_fun = fn slug -> Map.get(caps, slug) end

    test_pid = self()

    {:ok, pid} =
      BudgetTracker.start_link(
        name: Glorbo.Test.UniqueName.gen("bt_wave34"),
        company: company,
        base: base,
        budgets_fun: budgets_fun,
        audit_fun: capturing_audit_fun(test_pid)
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    Sandbox.allow(Glorbo.Repo, self(), pid)

    state = :sys.get_state(pid)

    # The filename was `editor-budget.md` — the rehydrated key must
    # be {"editor", <month>}, NOT the frontmatter's {"ceo", <month>}.
    assert MapSet.member?(state.alerts_fired, {"editor", ym})
    refute MapSet.member?(state.alerts_fired, {"ceo", ym})
  end

  # ---------------------------------------------------------------------------
  # Unconfigured agent cap (Test 13)
  # ---------------------------------------------------------------------------

  test "Test 13: no cap (budgets_fun returns nil) -> :ok (unlimited)" do
    {name, _pid, _base, company} = start_tracker!(%{})

    # Record way over any plausible cap
    ym = Ledger.month_bucket(DateTime.utc_now())

    Ledger.record!(%{
      company_slug: company,
      agent_slug: "ghost",
      year_month: ym,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd_cents: 1_000_000
    })

    assert :ok = BudgetTracker.check_budget(name, "ghost")
  end

  test "default budgets_fun reads budget.monthly_usd from AGENT.md" do
    base = TmpGlorboHome.setup()
    company = "acme"
    agent_dir = Path.join([base, "companies", company, "agents", "alice"])
    File.mkdir_p!(Path.join([base, "companies", company, "alerts"]))
    File.mkdir_p!(agent_dir)

    File.write!(Path.join(agent_dir, "AGENT.md"), """
    ---
    kind: agent/v1
    role: Engineer
    provider: claude-code
    model: claude-opus-4-6
    network: proxy
    budget:
      monthly_usd: 10.00
    ---
    """)

    name = Glorbo.Test.UniqueName.gen("budget_tracker_file")

    pid =
      start_supervised!(
        {BudgetTracker,
         [
           name: name,
           company: company,
           base: base,
           audit_fun: capturing_audit_fun(self())
         ]}
      )

    Sandbox.allow(Glorbo.Repo, self(), pid)

    ym = Ledger.month_bucket(DateTime.utc_now())

    Ledger.record!(%{
      company_slug: company,
      agent_slug: "alice",
      year_month: ym,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd_cents: 800
    })

    assert {:alert, 800, 1_000} = BudgetTracker.check_budget(name, "alice")
  end

  test "same agent slug in another company does not bleed into this tracker" do
    {name, _pid, _base, company} = start_tracker!(%{"alice" => 1_000})
    ym = Ledger.month_bucket(DateTime.utc_now())

    Ledger.record!(%{
      company_slug: "beta",
      agent_slug: "alice",
      year_month: ym,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd_cents: 9_000
    })

    Ledger.record!(%{
      company_slug: company,
      agent_slug: "alice",
      year_month: ym,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd_cents: 100
    })

    assert :ok = BudgetTracker.check_budget(name, "alice")
  end
end
