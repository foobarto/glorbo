defmodule Glorbo.Company.SchedulerTest do
  use ExUnit.Case, async: false

  alias Glorbo.Company.Scheduler

  defp capturing_audit_fun(pid) do
    fn _server, entry -> send(pid, {:audit, entry}) end
  end

  defp capturing_send_after_fun(pid) do
    fn dest, msg, delay ->
      send(pid, {:send_after, dest, msg, delay})
      # Return a ref so the scheduler can store it; make_ref is enough for
      # the cancel test since we never actually arm the real timer.
      make_ref()
    end
  end

  defp start_sched!(opts) do
    name = Glorbo.Test.UniqueName.gen("scheduler")

    pid =
      start_supervised!(
        {Scheduler,
         Keyword.merge(
           [
             name: name,
             company: "acme",
             audit_fun: capturing_audit_fun(self())
           ],
           opts
         )}
      )

    {name, pid}
  end

  # ---------------------------------------------------------------------------
  # S1 — start + register happy path
  # ---------------------------------------------------------------------------

  test "S1: start_link + register with valid cron returns :ok" do
    clock = ~U[2026-04-16 12:00:00Z]

    {name, pid} =
      start_sched!(
        clock_fun: fn -> clock end,
        send_after_fun: capturing_send_after_fun(self())
      )

    assert Process.alive?(pid)

    assert :ok =
             Scheduler.register(name, "engineer", %{
               cron: "*/30 * * * *",
               dispatch_fun: fn _ -> :ok end
             })
  end

  # ---------------------------------------------------------------------------
  # S2 — invalid cron
  # ---------------------------------------------------------------------------

  test "S2: invalid cron returns {:error, :invalid_cron} + emits audit + stays alive" do
    clock = ~U[2026-04-16 12:00:00Z]

    {name, pid} =
      start_sched!(
        clock_fun: fn -> clock end,
        send_after_fun: capturing_send_after_fun(self())
      )

    assert {:error, :invalid_cron} =
             Scheduler.register(name, "engineer", %{
               cron: "not a cron",
               dispatch_fun: fn _ -> :ok end
             })

    assert_receive {:audit, %{action: "scheduler.invalid_cron"} = entry}, 500
    assert (entry[:agent] || entry["agent"]) == "engineer"
    assert Process.alive?(pid)
  end

  # ---------------------------------------------------------------------------
  # S3 — send_after receives correct delay
  # ---------------------------------------------------------------------------

  test "S3: send_after_fun captures (pid, msg, delay_ms) based on clock_fun" do
    # 12:00:01 + "*/30 * * * *" -> next run 12:30:00 -> delay ~1_799_000 ms
    clock = ~U[2026-04-16 12:00:01Z]

    {name, _pid} =
      start_sched!(
        clock_fun: fn -> clock end,
        send_after_fun: capturing_send_after_fun(self())
      )

    :ok =
      Scheduler.register(name, "engineer", %{
        cron: "*/30 * * * *",
        dispatch_fun: fn _ -> :ok end
      })

    assert_receive {:send_after, _dest, {:heartbeat, "engineer"}, delay_ms}, 500
    # Should be ~30 minutes minus 1 second. Accept a broad range because
    # crontab's precision is minute-level.
    assert delay_ms > 1_700_000 and delay_ms <= 1_800_000
  end

  # ---------------------------------------------------------------------------
  # S4 — timer fire triggers dispatch_fun + re-arms
  # ---------------------------------------------------------------------------

  test "S4: heartbeat fire dispatches + recomputes wall-clock next-run" do
    test_pid = self()

    dispatch_fun = fn trigger -> send(test_pid, {:dispatched, trigger}) end

    # Clock fun — return two different times to prove recompute happens from
    # wall-clock at firing time (Pitfall 3).
    clock_ref = :counters.new(1, [])
    :counters.add(clock_ref, 1, 1)

    clock_fun = fn ->
      case :counters.get(clock_ref, 1) do
        1 -> ~U[2026-04-16 12:00:00Z]
        _ -> ~U[2026-04-16 12:30:00Z]
      end
    end

    # GEP-14: stub HEARTBEAT.md lookup — present for this test so the
    # heartbeat dispatches instead of being skipped.
    heartbeat_file_fun = fn _base, _co, _slug -> {:ok, "Check inbox\n"} end

    {name, pid} =
      start_sched!(
        clock_fun: clock_fun,
        send_after_fun: capturing_send_after_fun(test_pid),
        heartbeat_file_fun: heartbeat_file_fun
      )

    :ok =
      Scheduler.register(name, "engineer", %{
        cron: "*/30 * * * *",
        dispatch_fun: dispatch_fun
      })

    # Drain first send_after
    assert_receive {:send_after, _, {:heartbeat, "engineer"}, _}, 500

    # Advance clock and fire the heartbeat manually
    :counters.add(clock_ref, 1, 1)
    send(pid, {:heartbeat, "engineer"})

    assert_receive {:dispatched, :heartbeat}, 500
    assert_receive {:audit, %{action: "agent.wake"} = entry}, 500
    trigger = entry[:trigger] || entry["trigger"]
    assert trigger == "heartbeat"

    # Should re-arm via send_after with a new delay derived from the
    # advanced clock (wall-clock recompute).
    assert_receive {:send_after, _, {:heartbeat, "engineer"}, _}, 500
  end

  # ---------------------------------------------------------------------------
  # S5 — unregister cancels timer
  # ---------------------------------------------------------------------------

  test "S5: unregister removes agent; subsequent timer fires are no-ops" do
    test_pid = self()
    dispatch_fun = fn _ -> send(test_pid, :should_not_fire) end

    {name, pid} =
      start_sched!(
        clock_fun: fn -> ~U[2026-04-16 12:00:00Z] end,
        send_after_fun: capturing_send_after_fun(test_pid)
      )

    :ok =
      Scheduler.register(name, "engineer", %{
        cron: "*/30 * * * *",
        dispatch_fun: dispatch_fun
      })

    assert_receive {:send_after, _, _, _}, 500

    assert :ok = Scheduler.unregister(name, "engineer")

    # Fire heartbeat — should be ignored because agent was unregistered
    send(pid, {:heartbeat, "engineer"})
    refute_receive :should_not_fire, 200
  end

  # ---------------------------------------------------------------------------
  # S6 — re-register cancels prior timer
  # ---------------------------------------------------------------------------

  test "S6: double-register same agent cancels first timer and arms second" do
    test_pid = self()

    {name, _pid} =
      start_sched!(
        clock_fun: fn -> ~U[2026-04-16 12:00:00Z] end,
        send_after_fun: capturing_send_after_fun(test_pid)
      )

    :ok =
      Scheduler.register(name, "engineer", %{
        cron: "*/30 * * * *",
        dispatch_fun: fn _ -> :ok end
      })

    assert_receive {:send_after, _, _, _}, 500

    :ok =
      Scheduler.register(name, "engineer", %{
        cron: "0 * * * *",
        dispatch_fun: fn _ -> :ok end
      })

    # Second send_after fired (different delay — hourly instead of half-hourly)
    assert_receive {:send_after, _, {:heartbeat, "engineer"}, _}, 500
  end

  # ---------------------------------------------------------------------------
  # S7 — stateless-across-restarts
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # GEP-14 S8 — missing HEARTBEAT.md → skip (no wake, audit event emitted)
  # ---------------------------------------------------------------------------

  test "S8: missing HEARTBEAT.md emits agent.heartbeat_skipped; no dispatch" do
    test_pid = self()
    dispatch_fun = fn _ -> send(test_pid, :should_not_dispatch) end

    heartbeat_file_fun = fn _base, _co, _slug -> {:error, :no_heartbeat_file} end

    {name, pid} =
      start_sched!(
        clock_fun: fn -> ~U[2026-04-16 12:00:00Z] end,
        send_after_fun: capturing_send_after_fun(test_pid),
        heartbeat_file_fun: heartbeat_file_fun
      )

    :ok =
      Scheduler.register(name, "engineer", %{
        cron: "*/30 * * * *",
        dispatch_fun: dispatch_fun
      })

    assert_receive {:send_after, _, _, _}, 500

    send(pid, {:heartbeat, "engineer"})

    assert_receive {:audit, %{action: "agent.heartbeat_skipped"} = entry}, 500
    reason = entry[:reason] || entry["reason"]
    assert reason == "no_heartbeat_file"

    # Dispatch must NOT have run.
    refute_receive :should_not_dispatch, 200

    # Re-arm still fires — a skipped heartbeat should not stop the cron.
    assert_receive {:send_after, _, {:heartbeat, "engineer"}, _}, 500
  end

  # ---------------------------------------------------------------------------
  # GEP-14 S9 — whitespace-only HEARTBEAT.md → skip
  # ---------------------------------------------------------------------------

  test "S9: blank HEARTBEAT.md is treated as skip" do
    test_pid = self()
    dispatch_fun = fn _ -> send(test_pid, :should_not_dispatch) end

    heartbeat_file_fun = fn _base, _co, _slug -> {:ok, "   \n\n"} end

    {name, pid} =
      start_sched!(
        clock_fun: fn -> ~U[2026-04-16 12:00:00Z] end,
        send_after_fun: capturing_send_after_fun(test_pid),
        heartbeat_file_fun: heartbeat_file_fun
      )

    :ok =
      Scheduler.register(name, "engineer", %{
        cron: "*/30 * * * *",
        dispatch_fun: dispatch_fun
      })

    assert_receive {:send_after, _, _, _}, 500
    send(pid, {:heartbeat, "engineer"})

    assert_receive {:audit, %{action: "agent.heartbeat_skipped"}}, 500
    refute_receive :should_not_dispatch, 200
  end

  # ---------------------------------------------------------------------------
  # GEP-14 S10 — oversize HEARTBEAT.md → skip with reason
  # ---------------------------------------------------------------------------

  test "S10: oversize HEARTBEAT.md emits skip with file_too_large reason" do
    test_pid = self()
    heartbeat_file_fun = fn _base, _co, _slug -> {:error, :file_too_large} end

    {name, pid} =
      start_sched!(
        clock_fun: fn -> ~U[2026-04-16 12:00:00Z] end,
        send_after_fun: capturing_send_after_fun(test_pid),
        heartbeat_file_fun: heartbeat_file_fun
      )

    :ok =
      Scheduler.register(name, "engineer", %{
        cron: "*/30 * * * *",
        dispatch_fun: fn _ -> :ok end
      })

    assert_receive {:send_after, _, _, _}, 500
    send(pid, {:heartbeat, "engineer"})

    assert_receive {:audit, %{action: "agent.heartbeat_skipped"} = entry}, 500
    reason = entry[:reason] || entry["reason"]
    assert reason == "file_too_large"
  end

  # ---------------------------------------------------------------------------
  # GEP-14 S11 — default resolver reads the real file from disk
  # ---------------------------------------------------------------------------

  test "S11: default_heartbeat_lookup/3 reads HEARTBEAT.md off disk" do
    base = Path.join(System.tmp_dir!(), "glorbo_sched_#{System.unique_integer([:positive])}")
    agent_dir = Path.join([base, "companies", "acme", "agents", "engineer"])
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(agent_dir, "HEARTBEAT.md"), "Check inbox.\n")

    try do
      assert {:ok, "Check inbox.\n"} =
               Scheduler.default_heartbeat_lookup(base, "acme", "engineer")

      assert {:error, :no_heartbeat_file} =
               Scheduler.default_heartbeat_lookup(base, "acme", "ghost-agent")
    after
      File.rm_rf!(base)
    end
  end

  test "S7: state is empty after restart (D-45 stateless invariant)" do
    {name1, pid1} = start_sched!(clock_fun: fn -> ~U[2026-04-16 12:00:00Z] end)

    :ok =
      Scheduler.register(name1, "engineer", %{
        cron: "*/30 * * * *",
        dispatch_fun: fn _ -> :ok end
      })

    stop_supervised(Scheduler)
    ref = Process.monitor(pid1)
    # Wait for it to actually terminate
    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      500 -> :ok
    end

    # Start a fresh scheduler under new name
    {name2, pid2} = start_sched!(clock_fun: fn -> ~U[2026-04-16 12:00:00Z] end)
    assert pid2 != pid1

    # Unregister of an agent that was only registered on the previous instance
    # returns :ok and does not crash (new scheduler has empty state).
    assert :ok = Scheduler.unregister(name2, "engineer")
  end
end
