defmodule Glorbo.CLI.Lifecycle.Up do
  @moduledoc """
  TODO(plan-02): Implement `glorbo up` — background daemon via
  Burrito re-exec + pidfile + `RELEASE_COOKIE` env export.

  Wave-0 stub — routes `glorbo up <args>` to a "not implemented" tuple
  so the dispatch switch is fully reachable without Plan-02 landing.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:up, 0, "up: not implemented in Wave 0 (Plan 02 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo up — start the orchestrator in the background.

    USAGE
      glorbo up [--skip-doctor]

    SIDE EFFECTS
      Spawns the Glorbo release binary under nohup, writes the OS pid
      to ~/.glorbo/run/glorbo.pid, binds the dashboard at
      http://127.0.0.1:4000.

    SEE ALSO
      glorbo down, glorbo status, glorbo serve
    """
  end
end
