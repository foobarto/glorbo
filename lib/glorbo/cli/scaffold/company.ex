defmodule Glorbo.CLI.Scaffold.Company do
  @moduledoc """
  TODO(plan-02): Implement `glorbo new company <slug>` scaffold per
  D-11 (slug regex `~r/\\A[a-z0-9-]+\\z/`, idempotent).

  Wave-0 stub.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:new_company, 0, "new company: not implemented in Wave 0 (Plan 02 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo new company — scaffold a new company directory.

    USAGE
      glorbo new company <slug>

    SLUG
      Lowercase alphanumerics + hyphens only (~r/\\A[a-z0-9-]+\\z/).

    BEHAVIOR
      Creates ~/.glorbo/companies/<slug>/ with company.md + agents/,
      projects/, channels/, audit/. Idempotent on re-run.
    """
  end
end
