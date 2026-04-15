defmodule Glorbo.Company.BudgetTracker do
  @moduledoc """
  Per-agent token and USD spend accounting. Alerts and hard-stops are enforced
  here; Python workers report usage after each LLM call.

  *Phase 1 stub.* Phase 3 wires persistence against the SQLite index and
  exposes queries for the dashboard.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec record_usage(GenServer.server(), %{tokens: integer(), cost_usd: float()}) ::
          {:error, :not_implemented}
  def record_usage(_server, _usage), do: {:error, :not_implemented}

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
