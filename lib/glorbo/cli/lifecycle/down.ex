defmodule Glorbo.CLI.Lifecycle.Down do
  @moduledoc """
  TODO(plan-02): Implement `glorbo down` — read pidfile, send SIGTERM,
  wait up to 10s for graceful shutdown, SIGKILL on timeout, remove pidfile.

  Wave-0 stub.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:down, 0, "down: not implemented in Wave 0 (Plan 02 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo down — stop the running orchestrator daemon.

    USAGE
      glorbo down [--force]

    BEHAVIOR
      Reads ~/.glorbo/run/glorbo.pid, sends SIGTERM, waits 10s for
      graceful shutdown, then SIGKILL if still alive. Removes pidfile.
    """
  end
end
