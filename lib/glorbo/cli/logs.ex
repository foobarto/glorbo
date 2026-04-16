defmodule Glorbo.CLI.Logs do
  @moduledoc """
  TODO(plan-02): Implement `glorbo logs <co> [agent]` per D-14/D-15
  (--lines N, --follow via inotify with poll fallback).

  Wave-0 stub.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:logs, 0, "logs: not implemented in Wave 0 (Plan 02 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo logs — tail company or agent logs.

    USAGE
      glorbo logs <company>              # tails companies/<co>/audit/YYYY-MM.jsonl
      glorbo logs <company> <agent>      # tails agents/<ag>/stdout.log

    FLAGS
      --lines N    Initial backfill (default 50)
      --follow     Tail forever (inotify with poll fallback)
    """
  end
end
