defmodule Glorbo.CLI.Lifecycle.Run do
  @moduledoc """
  TODO(plan-02): Implement `glorbo run <company>/<agent> <task>` —
  one-shot dispatch without dashboard (D-10).

  Wave-0 stub.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:run, 0, "run: not implemented in Wave 0 (Plan 02 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo run — one-shot agent dispatch.

    USAGE
      glorbo run <company>/<agent> <task-file>

    BEHAVIOR
      Starts the supervision tree, dispatches the agent against the task,
      waits for completion, prints result, exits.
    """
  end
end
