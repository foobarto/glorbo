defmodule Glorbo.CLI.Migrate do
  @moduledoc """
  TODO(plan-03): Implement `glorbo migrate` — thin wrapper over
  `Ecto.Migrator.run(Glorbo.Repo, :up, all: true)` per D-18.

  Wave-0 stub.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:migrate, 0, "migrate: not implemented in Wave 0 (Plan 03 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo migrate — run Ecto migrations against ~/.glorbo/glorbo.db.

    USAGE
      glorbo migrate

    BEHAVIOR
      Runs all pending :up migrations. Exits non-zero on failure. No
      --rollback in v0.0.2 (hand-edit migration files for advanced cases).
    """
  end
end
