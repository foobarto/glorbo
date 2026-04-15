defmodule Glorbo.Agent.Server do
  @moduledoc """
  Per-agent lifecycle GenServer. Owns the agent's container exec, wake queue,
  and runtime state.

  *Phase 1 stub.* NOT started by Phase 1's supervision tree — Phase 3 spawns
  instances as dynamic children of `Glorbo.Company.Supervisor`. The stub
  exists so later phases can add it as a child spec without renaming.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec wake(GenServer.server(), atom()) :: {:error, :not_implemented}
  def wake(_server, _trigger), do: {:error, :not_implemented}

  @impl GenServer
  def init(opts) do
    {:ok, %{agent: Keyword.fetch!(opts, :name)}}
  end

  @impl GenServer
  def handle_call(_msg, _from, state),
    do: {:reply, {:error, :not_implemented}, state}

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
