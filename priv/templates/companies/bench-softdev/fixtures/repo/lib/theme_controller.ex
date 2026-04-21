defmodule BenchFixture.ThemeController do
  @moduledoc """
  In-process theme state. Bench task bugs-2 extends this to support
  :dark and to round-trip through `current_theme/0`.

  NOTE: intentionally skeletal — the bench task's job is to extend
  this module.
  """

  use Agent

  def start_link(_) do
    Agent.start_link(fn -> :light end, name: __MODULE__)
  end

  def set_theme(:light), do: Agent.update(__MODULE__, fn _ -> :light end)

  def current_theme, do: Agent.get(__MODULE__, & &1)
end
