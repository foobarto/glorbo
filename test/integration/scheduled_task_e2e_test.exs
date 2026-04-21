defmodule Glorbo.Integration.ScheduledTaskE2ETest do
  @moduledoc """
  Integration test for #268 / GEP-24 — end-to-end scheduled-task
  dispatch.

  Verifies the chain TaskScheduler → inbox file write → audit
  event against the real `default_write_inbox` path (no
  dep-injected stub for the write), using a dep-injected clock
  + send_after_fun to make the fire deterministic.

  This is deliberately narrow: we drive `:fire` directly via
  `send/2` rather than waiting for a real timer, so the test
  doesn't actually sleep for the next cron tick. The code path
  under test is everything the scheduler does **after** the
  timer fires:

    1. re-read task frontmatter
    2. resolve assignee
    3. build sched-<uniq>-<task_id>.md message
    4. write to agents/<assignee>/inbox/
    5. emit task.scheduled_dispatch audit

  Agent.Server is **not** exercised here — inotify-to-wake is
  covered by `AgentWakeInboxTest`. Gluing the two is implicit:
  if both pass, the full chain works.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Glorbo.Company.TaskScheduler

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-sched-e2e-#{System.unique_integer([:positive])}")

    company = "acme"
    tasks_dir = Path.join([base, "companies", company, "projects/foo/tasks"])
    File.mkdir_p!(tasks_dir)
    File.mkdir_p!(Path.join([base, "companies", company, "agents/ceo/inbox"]))

    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, company: company, tasks_dir: tasks_dir}
  end

  defp seed_scheduled_task(tasks_dir, task_id, opts) do
    schedule = Keyword.fetch!(opts, :schedule)
    assignee = Keyword.get(opts, :assigned_to, "ceo")
    body = Keyword.get(opts, :body, "do the scheduled work")

    File.write!(Path.join(tasks_dir, "#{task_id}.md"), """
    ---
    title: #{task_id}
    assigned_to: #{assignee}
    status: todo
    schedule: #{inspect(schedule)}
    ---

    #{body}
    """)
  end

  defp start_sched(base, company, opts \\ []) do
    test_pid = self()

    # Capture audits but use the REAL default_write_inbox so the
    # filesystem side-effect is exercised end-to-end.
    audit_fun = fn ^company, entry ->
      send(test_pid, {:audit, entry})
      :ok
    end

    # Intercept send_after so we don't actually arm a real timer.
    # We still want arm() to return something to store; tests fire
    # `:fire` directly via send/2.
    send_after_fun = fn pid, msg, _delay ->
      send(test_pid, {:armed, pid, msg})
      make_ref()
    end

    clock = Keyword.get(opts, :clock, ~U[2026-04-21 10:00:00Z])

    start_supervised!(
      {TaskScheduler,
       name: Glorbo.Test.UniqueName.gen("sched_e2e"),
       company: company,
       base: base,
       subscribe?: false,
       auto_rescan?: false,
       clock_fun: fn -> clock end,
       send_after_fun: send_after_fun,
       audit_fun: audit_fun}
    )
  end

  test "scheduled task fires: inbox file written + audit emitted",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    seed_scheduled_task(tasks_dir, "foo-e2e-1",
      schedule: "0 * * * *",
      body: "write the quarterly report"
    )

    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)

    assert_receive {:armed, ^sched, {:fire, "foo-e2e-1"}}, 200

    # Drive the fire directly (skipping timer).
    send(sched, {:fire, "foo-e2e-1"})

    # Audit hits the test pid.
    assert_receive {:audit,
                    %{
                      action: "task.scheduled_dispatch",
                      target: "projects/foo/tasks/foo-e2e-1.md",
                      detail: %{
                        task_path: "projects/foo/tasks/foo-e2e-1.md",
                        assigned_to: "ceo",
                        cron: "0 * * * *"
                      }
                    }},
                   500

    # Inbox file now exists on disk — verify via a live read
    # rather than a capture shim. Wait briefly for the message
    # pipeline (GenServer call → file write).
    inbox_dir = Path.join([base, "companies", company, "agents/ceo/inbox"])

    files =
      Enum.find_value(1..50, fn _ ->
        case File.ls(inbox_dir) do
          {:ok, fs} when fs != [] -> fs
          _ -> Process.sleep(10) && nil
        end
      end)

    assert is_list(files)
    assert [inbox_file | _] = Enum.filter(files, &String.starts_with?(&1, "sched-"))
    assert String.ends_with?(inbox_file, "-foo-e2e-1.md")

    inbox_body = File.read!(Path.join(inbox_dir, inbox_file))
    assert inbox_body =~ "from: scheduler"
    assert inbox_body =~ "task_path: projects/foo/tasks/foo-e2e-1.md"
    assert inbox_body =~ "write the quarterly report"
  end

  test "scheduled dispatch uses the current task body (not the armed-time cached copy)",
       %{base: base, company: company, tasks_dir: tasks_dir} do
    # Arm with body A, then rewrite the body to B before firing.
    # The fire must pick up B — GEP-24 D-fire-reread.
    seed_scheduled_task(tasks_dir, "foo-e2e-2",
      schedule: "0 * * * *",
      body: "original prompt (stale)"
    )

    sched = start_sched(base, company)
    :ok = TaskScheduler.scan(sched)
    assert_receive {:armed, ^sched, {:fire, "foo-e2e-2"}}, 200

    # Rewrite before firing.
    seed_scheduled_task(tasks_dir, "foo-e2e-2",
      schedule: "0 * * * *",
      body: "UPDATED PROMPT — fresh fire"
    )

    send(sched, {:fire, "foo-e2e-2"})
    assert_receive {:audit, %{action: "task.scheduled_dispatch"}}, 500

    inbox_dir = Path.join([base, "companies", company, "agents/ceo/inbox"])

    files =
      Enum.find_value(1..50, fn _ ->
        case File.ls(inbox_dir) do
          {:ok, fs} when fs != [] -> fs
          _ -> Process.sleep(10) && nil
        end
      end)

    [file | _] = Enum.filter(files, &String.starts_with?(&1, "sched-"))
    body = File.read!(Path.join(inbox_dir, file))

    assert body =~ "UPDATED PROMPT — fresh fire"
    refute body =~ "original prompt (stale)"
  end
end
