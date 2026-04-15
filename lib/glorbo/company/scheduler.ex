defmodule Glorbo.Company.Scheduler do
  @moduledoc """
  Heartbeats and cron-style wake triggers for company agents.

  *Phase 1 stub.* Phase 3 implements the heartbeat loop and external-event
  wake API used by `Glorbo.Agent.Server`.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec trigger(GenServer.server(), atom()) :: {:error, :not_implemented}
  def trigger(_server, _event), do: {:error, :not_implemented}

  @impl GenServer
  def init(opts) do
    {:ok, %{company: Keyword.fetch!(opts, :company)}}
  end

  @impl GenServer
  def handle_call(_msg, _from, state),
    do: {:reply, {:error, :not_implemented}, state}

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
