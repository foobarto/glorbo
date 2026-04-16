defmodule Glorbo.CLI.Lifecycle.Status do
  @moduledoc """
  TODO(plan-02): Implement `glorbo status` — pidfile check + port probe.
  Exit 0 if running, 3 if not (D-28 / D-09).

  Wave-0 stub.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:status, 0, "status: not implemented in Wave 0 (Plan 02 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo status — report orchestrator run-state.

    USAGE
      glorbo status [--json]

    EXIT CODES
      0 — running
      3 — not running
    """
  end
end
