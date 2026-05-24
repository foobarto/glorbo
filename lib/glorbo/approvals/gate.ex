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

  @doc """
  Mark a Director-driven approval decision as in-flight. Callers
  (`GlorboWeb.Actions.set_approval`) MUST invoke this **before**
  writing the task frontmatter. The Gate's watcher-handler later
  checks this mark to distinguish legitimate Director writes from
  agent self-approval attempts (Threatmodel H4).

  Marks expire 10 seconds after insertion so stale entries can't
  grant future file writes.
  """
  @spec mark_director_decision(GenServer.server(), String.t()) :: :ok
  def mark_director_decision(server, task_path) when is_binary(task_path) do
    GenServer.call(server, {:mark_director_decision, task_path})
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
      pubsub: Keyword.get(opts, :pubsub, Glorbo.PubSub),
      # Threatmodel H4: set of `task_path` marked by the Director's
      # `set_approval` path just before it writes the frontmatter.
      # The watcher-driven approval handler consults this to tell
      # legitimate Director flips from agent self-approval attempts.
      # Values are monotonic timestamps in milliseconds.
      director_pending: %{},
      # GEP-41 Round N-3: in-memory dedupe for peer-review-request
      # audit emission. Each task_path gets at most one
      # `peer_review.requested` entry per Gate lifetime. Re-emit on
      # restart is acceptable (audit dedupe happens at read-time).
      peer_review_requested: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:request_approval, req}, _from, state) do
    {reply, state} = do_request_approval(req, state)
    {:reply, reply, state}
  end

  def handle_call({:mark_director_decision, task_path}, _from, state) do
    now = System.monotonic_time(:millisecond)
    pending = Map.put(prune_expired(state.director_pending, now), task_path, now)
    {:reply, :ok, %{state | director_pending: pending}}
  end

  # 10 s TTL — plenty of headroom for the file write + watcher round-trip
  # (sub-second in practice) but short enough that an abandoned Director
  # mark can't be repurposed later.
  @director_mark_ttl_ms 10_000

  defp prune_expired(pending, now) do
    for {path, ts} <- pending, now - ts < @director_mark_ttl_ms, into: %{}, do: {path, ts}
  end

  defp consume_director_mark(state, task_path) do
    now = System.monotonic_time(:millisecond)
    pending = prune_expired(state.director_pending, now)

    case Map.pop(pending, task_path) do
      {nil, pending} -> {:agent_bypass, %{state | director_pending: pending}}
      {_ts, pending} -> {:director, %{state | director_pending: pending}}
    end
  end

  @impl true
  def handle_info({:file_event, rel_path, events}, state) do
    state =
      if :modified in events and Regex.match?(@project_task_re, rel_path) do
        handle_projects_event(rel_path, state)
      else
        state
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
        target: td.task_path,
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
    kind: sentinel-approval/v1
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

    # threatmodel M03: `state/` is agent-writable. Refuse to follow a
    # symlink the agent pre-planted at the sentinel path — otherwise
    # the host write lands at an attacker-chosen target.
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        File.write!(path, body)

      {:error, :enoent} ->
        File.write!(path, body)

      {:ok, %File.Stat{type: type}} ->
        raise "refusing sentinel write: #{inspect(type)} at #{path}"
    end

    :ok
  end

  defp upsert_awaiting(state, agent, td) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      company_slug: state.company,
      task_path: td.task_path,
      agent_slug: agent,
      status: "awaiting",
      requested_at: now
    }

    changeset = TasksApprovalState.changeset(%TasksApprovalState{}, attrs)

    # Composite unique index on `(company_slug, task_path)` (wave 31 — pre-fix
    # was task_path alone, allowing cross-company bleed). If a row already
    # exists, leave it. "awaiting" is the starting state; if already
    # approved or denied the Director is re-opening — out of scope for
    # v0.0.1 (D-37, denied tasks move to history/).
    case state.repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:company_slug, :task_path]
         ) do
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
        target: rel_path,
        company: state.company
      })

      state
    else
      abs_path = Path.join([state.base, "companies", state.company, rel_path])

      case TaskDefinition.parse_file(abs_path, base: state.base, company: state.company) do
        {:ok, td} ->
          resolve_status(td, abs_path, state)

        {:error, reason} ->
          audit(state, %{
            action: "approval.parse_error",
            actor: "system",
            target: rel_path,
            error: inspect(reason),
            company: state.company
          })

          state
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

  defp resolve_status(%TaskDefinition{status: "approved"} = td, abs_path, state) do
    case find_awaiting_row(state, td.task_path) do
      nil ->
        audit(state, %{
          action: "approval.spurious",
          actor: "director",
          agent: nil,
          target: td.task_path,
          status: "approved",
          company: state.company
        })

        state

      %TasksApprovalState{agent_slug: agent} ->
        case consume_director_mark(state, td.task_path) do
          {:director, state} ->
            case peer_review_ready?(td, state) do
              :ok ->
                :ok = resolve_granted(td, agent, state)
                state

              {:error, reason} ->
                revert_peer_review_block(td, abs_path, agent, reason, state)
                state
            end

          {:agent_bypass, state} ->
            revert_unauthorised_status(td, abs_path, agent, "approved", state)
            state
        end
    end
  end

  # GEP-41 D4 + codex P2: a peer-review `block` verdict lands as
  # `status: denied` + `peer_review_verdict: "block"`. The generic
  # `"denied"` clause below treats unmarked flips as agent self-
  # approval attempts and reverts them to `awaiting`, which would
  # clobber a legitimate reviewer block. Short-circuit here so the
  # reviewer-emitted denial sticks; the Director decides next via
  # the Inbox.
  defp resolve_status(
         %TaskDefinition{status: "denied", peer_review_verdict: "block"},
         _abs_path,
         state
       ) do
    state
  end

  defp resolve_status(%TaskDefinition{status: "denied"} = td, abs_path, state) do
    case find_awaiting_row(state, td.task_path) do
      nil ->
        audit(state, %{
          action: "approval.spurious",
          actor: "director",
          agent: nil,
          target: td.task_path,
          status: "denied",
          company: state.company
        })

        state

      %TasksApprovalState{agent_slug: agent} ->
        case consume_director_mark(state, td.task_path) do
          {:director, state} ->
            :ok = resolve_denied(td, agent, state)
            state

          {:agent_bypass, state} ->
            revert_unauthorised_status(td, abs_path, agent, "denied", state)
            state
        end
    end
  end

  # GEP-41 Round N-3: when a task sits at `pending-approval` with
  # `peer_review_required: true` and no verdict yet, emit a
  # `peer_review.requested` audit entry so Directors (and future
  # dispatcher logic) can see the queue of reviewer-blocked work.
  # Dedupe via in-memory MapSet — we emit once per Gate lifetime
  # per task_path; restarts re-emit (cheap), verdict-flips clear
  # the entry so re-open after revise would re-emit.
  #
  # GEP-42: on the same edge, drop a peer-review wake sentinel
  # into the reviewer's inbox via `Actions.Reviews.request_
  # peer_review/4`. The MapSet entry is added only when BOTH the
  # audit emit AND the sentinel write succeed — a missing
  # reviewer (D5) leaves the dedupe set unchanged so the next
  # gate observation retries.
  defp resolve_status(
         %TaskDefinition{
           status: "pending-approval",
           peer_review_required: true,
           peer_review_verdict: nil
         } = td,
         abs_path,
         state
       ) do
    maybe_emit_peer_review_requested(td, abs_path, state)
  end

  # When a verdict lands, drop the dedupe entry so a subsequent
  # revise→re-open cycle re-notifies.
  defp resolve_status(
         %TaskDefinition{peer_review_verdict: verdict} = td,
         _abs_path,
         state
       )
       when verdict in ["approve", "revise", "block"] do
    %{state | peer_review_requested: MapSet.delete(state.peer_review_requested, td.task_path)}
  end

  # Any other status (pending-approval, in-progress, completed, custom) is a
  # no-op — the sentinel stays in place until approved/denied.
  defp resolve_status(_td, _abs_path, state), do: state

  defp maybe_emit_peer_review_requested(td, abs_path, state) do
    if MapSet.member?(state.peer_review_requested, td.task_path) do
      state
    else
      audit(state, %{
        action: "peer_review.requested",
        actor: "system",
        target: td.task_path,
        company: state.company,
        reviewer: td.reviewer || "unspecified",
        severity: severity_string(td.severity)
      })

      # GEP-42: drop the wake sentinel. On success → mark dedupe.
      # On `:reviewer_absent` / `:inbox_unwritable` → leave the
      # MapSet unchanged so the next observation retries (covers
      # the case where the reviewer is scaffolded mid-flight).
      # `Actions.Reviews.request_peer_review/4` emits its own
      # `peer_review.dispatched` / `peer_review.skipped_no_reviewer`
      # audits; the gate doesn't double-audit.
      case dispatch_peer_review_request(td, abs_path, state) do
        {:ok, _} ->
          %{
            state
            | peer_review_requested: MapSet.put(state.peer_review_requested, td.task_path)
          }

        {:error, _} ->
          state
      end
    end
  end

  # GEP-42: side-effect on the same edge as `peer_review.requested`.
  # `audit_server` is the Gate's existing audit handle (bare module
  # in production, fake in tests). Wrapping in rescue keeps a
  # mis-configured Reviews call from taking the Gate down — the
  # gate's job is to gate, not to chase reviewer plumbing.
  defp dispatch_peer_review_request(td, abs_path, state) do
    Glorbo.Actions.Reviews.request_peer_review(
      state.company,
      abs_path,
      td,
      base: state.base,
      audit: state.audit_server
    )
  rescue
    _ -> {:error, :dispatcher_raised}
  end

  defp severity_string(nil), do: "unset"
  defp severity_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp severity_string(other), do: to_string(other)

  # GEP-41 D5: peer review runs BEFORE Director approval. When
  # `peer_review_required: true`, the Director's `status: approved`
  # flip is held until a verdict lands:
  #
  #   * verdict missing      → :awaiting_peer_review
  #   * verdict = "block"    → :peer_review_blocked
  #   * verdict = "revise"   → :peer_review_revise
  #   * verdict = "approve"  → :ok (Director's flip takes effect)
  #
  # `peer_review_required: false` (or unset) → :ok unconditionally.
  defp peer_review_ready?(%TaskDefinition{peer_review_required: false}, _state), do: :ok
  defp peer_review_ready?(%TaskDefinition{peer_review_required: nil}, _state), do: :ok

  # Codex round-4 finding (PR #36): the agent assigned to a task can
  # write its own task .md file (`projects:write:<proj>` → `tasks/`)
  # and pre-seed `peer_review_required: true` +
  # `peer_review_verdict: "approve"` directly into the frontmatter.
  # `Glorbo.Actions.Tasks.record_peer_review_verdict/4` (the legit
  # path) enforces `guard_actor_is_reviewer/2` and emits a
  # `task.peer_review.approve` audit row with `actor: "agent:<reviewer>"`.
  # Require the corroborating audit entry from the actor named in
  # `peer_review_verdict_by` before honouring an `approve` verdict
  # — same pattern as the loop-detector corroboration (round 3).
  # `Tools.valid_audit_action?/1` (round 3) keeps the agent from
  # forging the audit row through `audit_events`.
  defp peer_review_ready?(%TaskDefinition{peer_review_verdict: "approve"} = td, state) do
    if peer_review_verdict_corroborated?(td, state) do
      :ok
    else
      Logger.warning(
        "approvals/gate: peer_review_verdict=approve for #{td.task_path} but no " <>
          "corroborating `task.peer_review.approve` audit entry from " <>
          "agent:#{td.peer_review_verdict_by || "<unset>"} — refusing as awaiting_peer_review"
      )

      {:error, :awaiting_peer_review}
    end
  end

  defp peer_review_ready?(%TaskDefinition{peer_review_verdict: "block"}, _state),
    do: {:error, :peer_review_blocked}

  defp peer_review_ready?(%TaskDefinition{peer_review_verdict: "revise"}, _state),
    do: {:error, :peer_review_revise}

  defp peer_review_ready?(%TaskDefinition{peer_review_verdict: nil}, _state),
    do: {:error, :awaiting_peer_review}

  defp peer_review_ready?(_td, _state), do: {:error, :awaiting_peer_review}

  # Match the legit verdict emitter: Actions.Tasks.record_peer_review_verdict
  # emits `action: "task.peer_review.approve"` with
  # `actor: "agent:<reviewer-slug>"`. The `verdict_by` field on the
  # task must equal that reviewer slug. Scope the audit scan to a
  # reasonable window — the verdict was recorded recently if at
  # all (the gate runs on the Director's status flip).
  defp peer_review_verdict_corroborated?(%TaskDefinition{} = td, %{base: base, company: co}) do
    case to_string(td.peer_review_verdict_by) do
      "" ->
        # No `peer_review_verdict_by` → can't even ask whose
        # verdict it was. Refuse.
        false

      verdict_by ->
        # Codex P0 review of 3dc4eba: the legit emitter
        # `Glorbo.Actions.Tasks.emit_verdict_audit/6` writes
        # `actor: <bare-slug>` (no `agent:` prefix). The previous
        # `"agent:" <> verdict_by` comparison meant EVERY real
        # reviewer-emitted approval would fail corroboration —
        # only the synthetic-seed test passed. Compare against the
        # bare slug AND `target == task_path` (no fuzzy match —
        # avoid cross-task corroboration leaks through
        # `Audit.Query`'s substring fallback).
        base
        |> Glorbo.Audit.Query.for_task(co, td.task_path, limit: 100)
        |> Enum.any?(fn entry ->
          entry["action"] == "task.peer_review.approve" and
            entry["actor"] == verdict_by and
            entry["target"] == td.task_path
        end)
    end
  end

  defp revert_peer_review_block(td, abs_path, agent, reason, state) do
    audit(state, %{
      action: "approval.peer_review_block",
      actor: "system",
      agent: agent,
      target: td.task_path,
      peer_review_reason: to_string(reason),
      peer_review_verdict: td.peer_review_verdict,
      company: state.company
    })

    # Revert status to pending-approval so the Director's mark
    # doesn't latch. The director can re-flip once the verdict
    # clears (verdict changes land via the reviewer agent; the
    # director waits for that event).
    case File.lstat(abs_path) do
      {:ok, %{type: :regular}} ->
        _ = TaskDefinition.write_frontmatter(abs_path, %{"status" => "pending-approval"})

      _ ->
        :ok
    end

    :ok
  end

  # Threatmodel H4 (wave 4): an awaiting task file flipped to
  # approved/denied without a matching Director mark. Only the
  # Director's `set_approval` path marks the Gate before writing;
  # any other writer is an agent with `tasks:update` rwx on the
  # project tasks directory abusing that grant to self-approve.
  # Revert the file back to `awaiting` and audit the attempt.
  defp revert_unauthorised_status(td, abs_path, agent, attempted, state) do
    audit(state, %{
      action: "approval.self_approval_rejected",
      actor: "system",
      agent: agent,
      target: td.task_path,
      attempted_status: attempted,
      company: state.company
    })

    case File.lstat(abs_path) do
      {:ok, %{type: :regular}} -> _ = TaskDefinition.write(abs_path, %{status: "awaiting"})
      _ -> :ok
    end

    :ok
  end

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
      target: td.task_path,
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
      target: td.task_path,
      denied_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      denial_reason: td.denial_reason,
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

    history_dir = Path.dirname(history_path)

    # threatmodel M03. `File.mkdir_p!` follows symlinks; if any
    # ancestor segment was planted as a symlink by a prior path-grant
    # or operator edit, the rename lands at the aliased target.
    # Refuse if any segment from base→history_dir is a symlink.
    # Opencode round-3 flagged. Historical behaviour (crash on
    # unexpected shape) is preserved via the `audit` path below.
    if Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(history_dir) do
      audit(state, %{
        action: "approval.rename_failed",
        actor: "system",
        target: td.task_path,
        history_path: history_path,
        error: "history_dir_has_symlinked_segment",
        company: state.company
      })
    else
      File.mkdir_p!(history_dir)

      case File.rename(td.file_path, history_path) do
        :ok ->
          :ok

        {:error, reason} ->
          audit(state, %{
            action: "approval.rename_failed",
            actor: "system",
            target: td.task_path,
            history_path: history_path,
            error: inspect(reason),
            company: state.company
          })

          :ok
      end
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
      company_slug: state.company,
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
           conflict_target: [:company_slug, :task_path]
         ) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp find_awaiting_row(state, task_path) do
    state.repo.get_by(TasksApprovalState,
      company_slug: state.company,
      task_path: task_path,
      status: "awaiting"
    )
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
