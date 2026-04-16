defmodule Glorbo.CLI.Scaffold.Agent do
  @moduledoc """
  TODO(plan-02): Implement `glorbo new agent <company>/<slug>` per
  D-12 (Director-only, defaults: role=Agent, provider=claude-code,
  network=api-only, permissions=[], budget=1000 ¢/mo).

  Wave-0 stub.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:new_agent, 0, "new agent: not implemented in Wave 0 (Plan 02 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo new agent — scaffold a new agent inside a company.

    USAGE
      glorbo new agent <company>/<slug> [--role R] [--provider P]

    DEFAULTS
      role=Agent, provider=claude-code, network=api-only,
      permissions=[], budget_monthly_usd=10.00
    """
  end
end
