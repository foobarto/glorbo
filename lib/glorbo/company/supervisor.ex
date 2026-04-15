defmodule Glorbo.Company.Supervisor do
  @moduledoc """
  Per-company supervisor. Owns exactly the Phase-2 children:

    * `Glorbo.Company.AuditLog`       — append-only JSONL + SQLite mirror (Plan 01)
    * `Glorbo.Filesystem.Watcher`     — inotify-backed per-company watcher (Plan 04)

  Phase 3 adds Router, Scheduler, BudgetTracker (and later per-agent
  children). Until then, those Phase-1 stubs return `:not_implemented` from
  their calls and are intentionally NOT in this child list — adding them
  would not crash boot today (their `start_link/1` returns `{:ok, pid}`),
  but they carry no meaningful state yet, and surfacing them prematurely
  would confuse Phase-2 observability + testing.

  Crash isolation (CLAUDE.md invariant): killing any single sibling
  restarts only that sibling; killing this supervisor restarts ONLY this
  company's processes.
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

    # B5: Phase 2 supervisor children — ONLY AuditLog + Watcher.
    # Phase 3 adds Router, Scheduler, BudgetTracker.
    children = [
      {Glorbo.Company.AuditLog,
       [name: child_name(company, :audit_log), company: company, base: base]},
      {Glorbo.Filesystem.Watcher,
       [name: child_name(company, :file_watcher), company: company, base: base]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp child_name(company, role), do: String.to_atom("#{company}_#{role}")
end
