defmodule Glorbo.CLI.Lifecycle.Serve do
  @moduledoc """
  TODO(plan-02): Implement `glorbo serve` — start supervision tree +
  Phoenix endpoint, block until SIGINT (D-06).

  Wave-0 stub.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:serve, 0, "serve: not implemented in Wave 0 (Plan 02 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo serve — run the orchestrator in the foreground.

    USAGE
      glorbo serve

    BEHAVIOR
      Starts the full supervision tree + Phoenix LiveView dashboard at
      http://127.0.0.1:4000. Blocks until SIGINT/SIGTERM.
    """
  end
end
