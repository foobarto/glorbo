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
        "title: #{id}\nassigned_to: #{assigned}\nstatus: todo\n"
      else
        "title: #{id}\nassigned_to: #{assigned}\nstatus: todo\nschedule: #{inspect(schedule)}\n"
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

  test "honours keyword aliases (daily / @hourly / weekly)",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    write_task(tasks_dir, "foo-4", schedule: "daily")
    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)

    assert_receive {:armed, {:fire, "foo-4"}, _}
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
