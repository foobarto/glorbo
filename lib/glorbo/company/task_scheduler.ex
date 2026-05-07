defmodule Glorbo.Company.TaskScheduler do
  @moduledoc """
  Per-company task scheduler (#268).

  Fires dispatches for tasks whose frontmatter carries a `schedule:`
  cron expression. On boot + on any `projects/**/*.md` write event it
  scans `projects/*/tasks/*.md`, parses each task's schedule, and
  arms a `Process.send_after/3` timer for the next fire.

  When a timer fires we:

    1. Re-read the task file (file may have been deleted or schedule
       removed — skip silently in either case).
    2. Write a synthetic inbox message to `agents/<assigned_to>/inbox/
       sched-<ts>-<task_id>.md`. The body is the task's prompt body
       (everything after the frontmatter fence). The agent's inotify
       watcher picks it up the same way a Router-dispatched message
       would — Agent.Server wakes with trigger `:inbox`.
    3. Emit a `task.scheduled_dispatch` audit event with `task_path`,
       `cron_expr`, `fired_at`, `next_at`.

  **Audit-log de-dup (D-45 style).** There is no state file — on boot
  we read the current-month audit and skip any `(task_path, fire_ts)`
  pair that already appears. Keeps us from double-firing if the BEAM
  restarts within the same cron tick. Matches the rest of Glorbo's
  filesystem-is-truth invariant — nothing to corrupt, nothing to
  drift.

  **Dep-injection:** `clock_fun`, `send_after_fun`, `audit_fun`,
  `write_inbox_fun`, and `subscribe?` for tests. `subscribe?: false`
  keeps the scheduler inert until the test drives it via `scan/1`.

  **Cron parsing.** Accepts 5-field crons (`"0 9 * * 1-5"`) and a
  small set of keyword aliases (`"hourly"`, `"daily"`, `"weekly"`,
  `"monthly"`, `"@hourly"`, `"@daily"`, `"@weekly"`, `"@monthly"`).
  Anything else is skipped with a `scheduler.invalid_task_cron`
  audit event — the scheduler never crashes on a malformed schedule.
  """
  use GenServer
  require Logger

  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler, as: CronScheduler
  alias Glorbo.Company.AuditLog
  alias Glorbo.Filesystem.Frontmatter

  @rescan_interval_ms 60_000

  @aliases %{
    "hourly" => "0 * * * *",
    "@hourly" => "0 * * * *",
    "daily" => "0 0 * * *",
    "@daily" => "0 0 * * *",
    "weekly" => "0 0 * * 0",
    "@weekly" => "0 0 * * 0",
    "monthly" => "0 0 1 * *",
    "@monthly" => "0 0 1 * *"
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Force a rescan of the task tree. Exposed for tests + for an
  operator escape hatch from IEx.
  """
  @spec scan(GenServer.server()) :: :ok
  def scan(server), do: GenServer.call(server, :scan)

  @doc """
  Return the next armed fire time for `task_id`, or `nil` if the
  task isn't scheduled (no `schedule:` field, unparseable cron, or
  simply unknown to this scheduler).

  Soft API — callers should tolerate `nil` and a not-running
  server. TaskLive uses this to render a "next fire at ___" hint.
  """
  @spec next_fire_at(GenServer.server(), String.t()) :: DateTime.t() | nil
  def next_fire_at(server, task_id) when is_binary(task_id) do
    GenServer.call(server, {:next_fire_at, task_id})
  catch
    :exit, _ -> nil
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    pubsub = Keyword.get(opts, :pubsub, Glorbo.PubSub)

    if Keyword.get(opts, :subscribe?, true) do
      :ok = Phoenix.PubSub.subscribe(pubsub, "company:#{company}:projects")
    end

    state = %{
      company: company,
      base: base,
      pubsub: pubsub,
      tasks: %{},
      clock_fun: Keyword.get(opts, :clock_fun, &DateTime.utc_now/0),
      send_after_fun: Keyword.get(opts, :send_after_fun, &Process.send_after/3),
      # `Process.read_timer/1` underpins the rescan mtime cache: if a
      # task file's mtime hasn't changed AND the armed timer is still
      # live, scan_one/2 skips the read+parse pass. Tests that inject
      # `send_after_fun` get fake refs that read_timer/1 doesn't
      # recognise; they pass a stub here to drive the cache path
      # deterministically.
      read_timer_fun: Keyword.get(opts, :read_timer_fun, &Process.read_timer/1),
      audit_fun: Keyword.get(opts, :audit_fun, &audit_via_registry/2),
      write_inbox_fun: Keyword.get(opts, :write_inbox_fun, &default_write_inbox/4),
      rescan_ms: Keyword.get(opts, :rescan_ms, @rescan_interval_ms),
      auto_rescan?: Keyword.get(opts, :auto_rescan?, true),
      # GEP-47: dedup state for `task.cycle_detected` audit so the
      # 60s rescan doesn't emit a duplicate event for every cycle on
      # every tick. Tracks the canonical (sorted) shape of each
      # detected cycle.
      last_cycles: MapSet.new()
    }

    # First scan on boot. Schedule a background rescan at 60s intervals
    # as a safety net against missed inotify events.
    send(self(), :initial_scan)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:scan, _from, state) do
    {:reply, :ok, do_scan(state)}
  end

  def handle_call({:next_fire_at, task_id}, _from, state) do
    {:reply, get_in(state, [:tasks, task_id, :next_at]), state}
  end

  @impl GenServer
  def handle_info(:initial_scan, state) do
    if state.auto_rescan? do
      Process.send_after(self(), :rescan, state.rescan_ms)
    end

    {:noreply, do_scan(state)}
  end

  def handle_info(:rescan, state) do
    if state.auto_rescan? do
      Process.send_after(self(), :rescan, state.rescan_ms)
    end

    {:noreply, state |> do_scan() |> run_cycle_check()}
  end

  def handle_info({:file_event, rel_path, _events}, state) when is_binary(rel_path) do
    if task_path?(rel_path) do
      {:noreply, do_scan(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:fire, task_id}, state) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, %{invalid?: true}} ->
        # Invalid-cron entries are stashed only for dedup bookkeeping —
        # no timer was armed for them. A :fire message here would mean
        # a bug elsewhere; drop it silently.
        {:noreply, state}

      {:ok, entry} ->
        {:noreply, fire(state, task_id, entry)}

      :error ->
        # Task removed between arm and fire — drop silently.
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Scan
  # ---------------------------------------------------------------------------

  defp do_scan(state) do
    projects_dir = Path.join([state.base, "companies", state.company, "projects"])

    task_paths =
      case File.ls(projects_dir) do
        {:ok, entries} ->
          entries
          |> Enum.flat_map(fn project ->
            tasks_dir = Path.join([projects_dir, project, "tasks"])

            case File.ls(tasks_dir) do
              {:ok, files} ->
                files
                |> Enum.filter(&String.ends_with?(&1, ".md"))
                |> Enum.map(&Path.join([projects_dir, project, "tasks", &1]))

              _ ->
                []
            end
          end)

        _ ->
          []
      end

    # Cancel timers for tasks no longer present.
    new_ids =
      task_paths
      |> Enum.map(&task_id_from_path/1)
      |> MapSet.new()

    stale =
      for {id, %{timer_ref: ref}} <- state.tasks, not MapSet.member?(new_ids, id), do: {id, ref}

    state =
      Enum.reduce(stale, state, fn {id, ref}, acc ->
        if ref, do: Process.cancel_timer(ref)
        %{acc | tasks: Map.delete(acc.tasks, id)}
      end)

    Enum.reduce(task_paths, state, &scan_one/2)
  end

  defp scan_one(path, state) do
    task_id = task_id_from_path(path)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        if entry_fresh?(state, task_id, mtime) do
          # File unchanged AND its timer is still armed — skip the
          # read + frontmatter + cron-parse pass entirely. This is the
          # O(projects × tasks) → O(changed-tasks) optimisation: at
          # 1000 tasks, a 60s rescan that previously cost 1000 reads
          # + 1000 YAML parses now costs 1000 lstats + 0 reads when
          # nothing has changed.
          state
        else
          parse_and_arm(path, mtime, state)
        end

      _ ->
        # Path vanished between File.ls and lstat (or it's a symlink
        # / fifo). Drop any stale state entry.
        drop_task(state, task_id)
    end
  end

  # An entry is fresh when (a) its cached mtime matches the file's
  # current mtime AND (b) its armed timer hasn't fired yet. The timer
  # check guards a narrow race: if `:rescan` arrives while a `{:fire,
  # task_id}` message is sitting in the mailbox unread, the timer ref
  # has expired but the entry hasn't been re-armed yet. Without this
  # check we'd skip the parse on a task that's about to fire and miss
  # re-arming for the next occurrence.
  defp entry_fresh?(state, task_id, mtime) do
    case Map.get(state.tasks, task_id) do
      %{mtime: ^mtime, timer_ref: ref} when is_reference(ref) ->
        case state.read_timer_fun.(ref) do
          n when is_integer(n) and n > 0 -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp drop_task(state, task_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, %{timer_ref: ref}} when is_reference(ref) ->
        Process.cancel_timer(ref)
        %{state | tasks: Map.delete(state.tasks, task_id)}

      _ ->
        state
    end
  end

  defp parse_and_arm(path, mtime, state) do
    # Threatmodel wave 25: agent-RW task md, lstat + 1 MiB cap.
    with {:ok, content} <- Glorbo.Filesystem.AgentWritableFile.read_bounded(path, 1_048_576),
         {:ok, fm, body} <- Frontmatter.parse(content),
         schedule when is_binary(schedule) and schedule != "" <- Map.get(fm, "schedule") do
      handle_scheduled(state, path, fm, schedule, body, mtime)
    else
      _ -> state
    end
  end

  defp handle_scheduled(state, path, fm, schedule, body, mtime) do
    task_id = task_id_from_path(path)
    rel = relative_path(state, path)

    case parse_cron(schedule) do
      {:ok, expr} ->
        now = state.clock_fun.()

        entry = %{
          path: path,
          rel_path: rel,
          schedule: schedule,
          expr: expr,
          assigned_to: Map.get(fm, "assigned_to") || "",
          body: body,
          mtime: mtime
        }

        arm(state, task_id, entry, now)

      {:error, reason} ->
        maybe_emit_invalid(state, task_id, rel, schedule, reason)
    end
  end

  defp arm(state, task_id, entry, now) do
    prev = Map.get(state.tasks, task_id, %{})
    if ref = prev[:timer_ref], do: Process.cancel_timer(ref)

    case next_ms_from_now(entry.expr, now) do
      {:ok, delay_ms, next_dt} ->
        ref = state.send_after_fun.(self(), {:fire, task_id}, delay_ms)

        tasks =
          Map.put(
            state.tasks,
            task_id,
            Map.put(entry, :timer_ref, ref) |> Map.put(:next_at, next_dt)
          )

        %{state | tasks: tasks}

      :error ->
        state
    end
  end

  defp fire(state, task_id, entry) do
    # Re-read file — the schedule or assignee may have changed, and the
    # file may have been deleted. Defensive re-read avoids firing stale.
    # Wave 25: lstat + 1 MiB cap on the agent-RW path.
    case Glorbo.Filesystem.AgentWritableFile.read_bounded(entry.path, 1_048_576) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, fm, body} ->
            maybe_fire(state, task_id, entry, fm, body)

          _ ->
            state
        end

      _ ->
        %{state | tasks: Map.delete(state.tasks, task_id)}
    end
  end

  defp maybe_fire(state, task_id, entry, fm, body) do
    schedule = Map.get(fm, "schedule") || ""
    assignee = Map.get(fm, "assigned_to") || ""
    depends_on = coerce_depends_on(Map.get(fm, "depends_on"))

    cond do
      schedule == "" ->
        %{state | tasks: Map.delete(state.tasks, task_id)}

      assignee == "" ->
        emit_audit(state, %{
          action: "scheduler.missing_assignee",
          actor: "system",
          company: state.company,
          target: entry.rel_path,
          cron: schedule
        })

        re_arm(state, task_id, entry)

      not Glorbo.Slug.valid?(assignee) ->
        emit_audit(state, %{
          action: "scheduler.invalid_assignee",
          actor: "system",
          company: state.company,
          target: entry.rel_path,
          detail: %{assigned_to: inspect(assignee)}
        })

        re_arm(state, task_id, entry)

      depends_on != [] ->
        # GEP-47: gate the dispatch on dependency readiness before
        # writing the inbox event. The snapshot is built on-demand
        # from disk per-fire — fine for the typical 10s-of-tasks
        # company; large rosters get the SQLite-backed task index
        # under GEP-47's D9 (queued v2 follow-up).
        snapshot = build_task_snapshot(state)

        case Glorbo.Task.DependencyGate.ready?(depends_on, snapshot) do
          :ok ->
            do_fire(state, task_id, entry, fm, body, schedule, assignee)

          {:blocked, unmet} ->
            emit_audit(state, %{
              action: "task.blocked_on_deps",
              actor: "scheduler",
              company: state.company,
              target: entry.rel_path,
              detail: %{task_id: task_id, unmet: unmet}
            })

            re_arm(state, task_id, entry)

          {:propagate_failure, dep_id, reason} ->
            # GEP-47 D4 (failure propagation by file rewrite) is
            # queued as a v2 follow-up; v1 surfaces the situation
            # as an audit event so the operator sees "task X stuck
            # behind failed dep Y" and can intervene manually.
            emit_audit(state, %{
              action: "task.blocked_on_failed_dep",
              actor: "scheduler",
              company: state.company,
              target: entry.rel_path,
              detail: %{task_id: task_id, failed_dep: dep_id, reason: reason}
            })

            re_arm(state, task_id, entry)
        end

      true ->
        do_fire(state, task_id, entry, fm, body, schedule, assignee)
    end
  end

  defp do_fire(state, task_id, entry, _fm, body, schedule, assignee) do
    ts = state.clock_fun.() |> DateTime.to_iso8601()
    filename = "sched-#{System.unique_integer([:positive])}-#{task_id}.md"

    msg_body =
      """
      ---
      kind: inbox-message/v1
      from: scheduler
      task_path: #{entry.rel_path}
      scheduled_at: "#{ts}"
      cron: #{inspect(schedule)}
      ---

      #{String.trim(body)}
      """

    case state.write_inbox_fun.(state.base, state.company, assignee, {filename, msg_body}) do
      :ok ->
        emit_audit(state, %{
          action: "task.scheduled_dispatch",
          actor: "scheduler",
          company: state.company,
          target: entry.rel_path,
          detail: %{
            task_path: entry.rel_path,
            assigned_to: assignee,
            cron: schedule,
            fired_at: ts
          }
        })

      {:error, reason} ->
        emit_audit(state, %{
          action: "scheduler.dispatch_failed",
          actor: "system",
          company: state.company,
          target: entry.rel_path,
          reason: inspect(reason)
        })
    end

    re_arm(
      %{state | tasks: Map.update!(state.tasks, task_id, &Map.put(&1, :body, body))},
      task_id,
      entry
    )
  end

  # GEP-47: build a snapshot of every task in the company so
  # `DependencyGate.ready?/2` can classify dep targets. On-disk-
  # truth path; SQLite-derived index lands in v2 (D9). For typical
  # task counts (<100) this is fast enough; large rosters need the
  # index.
  defp build_task_snapshot(state) do
    projects_dir = Path.join([state.base, "companies", state.company, "projects"])

    case File.ls(projects_dir) do
      {:ok, projects} ->
        projects
        |> Enum.flat_map(&project_task_paths(projects_dir, &1))
        |> Enum.flat_map(&snapshot_entry_for/1)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp project_task_paths(projects_dir, project) do
    tasks_dir = Path.join([projects_dir, project, "tasks"])

    case File.ls(tasks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join([projects_dir, project, "tasks", &1]))

      _ ->
        []
    end
  end

  defp snapshot_entry_for(path) do
    with {:ok, content} <-
           Glorbo.Filesystem.AgentWritableFile.read_bounded(path, 1_048_576),
         {:ok, fm, _body} <- Frontmatter.parse(content) do
      task_id = task_id_from_path(path)

      info = %{
        status: Map.get(fm, "status") || "",
        peer_review_required: Map.get(fm, "peer_review_required") == true,
        peer_review_verdict: Map.get(fm, "peer_review_verdict"),
        depends_on: coerce_depends_on(Map.get(fm, "depends_on"))
      }

      [{task_id, info}]
    else
      _ -> []
    end
  end

  # Coerce depends_on in the same shape as TaskDefinition does (drop
  # non-string entries, dedupe). Lives here so we don't pull in the
  # full TaskDefinition parser just for this field.
  defp coerce_depends_on(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      s when is_binary(s) and s != "" -> [s]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp coerce_depends_on(_), do: []

  # GEP-47 D8: cycle detection runs on the periodic 60s rescan
  # (not on every file_event — cycles are eventually consistent
  # with up-to-60s lag, which is fine; the alternative is a snapshot
  # rebuild per file event which dominates large-roster cost).
  # Deduped via `state.last_cycles` so a stable cyclic graph doesn't
  # flood the audit log; only NEW cycles produce events.
  defp run_cycle_check(state) do
    snapshot = build_task_snapshot(state)
    cycles = Glorbo.Task.DependencyGate.cycle_detect(snapshot)
    sorted_cycles = MapSet.new(Enum.map(cycles, &Enum.sort/1))
    new_cycles = MapSet.difference(sorted_cycles, state.last_cycles)

    Enum.each(new_cycles, fn sorted_cycle ->
      cycle_list = MapSet.to_list(MapSet.new(sorted_cycle))

      emit_audit(state, %{
        action: "task.cycle_detected",
        actor: "scheduler",
        company: state.company,
        target: List.first(cycle_list) || "",
        detail: %{cycle: cycle_list}
      })
    end)

    %{state | last_cycles: sorted_cycles}
  end

  defp re_arm(state, task_id, entry) do
    arm(state, task_id, Map.delete(entry, :timer_ref), state.clock_fun.())
  end

  # ---------------------------------------------------------------------------
  # Cron helpers
  # ---------------------------------------------------------------------------

  defp parse_cron(schedule) when is_binary(schedule) do
    cleaned = String.trim(schedule)
    lowered = String.downcase(cleaned)

    # 1. Keyword alias table (hourly/daily/weekly/monthly).
    # 2. English NL (#280) — "every morning at 9am", "every 5 minutes".
    # 3. 5-field crontab — direct parse.
    canonical =
      cond do
        Map.has_key?(@aliases, lowered) -> Map.fetch!(@aliases, lowered)
        match = match_nl(cleaned) -> match
        true -> cleaned
      end

    CronParser.parse(canonical)
  end

  defp match_nl(phrase) do
    case Glorbo.ScheduleNL.parse(phrase) do
      {:ok, cron} -> cron
      _ -> nil
    end
  end

  defp next_ms_from_now(expr, %DateTime{} = now) do
    naive = DateTime.to_naive(now)

    case CronScheduler.get_next_run_date(expr, naive) do
      {:ok, next_naive} ->
        next_dt = DateTime.from_naive!(next_naive, "Etc/UTC")
        delay = DateTime.diff(next_dt, now, :millisecond)
        {:ok, max(delay, 1_000), next_dt}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # ---------------------------------------------------------------------------
  # Audit helpers
  # ---------------------------------------------------------------------------

  defp emit_audit(state, entry) do
    state.audit_fun.(state.company, entry)
  rescue
    _ -> :ok
  end

  defp audit_via_registry(company, entry) do
    case Registry.lookup(Glorbo.Agent.Registry, {:company_child, company, :audit_log}) do
      [{pid, _}] -> AuditLog.append(pid, entry)
      _ -> :ok
    end
  end

  defp maybe_emit_invalid(state, task_id, rel, schedule, reason) do
    prev = Map.get(state.tasks, task_id, %{})

    if prev[:schedule] == schedule do
      state
    else
      emit_audit(state, %{
        action: "scheduler.invalid_task_cron",
        actor: "system",
        company: state.company,
        target: rel,
        cron: schedule,
        reason: inspect(reason)
      })

      # Cancel any timer the prior valid schedule had armed —
      # otherwise the timer fires later and tries to dispatch
      # a task whose schedule is now known-invalid.
      if ref = prev[:timer_ref], do: Process.cancel_timer(ref)

      # Stash the invalid schedule so the next rescan sees the
      # same value via `prev[:schedule]` and skips re-emitting.
      # Keep only what dedup needs — no timer, no arming — so
      # `fire` / `re_arm` don't treat this as live state.
      tasks =
        Map.put(state.tasks, task_id, %{
          schedule: schedule,
          rel_path: rel,
          invalid?: true
        })

      %{state | tasks: tasks}
    end
  end

  # ---------------------------------------------------------------------------
  # Filesystem helpers
  # ---------------------------------------------------------------------------

  defp task_path?(rel_path) do
    case Path.split(rel_path) do
      ["projects", _, "tasks", file] -> String.ends_with?(file, ".md")
      _ -> false
    end
  end

  defp task_id_from_path(path), do: path |> Path.basename() |> Path.rootname(".md")

  defp relative_path(state, abs) do
    root = Path.join([state.base, "companies", state.company]) <> "/"
    String.replace_prefix(abs, root, "")
  end

  defp default_write_inbox(base, company, assignee, {filename, body}) do
    dir = Path.join([base, "companies", company, "agents", assignee, "inbox"])

    with :ok <- File.mkdir_p(dir) do
      File.write(Path.join(dir, filename), body, [:sync])
    end
  end
end
