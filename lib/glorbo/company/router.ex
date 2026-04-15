defmodule Glorbo.Company.Router do
  @moduledoc """
  Routes outbox messages to recipient inboxes and channels. The Router is the
  application-layer permission enforcement call-site (CLAUDE.md: kernel is the
  policy engine, but Elixir checks first).

  *Phase 1 stub.* `route/2` returns `{:error, :not_implemented}`. Phase 3 fills
  in permission-checked routing.

  Note: there is NO public `write_inbox/*` function — all inbox writes go
  through `route/2` per CLAUDE.md's one-way-flow invariant.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec route(GenServer.server(), map()) :: {:error, :not_implemented}
  def route(_server, _message), do: {:error, :not_implemented}

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
