defmodule Glorbo.Company.FileWatcher do
  @moduledoc """
  inotify-backed watcher on a company's directory. Emits Elixir messages to the
  `Router` when inbox/outbox files change.

  *Phase 1 stub.* Phase 2 wires `file_system` and Phase 3 emits routing events
  for one-way inbox/outbox flow (CLAUDE.md invariant).
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec watch(atom(), Path.t()) :: {:error, :not_implemented}
  def watch(_company, _path), do: {:error, :not_implemented}

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
