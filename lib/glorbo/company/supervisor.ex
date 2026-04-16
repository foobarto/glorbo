defmodule Glorbo.Company.Supervisor do
  @moduledoc """
  Per-company supervisor (AGT-01; D-44).

  Owns the 6-child supervision tree (expanded from Phase 2's 2-child shape
  by Plan 03-05):

    1. `Glorbo.Company.AuditLog`       — append-only JSONL + SQLite mirror (Plan 2-01)
    2. `Glorbo.Filesystem.Watcher`     — inotify + PubSub broadcast (Plan 2-04 + 3-05)
    3. `Glorbo.Company.Router`         — permission-checked outbox routing (Plan 3-02)
    4. `Glorbo.Company.Scheduler`      — cron heartbeats (Plan 3-02)
    5. `Glorbo.Company.BudgetTracker`  — pre-dispatch USD gate (Plan 3-02)
    6. `Glorbo.Company.AgentSupervisor` — per-agent DynamicSupervisor (Plan 3-03)

  Approvals.Gate lives as a DynamicSupervisor'd child of Router per D-44
  collapse (shared PubSub subscription context; not a 7th sibling).

  Strategy: `:one_for_one` — killing any single child restarts only that
  child. Kill this supervisor → only this company's 6 children restart;
  other companies + the dashboard are unaffected.

  ## Cross-child state recovery (D-45)

    * **Router crash:** Watcher re-emits recent outbox events when Router
      re-subscribes to `company:<co>:outbox` on restart.
    * **BudgetTracker crash:** rebuilds cap cache lazily; SQLite `budgets`
      rows are authoritative; alert file idempotency accepts one duplicate
      write per agent-month after crash (File.write! is content-idempotent).
    * **Scheduler crash:** heartbeats re-registered by AgentSupervisor's
      per-agent startup hooks.
    * **AgentSupervisor crash:** per-agent sub-trees are transient children
      — they do NOT auto-restart on AgentSupervisor restart. The next
      company boot re-starts them from agent.md files.

  ## Boot-order invariants

    1. AuditLog first — every subsequent child's audit emits go here.
    2. Watcher second — Router + Gate subscribe to its PubSub broadcasts.
    3. Router, Scheduler, BudgetTracker in parallel (no direct deps).
    4. AgentSupervisor last — children may call Router.route/2 etc during
       their own startup.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))

    children = [
      {Glorbo.Company.AuditLog,
       [name: child_name(company, :audit_log), company: company, base: base]},
      {Glorbo.Filesystem.Watcher,
       [name: child_name(company, :file_watcher), company: company, base: base]},
      {Glorbo.Company.Router, [name: child_name(company, :router), company: company, base: base]},
      {Glorbo.Company.Scheduler,
       [name: child_name(company, :scheduler), company: company, base: base]},
      {Glorbo.Company.BudgetTracker,
       [name: child_name(company, :budget_tracker), company: company, base: base]},
      {Glorbo.Company.AgentSupervisor,
       [name: child_name(company, :agent_sup), company: company, base: base]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp child_name(company, role), do: String.to_atom("#{company}_#{role}")
end
