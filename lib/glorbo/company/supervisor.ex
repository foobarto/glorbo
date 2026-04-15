defmodule Glorbo.Company.Supervisor do
  @moduledoc """
  Per-company supervisor. Owns `FileWatcher`, `Router`, `Scheduler`,
  `BudgetTracker`, and `AuditLog` for a single company. Agents are added as
  additional dynamic children in Phase 3.

  Crash isolation: killing any single sibling restarts only that sibling;
  killing this supervisor restarts ONLY this company's processes (CLAUDE.md
  invariant: crash isolation follows the OTP supervision tree).
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

    children = [
      {Glorbo.Company.FileWatcher, company: company, name: child_name(company, :file_watcher)},
      {Glorbo.Company.Router, company: company, name: child_name(company, :router)},
      {Glorbo.Company.Scheduler, company: company, name: child_name(company, :scheduler)},
      {Glorbo.Company.BudgetTracker,
       company: company, name: child_name(company, :budget_tracker)},
      {Glorbo.Company.AuditLog, company: company, name: child_name(company, :audit_log)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp child_name(company, role), do: String.to_atom("#{company}_#{role}")
end
