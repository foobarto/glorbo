defmodule Glorbo.CLI.Console do
  @moduledoc """
  TODO(plan-03): Implement `glorbo console` — iex --remsh into running
  release per D-24. Cookie from `Glorbo.Config.erl_cookie/1`.

  Wave-0 stub.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:console, 0, "console: not implemented in Wave 0 (Plan 03 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo console — open remote shell into the running orchestrator.

    USAGE
      glorbo console

    BEHAVIOR
      Spawns `iex --remsh glorbo@127.0.0.1 --name console@127.0.0.1
      --cookie <from config.md>`. Exits with code 3 if orchestrator is
      not running.
    """
  end
end
