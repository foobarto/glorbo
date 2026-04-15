defmodule Glorbo.Init do
  @moduledoc """
  Public entry for the `glorbo init` command (D-22 via `Glorbo.CLI`).

  Thin delegation wrapper around `Glorbo.Init.Orchestrator.run/1`. Kept
  separate so tests and CLI consumers depend on the public surface rather
  than the orchestrator internals.
  """

  @spec run(keyword()) :: {:ok | :error, map()}
  def run(opts \\ []), do: Glorbo.Init.Orchestrator.run(opts)
end
