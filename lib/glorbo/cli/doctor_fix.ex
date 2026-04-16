defmodule Glorbo.CLI.DoctorFix do
  @moduledoc """
  TODO(plan-03): Implement `doctor --fix` — routes failed Doctor checks
  through `Glorbo.Doctor.Fixer` per D-16. Unlike the other CLI modules,
  this one takes PRE-PARSED `OptionParser` opts (keyword list) — the
  parent `doctor` dispatch branch already parses flags.

  Wave-0 stub.
  """

  @spec run(keyword()) :: Glorbo.CLI.result()
  def run(_opts) do
    {:doctor, 0, "doctor --fix: not implemented in Wave 0 (Plan 03 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo doctor --fix — attempt to repair failed doctor checks.

    USAGE
      glorbo doctor --fix [--dry-run]

    BEHAVIOR
      Runs all doctor checks; for each failed check with a registered
      repair in Glorbo.Doctor.Fixer, attempts the repair and re-checks.
      Repairs are non-destructive on user data.
    """
  end
end
