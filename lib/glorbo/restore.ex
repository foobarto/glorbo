defmodule Glorbo.Restore do
  @moduledoc """
  TODO(plan-03): Implement `glorbo restore <archive>` per D-22 —
  :erl_tar.extract with traversal guard, then chain:
  migrate → reindex → doctor --fix.

  Wave-0 stubs.
  """

  @doc """
  Internal programmatic entry. Plan 03 implements.
  """
  @spec run(Path.t(), keyword()) :: :ok | {:error, term()}
  def run(_archive, _opts) do
    {:error, :not_implemented}
  end

  @doc """
  CLI entry. Parses `--force` and the positional archive path, then
  calls `run/2`. Wave-0 returns the stub tuple directly.
  """
  @spec run_cli([String.t()]) :: Glorbo.CLI.result()
  def run_cli(_argv) do
    {:restore, 0, "restore: not implemented in Wave 0 (Plan 03 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo restore — extract a Glorbo archive into ~/.glorbo/.

    USAGE
      glorbo restore <archive> [--force]

    BEHAVIOR
      Extracts into ~/.glorbo/. If the directory is non-empty, prints a
      summary of what would be overwritten and exits 2 unless --force is
      passed. Post-extract chain: migrate → reindex → doctor --fix.

    SECURITY
      :erl_tar.extract with traversal guard — rejects archives containing
      entries that would escape ~/.glorbo/ (../etc/passwd, etc.).
    """
  end
end
