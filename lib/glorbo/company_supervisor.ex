defmodule Glorbo.CompanySupervisor do
  @moduledoc """
  Wrapper around the application-level `DynamicSupervisor` that owns per-company
  supervision trees.

  The actual process is registered by name in `Glorbo.Application.start/2` via
  `{DynamicSupervisor, name: __MODULE__, strategy: :one_for_one}`. This module
  provides a typed helper for Phase 2's `glorbo new company` path.

  *Phase 1 stub.* `start_child/1` returns `{:error, :not_implemented}` until
  Phase 2 wires real company bootstrapping.
  """

  @spec start_child(keyword()) :: {:error, :not_implemented}
  def start_child(_opts), do: {:error, :not_implemented}
end
