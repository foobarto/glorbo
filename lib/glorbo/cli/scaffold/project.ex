defmodule Glorbo.CLI.Scaffold.Project do
  @moduledoc """
  TODO(plan-02): Implement `glorbo new project <company>/<slug>` per
  D-13 (creates projects/<slug>/README.md, idempotent).

  Wave-0 stub.
  """

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(_argv) do
    {:new_project, 0, "new project: not implemented in Wave 0 (Plan 02 fills)\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo new project — scaffold a new project inside a company.

    USAGE
      glorbo new project <company>/<slug>

    BEHAVIOR
      Creates projects/<slug>/README.md. Lightweight scaffold.
    """
  end
end
