defmodule Glorbo.Backup do
  @moduledoc """
  TODO(plan-03): Implement `glorbo backup` per D-19/D-20/D-21 —
  :erl_tar.create with [:compressed], WAL-checkpoint (TRUNCATE)
  pre-archive, refuse if pidfile is live.

  Wave-0 stubs — both entry points return the tuple so the dispatch
  switch is reachable.
  """

  @doc """
  Internal programmatic entry. Plan 03 implements; currently returns
  the Wave-0 stub tuple for callers that bypass CLI parsing.
  """
  @spec run(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def run(_opts) do
    {:error, :not_implemented}
  end

  @doc """
  CLI entry. Parses `--output PATH` and `--force-live`, then calls
  `run/1`. Wave-0 returns the stub tuple directly.
  """
  @spec run_cli([String.t()]) :: Glorbo.CLI.result()
  def run_cli(_argv) do
    {:backup, 0, "backup: not implemented in Wave 0 (Plan 03 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo backup — produce a portable archive of ~/.glorbo/.

    USAGE
      glorbo backup [--output PATH] [--force-live]

    DEFAULTS
      Output: ~/glorbo-backup-<UTC-ISO8601>.tar.gz
      Precondition: glorbo must be stopped (pidfile absent) unless
      --force-live is passed.

    INCLUDES
      companies/, config.md, audit/, glorbo.db
    EXCLUDES
      bin/, models/, containers/, runtime/, run/ (re-downloadable/derived)
    """
  end
end
