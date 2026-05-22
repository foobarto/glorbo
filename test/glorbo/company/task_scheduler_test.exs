defmodule Glorbo.Company.TaskSchedulerTest do
  @moduledoc """
  Unit tests for `Glorbo.Company.TaskScheduler` (#268).

  Uses dep-injected `clock_fun`, `send_after_fun`, `audit_fun`, and
  `write_inbox_fun` so the tests never arm a real BEAM timer or touch
  the PubSub tree.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Company.TaskScheduler

  setup do
    base = Path.join(System.tmp_dir!(), "glorbo-task-sched-#{System.unique_integer([:positive])}")
    company = "acme"
    tasks_dir = Path.join([base, "companies", company, "projects/foo/tasks"])
    File.mkdir_p!(tasks_dir)
    agents_dir = Path.join([base, "companies", company, "agents/ceo/inbox"])
    File.mkdir_p!(agents_dir)

    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, company: company, tasks_dir: tasks_dir, agents_dir: agents_dir}
  end

  defp write_task(tasks_dir, id, opts) do
    schedule = Keyword.get(opts, :schedule, "")
    assigned = Keyword.get(opts, :assigned_to, "ceo")
    body = Keyword.get(opts, :body, "go do the thing")

    front =
      if schedule == "" do
        "kind: task/v1\ntitle: #{id}\nassigned_to: #{assigned}\nstatus: todo\n"
      else
        "kind: task/v1\ntitle: #{id}\nassigned_to: #{assigned}\nstatus: todo\nschedule: #{inspect(schedule)}\n"
      end

    File.write!(Path.join(tasks_dir, "#{id}.md"), """
    ---
    #{front}---

    #{body}
    """)
  end

  defp start_sched(base, company, opts \\ []) do
    test_pid = self()

    audit_fun = fn ^company, entry ->
      send(test_pid, {:audit, entry})
      :ok
    end

    send_after_fun = fn pid, msg, delay ->
      send(test_pid, {:armed, msg, delay})
      # Return a fake reference — Process.cancel_timer/1 accepts any
      # reference and returns false for unknown refs without crashing.
      ref = make_ref()
      send(pid, :noop)
      ref
    end

    write_inbox_fun = fn ^base, ^company, assignee, {filename, body} ->
      send(test_pid, {:inbox_write, assignee, filename, body})
      :ok
    end

    clock = Keyword.get(opts, :clock, ~U[2026-04-21 10:00:00Z])

    name = Glorbo.Test.UniqueName.gen("test_sched")

    start_supervised!(
      {TaskScheduler,
       name: name,
       company: company,
       base: base,
       subscribe?: false,
       auto_rescan?: false,
       clock_fun: fn -> clock end,
       send_after_fun: send_after_fun,
       audit_fun: audit_fun,
       write_inbox_fun: write_inbox_fun}
    )
  end

  test "arms a timer for a task with a valid schedule",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-1", schedule: "0 * * * *")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)

    assert_receive {:armed, {:fire, "foo-1"}, delay} when delay > 0
  end

  test "ignores tasks without a schedule",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-2", schedule: "")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)

    refute_receive {:armed, {:fire, "foo-2"}, _}, 50
  end

  test "emits scheduler.invalid_task_cron for unparseable schedules",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-3", schedule: "not-a-cron")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)

    assert_receive {:audit, %{action: "scheduler.invalid_task_cron", cron: "not-a-cron"}}
    refute_receive {:armed, {:fire, "foo-3"}, _}, 50
  end

  # UAT round 9 — repeated rescans of a task with an unchanged
  # malformed schedule must NOT flood the audit log. Only emit on
  # schedule change (or first sight).
  test "scheduler.invalid_task_cron dedups across repeated scans",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-3b", schedule: "wutang-clan")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:audit, %{action: "scheduler.invalid_task_cron"}}

    # Three more scans with the same invalid schedule — no further
    # audit events should fire.
    :ok = TaskScheduler.scan(sched)
    :ok = TaskScheduler.scan(sched)
    :ok = TaskScheduler.scan(sched)
    refute_receive {:audit, %{action: "scheduler.invalid_task_cron"}}, 50
  end

  test "scheduler.invalid_task_cron re-emits when schedule changes",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-3c", schedule: "wutang-clan")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:audit, %{action: "scheduler.invalid_task_cron", cron: "wutang-clan"}}

    # Rewrite with a different (still-invalid) schedule — fresh audit.
    write_task(tasks_dir, "foo-3c", schedule: "flip-diesel")
    :ok = TaskScheduler.scan(sched)
    assert_receive {:audit, %{action: "scheduler.invalid_task_cron", cron: "flip-diesel"}}
  end

  test "honours keyword aliases (daily / @hourly / weekly)",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-4", schedule: "daily")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)

    assert_receive {:armed, {:fire, "foo-4"}, _}
  end

  # R16 / #280 — NL phrases fire too. The display layer (#237) had
  # accepted these since v0.0.3 but they fell through the scheduler
  # parser. Closes the gap.
  test "honours English NL schedule phrases",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-4a", schedule: "every morning at 9am")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)

    assert_receive {:armed, {:fire, "foo-4a"}, _}
  end

  test "NL phrase 'every weekday' arms like the cron it resolves to",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-4b", schedule: "every weekday")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)

    assert_receive {:armed, {:fire, "foo-4b"}, _}
  end

  test "fire writes to the assignee's inbox + emits task.scheduled_dispatch audit",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-5", schedule: "0 * * * *", body: "write the quarterly report")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-5"}, _}

    # Fire the timer by hand.
    send(sched, {:fire, "foo-5"})

    assert_receive {:inbox_write, "ceo", filename, body}
    assert String.starts_with?(filename, "sched-")
    assert String.ends_with?(filename, "-foo-5.md")
    assert body =~ "from: scheduler"
    assert body =~ "task_path: projects/foo/tasks/foo-5.md"
    assert body =~ "write the quarterly report"

    assert_receive {:audit,
                    %{action: "task.scheduled_dispatch", target: "projects/foo/tasks/foo-5.md"}}
  end

  # GEP-47: depends_on gating.
  defp write_task_with_deps(tasks_dir, id, schedule, deps, opts \\ []) do
    assigned = Keyword.get(opts, :assigned_to, "ceo")
    body = Keyword.get(opts, :body, "do thing")

    deps_yaml =
      "depends_on:\n" <>
        Enum.map_join(deps, "\n", &"  - #{&1}")

    File.write!(Path.join(tasks_dir, "#{id}.md"), """
    ---
    kind: task/v1
    title: #{id}
    assigned_to: #{assigned}
    status: todo
    schedule: #{inspect(schedule)}
    #{deps_yaml}
    ---

    #{body}
    """)
  end

  defp write_dep_task(tasks_dir, id, status) do
    File.write!(Path.join(tasks_dir, "#{id}.md"), """
    ---
    kind: task/v1
    title: #{id}
    status: #{status}
    ---

    body
    """)
  end

  test "GEP-47: depends_on with all deps done → fires normally",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_dep_task(tasks_dir, "foo-prereq", "done")
    write_task_with_deps(tasks_dir, "foo-7", "0 * * * *", ["foo-prereq"])
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-7"}, _}, 1_000

    send(sched, {:fire, "foo-7"})

    # Bumped from default 100ms — these tests do an extra full-tree
    # snapshot scan per fire, which can run slow under heavy parallel-
    # test load (the precommit run on CI hits this).
    assert_receive {:inbox_write, "ceo", _filename, _body}, 1_000
    assert_receive {:audit, %{action: "task.scheduled_dispatch", target: target}}, 1_000
    assert target =~ "foo-7"
  end

  test "GEP-47: depends_on with non-terminal dep → emits blocked_on_deps + skips inbox",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_dep_task(tasks_dir, "foo-prereq", "in-progress")
    write_task_with_deps(tasks_dir, "foo-8", "0 * * * *", ["foo-prereq"])
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-8"}, _}, 1_000

    send(sched, {:fire, "foo-8"})

    assert_receive {:audit, %{action: "task.blocked_on_deps", detail: %{unmet: ["foo-prereq"]}}},
                   1_000

    refute_receive {:inbox_write, _, _, _}, 100
  end

  test "GEP-47: depends_on with denied dep → emits blocked_on_failed_dep",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_dep_task(tasks_dir, "foo-prereq", "denied")
    write_task_with_deps(tasks_dir, "foo-9", "0 * * * *", ["foo-prereq"])
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-9"}, _}, 1_000

    send(sched, {:fire, "foo-9"})

    assert_receive {:audit, %{action: "task.blocked_on_failed_dep", detail: detail}}, 1_000

    assert detail.failed_dep == "foo-prereq"
    refute_receive {:inbox_write, _, _, _}, 100
  end

  # C-130: depends_on lives in an agent-RW task file. An agent with
  # tasks:update could blank/remove depends_on before the scheduled fire
  # to make the dependency gate fail open. The scheduler must NOT trust a
  # shrink of the dependency set below what was registered at arm time.
  test "C-130: removing depends_on before fire does not fail open",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_dep_task(tasks_dir, "foo-prereq", "in-progress")
    write_task_with_deps(tasks_dir, "foo-tamper", "0 * * * *", ["foo-prereq"])
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-tamper"}, _}, 1_000

    # Agent tampers: rewrite the task file dropping depends_on entirely.
    File.write!(Path.join(tasks_dir, "foo-tamper.md"), """
    ---
    kind: task/v1
    title: foo-tamper
    assigned_to: ceo
    status: todo
    schedule: "0 * * * *"
    ---

    do thing
    """)

    send(sched, {:fire, "foo-tamper"})

    # The tamper is detected and audited, AND the gate still blocks
    # (registered dep foo-prereq is in-progress) — no dispatch.
    assert_receive {:audit, %{action: "scheduler.depends_on_tampered", detail: detail}}, 1_000
    assert detail.dropped == ["foo-prereq"]

    assert_receive {:audit, %{action: "task.blocked_on_deps", target: target}}, 1_000
    assert target =~ "foo-tamper"
    refute_receive {:inbox_write, _, _, _}, 100
  end

  test "C-130: blanking depends_on to empty list does not fail open",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_dep_task(tasks_dir, "foo-prereq", "in-progress")
    write_task_with_deps(tasks_dir, "foo-blank", "0 * * * *", ["foo-prereq"])
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-blank"}, _}, 1_000

    # Coerce depends_on to a list of empties (coerce_depends_on → []).
    File.write!(Path.join(tasks_dir, "foo-blank.md"), """
    ---
    kind: task/v1
    title: foo-blank
    assigned_to: ceo
    status: todo
    schedule: "0 * * * *"
    depends_on:
      - ""
    ---

    do thing
    """)

    send(sched, {:fire, "foo-blank"})

    refute_receive {:inbox_write, _, _, _}, 200
  end

  # Legitimate case: a task that never had deps still fires (no false block).
  test "C-130: a task registered with no deps still fires normally",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-nodeps", schedule: "0 * * * *")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-nodeps"}, _}, 1_000

    send(sched, {:fire, "foo-nodeps"})
    assert_receive {:inbox_write, "ceo", _filename, _body}, 1_000
  end

  test "fire without assignee emits scheduler.missing_assignee",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-6", schedule: "0 * * * *", assigned_to: "")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    # With an empty assignee the arm still happens (cron is valid).
    assert_receive {:armed, {:fire, "foo-6"}, _}

    send(sched, {:fire, "foo-6"})
    assert_receive {:audit, %{action: "scheduler.missing_assignee"}}
    refute_receive {:inbox_write, _, _, _}, 50
  end

  test "fire re-reads the task — schedule removed between arm and fire drops it",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-7", schedule: "0 * * * *")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-7"}, _}

    # Rewrite the task without a schedule.
    write_task(tasks_dir, "foo-7", schedule: "")
    send(sched, {:fire, "foo-7"})
    refute_receive {:inbox_write, _, _, _}, 50
    refute_receive {:audit, %{action: "task.scheduled_dispatch"}}, 50
  end

  # Performance: on rescan, files whose mtime hasn't changed AND whose
  # armed timer is still live MUST NOT be re-parsed or re-armed. This
  # is the O(projects × tasks) → O(changed-tasks) optimisation. Without
  # it, 1000 tasks → 1000 reads + 1000 YAML parses every 60 seconds.

  defp start_sched_with_live_timer(base, company, opts \\ []) do
    test_pid = self()
    company_str = company

    audit_fun = fn ^company_str, entry ->
      send(test_pid, {:audit, entry})
      :ok
    end

    send_after_fun = fn pid, msg, delay ->
      send(test_pid, {:armed, msg, delay})
      ref = make_ref()
      send(pid, :noop)
      ref
    end

    write_inbox_fun = fn ^base, ^company_str, assignee, {filename, body} ->
      send(test_pid, {:inbox_write, assignee, filename, body})
      :ok
    end

    # `read_timer_fun: fn _ -> 60_000 end` simulates "the BEAM timer is
    # still armed, expires in 60s" so the mtime-cache path triggers
    # for every entry whose mtime matches.
    clock = Keyword.get(opts, :clock, ~U[2026-04-21 10:00:00Z])
    name = Glorbo.Test.UniqueName.gen("test_sched")

    start_supervised!(
      {TaskScheduler,
       name: name,
       company: company,
       base: base,
       subscribe?: false,
       auto_rescan?: false,
       clock_fun: fn -> clock end,
       send_after_fun: send_after_fun,
       read_timer_fun: fn _ref -> 60_000 end,
       audit_fun: audit_fun,
       write_inbox_fun: write_inbox_fun}
    )
  end

  test "rescan with unchanged mtime + live timer skips re-arm (mtime cache)",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "perf-1", schedule: "0 * * * *")
    sched = start_sched_with_live_timer(base, company)

    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "perf-1"}, _}

    # Second scan with no file changes — the entry is fresh in the
    # cache, so no second {:armed, ...} message should land.
    :ok = TaskScheduler.scan(sched)
    refute_receive {:armed, {:fire, "perf-1"}, _}, 50
  end

  test "rescan re-parses + re-arms when mtime advances",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    path = Path.join(tasks_dir, "perf-2.md")
    write_task(tasks_dir, "perf-2", schedule: "0 * * * *")
    sched = start_sched_with_live_timer(base, company)

    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "perf-2"}, _}

    # Bump the file's mtime forward by 5s so the cache miss triggers.
    # Use gregorian-second arithmetic so a `seconds + 5` past 59
    # rolls cleanly into the next minute / hour / day instead of
    # producing an invalid {{y,mo,d},{h,mi,60+}} tuple File.touch!
    # rejects with `:einval`. (Surfaced as a CI flake on a run that
    # happened to start the test in the last 5 seconds of a minute.)
    next =
      :calendar.universal_time()
      |> :calendar.datetime_to_gregorian_seconds()
      |> Kernel.+(5)
      |> :calendar.gregorian_seconds_to_datetime()

    :ok = File.touch!(path, next)

    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "perf-2"}, _}, 200
  end

  test "rescan re-parses when armed timer has expired (defensive miss)",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "perf-3", schedule: "0 * * * *")

    # `read_timer_fun: fn _ -> false end` simulates "the timer fired
    # but the {:fire, _} message hasn't been handled yet" — the cache
    # check must reject the entry as stale and re-parse.
    test_pid = self()

    send_after_fun = fn pid, msg, delay ->
      send(test_pid, {:armed, msg, delay})
      send(pid, :noop)
      make_ref()
    end

    name = Glorbo.Test.UniqueName.gen("test_sched")

    sched =
      start_supervised!(
        {TaskScheduler,
         name: name,
         company: company,
         base: base,
         subscribe?: false,
         auto_rescan?: false,
         clock_fun: fn -> ~U[2026-04-21 10:00:00Z] end,
         send_after_fun: send_after_fun,
         read_timer_fun: fn _ref -> false end,
         audit_fun: fn ^company, _entry -> :ok end,
         write_inbox_fun: fn _, _, _, _ -> :ok end}
      )

    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "perf-3"}, _}

    # Same file, no mtime change — but read_timer_fun says the timer
    # is dead. The scheduler MUST re-arm rather than trust the cache.
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "perf-3"}, _}, 200
  end

  test "stale entries removed on rescan when file deleted",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-8", schedule: "0 * * * *")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-8"}, _}

    File.rm!(Path.join(tasks_dir, "foo-8.md"))
    :ok = TaskScheduler.scan(sched)
    send(sched, {:fire, "foo-8"})
    refute_receive {:inbox_write, _, _, _}, 50
  end

  # GEP-24 — TaskLive reads the armed fire time for its
  # "next fire at ___" hint via this API. Must return a DateTime
  # for armed tasks and nil otherwise.
  test "next_fire_at/2 returns a DateTime for armed tasks",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-9", schedule: "0 * * * *")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-9"}, _}

    assert %DateTime{} = TaskScheduler.next_fire_at(sched, "foo-9")
  end

  test "next_fire_at/2 returns nil for unknown tasks",
       %{base: base, company: company} do
    sched = start_sched(base, company)
    assert nil == TaskScheduler.next_fire_at(sched, "never-heard-of-it")
  end

  # C-078: a `*.comments.md` task-comment file carrying a non-empty
  # `schedule:` must NOT be armed as a scheduled task.
  test "C-078: a .comments.md file with a schedule is not armed",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    File.write!(Path.join(tasks_dir, "foo-1.comments.md"), """
    ---
    kind: task-comments/v1
    task_id: foo-1
    schedule: "0 * * * *"
    assigned_to: ceo
    ---

    sneaky comment posing as a scheduled task
    """)

    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)

    refute_receive {:armed, {:fire, _}, _}, 50
    refute_receive {:inbox_write, _, _, _}, 50
  end

  # C-078: any task `*.md` whose `kind` is not `task/v1` must be skipped
  # even with a non-empty schedule (a comments file not named .comments.md).
  test "C-078: a non-task/v1 kind with a schedule is not armed",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    File.write!(Path.join(tasks_dir, "foo-disguised.md"), """
    ---
    kind: task-comments/v1
    task_id: foo-1
    schedule: "0 * * * *"
    assigned_to: ceo
    ---

    body
    """)

    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)

    refute_receive {:armed, {:fire, "foo-disguised"}, _}, 50
    refute_receive {:inbox_write, _, _, _}, 50
  end

  # C-046 / C-047: the mtime cache can preserve a stale parsed cron. When
  # the (stale) timer fires, the fire path must re-parse the CURRENT
  # schedule and re-arm from it — never re-use the cron parsed at arm time.
  test "C-046/C-047: fire re-parses the current schedule, not the armed expr",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-stale", schedule: "* * * * *")
    sched = start_sched(base, company, clock: ~U[2026-04-21 10:00:30Z])
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, {:fire, "foo-stale"}, delay_armed}
    assert delay_armed <= 31_000

    # Drain any further every-minute arms from boot/explicit scans so the
    # only {:armed} left after the fire is the re-arm under test.
    flush_armed = fn flush ->
      receive do
        {:armed, {:fire, "foo-stale"}, _} -> flush.(flush)
      after
        50 -> :ok
      end
    end

    flush_armed.(flush_armed)

    # Agent edits the schedule to once-a-year while the stale timer is
    # still armed. A correct re-parse re-arms from the NEW far-future cron.
    write_task(tasks_dir, "foo-stale", schedule: "0 0 1 1 *")

    send(sched, {:fire, "foo-stale"})

    assert_receive {:inbox_write, "ceo", _filename, _body}
    assert_receive {:armed, {:fire, "foo-stale"}, delay_rearm}

    # New "0 0 1 1 *" from 2026-04-21 → next Jan 1 is far out. A stale
    # every-minute re-arm would be <= 61s.
    assert delay_rearm > 61_000
  end

  test "next_fire_at/2 tolerates a stopped server",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-10", schedule: "0 * * * *")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert %DateTime{} = TaskScheduler.next_fire_at(sched, "foo-10")

    # Kill the scheduler to simulate a crash / not-running case —
    # TaskLive should get nil, not an exception.
    ref = Process.monitor(sched)
    GenServer.stop(sched, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^sched, _}

    assert nil == TaskScheduler.next_fire_at(sched, "foo-10")
  end
end
