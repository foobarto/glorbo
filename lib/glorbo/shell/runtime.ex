defmodule Glorbo.Shell.Runtime do
  @moduledoc """
  GEP-37 Phase 1 — minimal shell runtime state holder.

  Phase 1 scope: receive events from `Glorbo.Shell.EventBus` via
  cast, accumulate the most-recent N for inspection, expose a
  state-read API for tests + Phase-2 view callbacks. No rendering,
  no view composition, no input handling — those land in Phase 2
  alongside the `term_ui` app-module integration.

  ## Crash semantics

  Under `Glorbo.Shell.Supervisor`'s `:rest_for_one` strategy,
  Runtime is the SECOND child (downstream of EventBus). A Runtime
  crash restarts only itself; EventBus continues buffering PubSub
  events into its own mailbox until Runtime is up again.
  """
  use GenServer

  @max_events 256

  @typedoc "Public state shape. May grow in later phases."
  @type state :: %{
          events: [term()],
          event_count: non_neg_integer()
        }

  @doc """
  Start the runtime under a supervisor. Accepts:

    * `:name` — registered name (default: `Glorbo.Shell.Runtime`).
      Tests pass `nil` for nameless or a unique atom for parallel
      isolation.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Read the current runtime state. Used by tests + Phase-2 views."
  @spec state(GenServer.server()) :: state()
  def state(server \\ __MODULE__) do
    GenServer.call(server, :state)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{events: [], event_count: 0}}
  end

  @impl GenServer
  def handle_cast({:shell_event, msg}, state) do
    new_events = Enum.take([msg | state.events], @max_events)
    {:noreply, %{state | events: new_events, event_count: state.event_count + 1}}
  end

  @impl GenServer
  def handle_call(:state, _from, state), do: {:reply, state, state}
end
