defmodule Glorbo.CLI.DoctorFix do
  @moduledoc """
  `glorbo doctor --fix` — thin router into `Glorbo.Doctor.Fixer.run/1`.

  The parent `doctor` dispatch branch in `Glorbo.CLI` already parses
  flags (`--fix`, `--dry-run`, `--json`). This module receives the
  pre-parsed `OptionParser` opts (keyword list) and delegates to the
  Fixer registry, which owns the orchestration, audit events, and
  summary rendering.
  """

  @spec run(keyword()) :: Glorbo.CLI.result()
  def run(opts), do: Glorbo.Doctor.Fixer.run(opts)

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
