defmodule Glorbo.Approvals.Gate do
  @moduledoc """
  Per-company approval gate (SEC-04; D-34..D-37).

  Owns the lifecycle of tasks whose frontmatter includes
  `requires_approval: director`:

    1. **Request** — Agent.Server calls `request_approval/2` before running
       such a task. Gate writes a sentinel file at
       `agents/<name>/state/awaiting-approval-<task_id>.md`, upserts a
       `Glorbo.TasksApprovalState` row with status `"awaiting"`, and emits
       an `approval.requested` audit event. Agent returns to idle.
    2. **Resolve** — Director edits the task file's frontmatter
       (`status: approved` or `status: denied`). Plan 03-05's
       `Glorbo.Filesystem.Watcher` broadcasts `{:file_event, rel_path,
       events}` on topic `"company:<slug>:projects"`. Gate's `handle_info`
       filters for `projects/**/*.md`, parses the task file, and — if
       status flipped to `"approved"` or `"denied"` — resolves:

         * **approved** → upsert state `"approved"` + emit
           `approval.granted` + call `agent_wake_fun(agent,
           :director_approval, task_map)` + remove sentinel.
         * **denied** → upsert state `"denied"` (with optional
           `denial_reason`) + emit `approval.denied` + `File.rename!/2`
           task file to `history/tasks/<task_id>.md` + remove sentinel.
           No agent wake.
         * **approved/denied with no matching sentinel** → emit
           `approval.spurious` (Director pre-approved; not a fault — the
           agent will pick up `status: approved` on next inbox scan).

  ## Defensive posture

    * Only files matching `~r{\\Aprojects/.+/tasks/.+\\.md\\z}` trigger
      approval resolution — prevents feedback loops when the Gate's own
      sentinel write or the audit log triggers a Watcher event
      (T-03-24).
    * Sentinel correlation is via `{agent, task_id}` and the unique
      `task_path` index in `tasks_approval_state` — a malicious rename of
      the task file doesn't clobber state (T-03-25).
    * Every state transition emits an audit event (T-03-26). Timeline is
      reconstructable from `tasks_approval_state.requested_at` +
      `resolved_at` + `reason` + audit JSONL.
    * Parse errors → `approval.parse_error` audit + continue (T-03-27 —
      one malformed task.md does not lock up the gate).
    * Rename failures → `approval.rename_failed` audit; DB still marks
      the task denied. Next reindex surfaces the disk/SQLite mismatch
      (T-03-29).

  ## State is empty

  Gate state is intentionally minimal (`company, base, repo, fns, ...`).
  After a crash, the fresh Gate reads sentinel files + SQLite rows on
  demand — no in-memory replay needed. This matches Plan 03-02's
  BudgetTracker and Scheduler pattern (D-45 — all company-supervisor
  children rebuild from filesystem + SQLite on restart).
  """
  use GenServer

  require Logger

  alias Glorbo.Company.AuditLog
  alias Glorbo.Repo
  alias Glorbo.TaskDefinition
  alias Glorbo.TasksApprovalState

  @project_task_re ~r{\Aprojects/.+/tasks/.+\.md\z}

  @type request :: %{
          agent: String.t(),
          task_definition: TaskDefinition.t(),
          requesting_trigger: atom() | String.t()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a per-company Gate.

  ## Required opts

    * `:company` — company slug.
    * `:base` — Glorbo root (e.g. `~/.glorbo`).

  ## Optional opts

    * `:name` — GenServer name (default: nameless pid).
    * `:repo` — Ecto repo module (default: `Glorbo.Repo`).
    * `:audit_fun` — `(server, entry -> :ok)` (default:
      `&Glorbo.Company.AuditLog.append/2`).
    * `:audit_server` — server argument passed as first arg to
      `audit_fun` (default: `Glorbo.Company.AuditLog`).
    * `:agent_wake_fun` — `(agent, trigger, task_map -> any)`
      (default: Registry-lookup + `Glorbo.Agent.Server.wake/3`; tests
      pass fakes). Returning `:noproc` / `nil` / raising is tolerated —
      the approval still completes.
    * `:pubsub` — `Phoenix.PubSub` name (default: `Glorbo.PubSub`).
    * `:subscribe?` — whether to subscribe to
      `"company:<slug>:projects"` in init (default: `true`; tests that
      drive events manually pass `false`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Ask the Gate to open an approval. Writes sentinel + DB row + audit.
  Idempotent: duplicate calls for the same `{agent, task_id}` are
  short-circuited (no second sentinel write, no second audit).
  """
  @spec request_approval(GenServer.server(), request()) :: :ok | {:error, term()}
  def request_approval(server, %{} = req) do
    GenServer.call(server, {:request_approval, req})
  end

  # `resolve_approval/3` moved to `Glorbo.Test.GateHelpers` — it was a
  # test-only shortcut that used `:sys.get_state/1` on the production API
  # surface. Tests now call `Glorbo.Test.GateHelpers.resolve_approval/3`
  # directly.

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    base = Keyword.fetch!(opts, :base)

    if Keyword.get(opts, :subscribe?, true) do
      pubsub = Keyword.get(opts, :pubsub, Glorbo.PubSub)
      :ok = Phoenix.PubSub.subscribe(pubsub, "company:#{company}:projects")
    end

    state = %{
      company: company,
      base: base,
      repo: Keyword.get(opts, :repo, Repo),
      audit_fun: Keyword.get(opts, :audit_fun, &AuditLog.append/2),
      audit_server: Keyword.get(opts, :audit_server, AuditLog),
      agent_wake_fun: Keyword.get(opts, :agent_wake_fun, &default_agent_wake/3),
      pubsub: Keyword.get(opts, :pubsub, Glorbo.PubSub)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:request_approval, req}, _from, state) do
    {reply, state} = do_request_approval(req, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:file_event, rel_path, events}, state) do
    if :modified in events and Regex.match?(@project_task_re, rel_path) do
      handle_projects_event(rel_path, state)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Approval request
  # ---------------------------------------------------------------------------

  defp do_request_approval(req, state) do
    agent = req.agent
    td = req.task_definition
    trigger = req.requesting_trigger
    sentinel_path = sentinel_path(state, agent, td.task_id)

    if File.exists?(sentinel_path) do
      {:ok, state}
    else
      :ok = write_sentinel(sentinel_path, agent, td, trigger)
      :ok = upsert_awaiting(state, agent, td)
      # Reassign task to director while approval is pending.
      # On grant, resolve_granted will restore assigned_to = <agent>.
      # On deny, the task moves to history, so no restore needed.
      _ = reassign_task(state, td.task_path, "director")

      audit(state, %{
        action: "approval.requested",
        actor: agent,
        agent: agent,
        task_path: td.task_path,
        task_id: td.task_id,
        previous_assigned_to: td.assigned_to || "",
        company: state.company
      })

      {:ok, state}
    end
  end

  defp reassign_task(state, task_path, assignee) do
    abs = Path.join([state.base, "companies", state.company, task_path])
    Glorbo.TaskDefinition.write(abs, %{assigned_to: assignee})
  rescue
    _ -> :error
  end

  defp sentinel_path(state, agent, task_id) do
    Path.join([
      state.base,
      "companies",
      state.company,
      "agents",
      agent,
      "state",
      "awaiting-approval-#{task_id}.md"
    ])
  end

  defp write_sentinel(path, agent, td, trigger) do
    File.mkdir_p!(Path.dirname(path))
    requested_at = DateTime.utc_now() |> DateTime.to_iso8601()

    body = """
    ---
    agent: #{agent}
    task_path: #{td.task_path}
    task_id: #{td.task_id}
    requested_at: "#{requested_at}"
    requesting_trigger: #{trigger}
    ---

    # Awaiting Director approval

    **Task:** #{td.title || td.task_id}

    This task requires approval because `requires_approval: director` is set in its frontmatter.
    To approve: edit the task file and set `status: approved` in its frontmatter.
    To deny: edit the task file and set `status: denied` in its frontmatter.
    """

    File.write!(path, body)
    :ok
  end

  defp upsert_awaiting(state, agent, td) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      task_path: td.task_path,
      agent_slug: agent,
      status: "awaiting",
      requested_at: now
    }

    changeset = TasksApprovalState.changeset(%TasksApprovalState{}, attrs)

    # Unique index on task_path — if a row already exists, leave it
    # alone. "awaiting" is the starting state; if it's already approved
    # or denied the Director is re-opening the task, which is out of
    # scope for v0.0.1 (D-37 — denied tasks move to history/).
    case state.repo.insert(changeset, on_conflict: :nothing, conflict_target: [:task_path]) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Resolution (PubSub event handler)
  # ---------------------------------------------------------------------------

  defp handle_projects_event(rel_path, state) do
    # WR-01 defense-in-depth: reject any rel_path with `..` traversal segments
    # before hitting the filesystem. `Path.join/1` does not normalise `..`
    # segments and `File.read/1` resolves them through the kernel — an
    # untrusted PubSub publisher could otherwise escape the company dir (e.g.
    # `projects/../../../etc/passwd.md`).
    if unsafe_rel_path?(rel_path) do
      audit(state, %{
        action: "approval.rejected_traversal",
        actor: "system",
        task_path: rel_path,
        company: state.company
      })

      :ok
    else
      abs_path = Path.join([state.base, "companies", state.company, rel_path])

      case TaskDefinition.parse_file(abs_path, base: state.base, company: state.company) do
        {:ok, td} ->
          resolve_status(td, state)

        {:error, reason} ->
          audit(state, %{
            action: "approval.parse_error",
            actor: "system",
            task_path: rel_path,
            error: inspect(reason),
            company: state.company
          })

          :ok
      end
    end
  end

  # Reject any path that either contains `..` as a full segment or starts with
  # `/` (absolute). `String.contains?(rel_path, "..")` would false-positive on
  # files like `foo..bar.md`; splitting on `/` and checking each segment is
  # exact.
  defp unsafe_rel_path?(rel_path) when is_binary(rel_path) do
    String.starts_with?(rel_path, "/") or
      rel_path |> Path.split() |> Enum.any?(fn seg -> seg == ".." end)
  end

  defp unsafe_rel_path?(_), do: true

  defp resolve_status(%TaskDefinition{status: "approved"} = td, state) do
    case find_awaiting_row(state, td.task_path) do
      nil ->
        audit(state, %{
          action: "approval.spurious",
          actor: "director",
          agent: nil,
          task_path: td.task_path,
          status: "approved",
          company: state.company
        })

      %TasksApprovalState{agent_slug: agent} ->
        resolve_granted(td, agent, state)
    end
  end

  defp resolve_status(%TaskDefinition{status: "denied"} = td, state) do
    case find_awaiting_row(state, td.task_path) do
      nil ->
        audit(state, %{
          action: "approval.spurious",
          actor: "director",
          agent: nil,
          task_path: td.task_path,
          status: "denied",
          company: state.company
        })

      %TasksApprovalState{agent_slug: agent} ->
        resolve_denied(td, agent, state)
    end
  end

  # Any other status (pending-approval, in-progress, completed, custom) is a
  # no-op — the sentinel stays in place until approved/denied.
  defp resolve_status(_td, _state), do: :ok

  defp resolve_granted(td, agent, state) do
    :ok = upsert_resolved(state, td, agent, "approved", nil)

    # Restore task assignment to the requesting agent so the Kanban
    # shows them owning the work again (the request flow swapped it
    # to "director" while waiting on approval).
    _ = reassign_task(state, td.task_path, agent)

    audit(state, %{
      action: "approval.granted",
      actor: "director",
      agent: agent,
      task_path: td.task_path,
      approved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      company: state.company
    })

    # Wake the agent (fire-and-forget; failures are tolerated — the
    # task's status: approved persists for when the agent restarts).
    task_map = %{
      task_id: td.task_id,
      task_path: td.task_path,
      prompt: td.prompt_body,
      trigger: :director_approval
    }

    safe_wake(state.agent_wake_fun, agent, :director_approval, task_map)

    # Remove sentinel AFTER the DB + audit are in place.
    sentinel = sentinel_path(state, agent, td.task_id)

    if File.exists?(sentinel) do
      File.rm(sentinel)
    end

    :ok
  end

  defp resolve_denied(td, agent, state) do
    :ok = upsert_resolved(state, td, agent, "denied", td.denial_reason)

    audit(state, %{
      action: "approval.denied",
      actor: "director",
      agent: agent,
      task_path: td.task_path,
      denied_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      reason: td.denial_reason,
      company: state.company
    })

    # Move task file to history/tasks/<task_id>.md atomically.
    history_path =
      Path.join([
        state.base,
        "companies",
        state.company,
        "history",
        "tasks",
        "#{td.task_id}.md"
      ])

    File.mkdir_p!(Path.dirname(history_path))

    case File.rename(td.file_path, history_path) do
      :ok ->
        :ok

      {:error, reason} ->
        audit(state, %{
          action: "approval.rename_failed",
          actor: "system",
          task_path: td.task_path,
          target: history_path,
          error: inspect(reason),
          company: state.company
        })

        :ok
    end

    sentinel = sentinel_path(state, agent, td.task_id)

    if File.exists?(sentinel) do
      File.rm(sentinel)
    end

    :ok
  end

  defp upsert_resolved(state, td, agent, status, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      task_path: td.task_path,
      agent_slug: agent,
      status: status,
      requested_at: now,
      resolved_at: now,
      reason: reason
    }

    changeset = TasksApprovalState.changeset(%TasksApprovalState{}, attrs)

    case state.repo.insert(changeset,
           on_conflict: [set: [status: status, resolved_at: now, reason: reason]],
           conflict_target: [:task_path]
         ) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp find_awaiting_row(state, task_path) do
    state.repo.get_by(TasksApprovalState, task_path: task_path, status: "awaiting")
  end

  defp audit(state, entry) do
    state.audit_fun.(state.audit_server, entry)
  rescue
    e ->
      Logger.error("[gate/#{state.company}] audit failed: #{Exception.message(e)}")

      :ok
  end

  defp safe_wake(wake_fun, agent, trigger, task_map) do
    wake_fun.(agent, trigger, task_map)
  rescue
    e ->
      Logger.warning("[gate] agent_wake_fun raised: #{Exception.message(e)}")

      :ok
  catch
    :exit, reason ->
      Logger.warning("[gate] agent_wake_fun exited: #{inspect(reason)}")

      :ok
  end

  # Production default — Registry-lookup + Agent.Server.wake/3. Tests pass
  # fakes via :agent_wake_fun opt. We accept dynamic dispatch against
  # Registry/Agent.Server — if Registry isn't running (pre-Plan 03-05) or
  # the agent is crashed, we log + swallow; the approval still completes.
  defp default_agent_wake(_agent, _trigger, _task_map) do
    # Plan 03-05 supervisor wires up a real wake fn at Gate start_link time.
    # Without that, we simply no-op — the task's status: approved persists
    # on disk for when the agent's next inbox scan picks it up.
    :ok
  end
end
