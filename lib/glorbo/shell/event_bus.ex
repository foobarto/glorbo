defmodule Glorbo.Shell.EventBus do
  @moduledoc """
  GEP-37 Phase 1 — PubSub bridge from Glorbo's per-company topics
  into the shell `Runtime`.

  Subscribes to `company:<co>:{projects,channels,agents,audit,
  approvals}` for each company in the configured roster, plus the
  cross-company `glorbo:companies` topic. Each PubSub broadcast
  arrives in this GenServer's mailbox via `handle_info/2` and is
  forwarded to the runtime as a `{:shell_event, raw_msg}` cast.

  Phase 1 keeps the wire format raw — no per-topic normalization
  yet. Phase 2 introduces the `(state, msg) → state` reducer in
  Runtime and adds topic-tagged shapes the views can pattern-match
  on. Today's contract is simple enough that a Phase-2 caller can
  refactor the forwarding without touching the supervisor tree.

  ## Crash semantics

  Under `Glorbo.Shell.Supervisor`'s `:rest_for_one` strategy, an
  EventBus crash restarts both EventBus and Runtime — Runtime's
  in-memory state is reconstructible from disk + a fresh PubSub
  subscription, so dropping it on EventBus restart is intentional.
  """
  use GenServer

  alias Phoenix.PubSub

  @per_company_topics ~w(projects channels agents audit approvals)
  @global_topics ~w(glorbo:companies)

  @doc """
  Start under a supervisor. Accepts:

    * `:name` — registered name (default: `Glorbo.Shell.EventBus`).
    * `:runtime` — pid or name to forward to (default:
      `Glorbo.Shell.Runtime`).
    * `:pubsub` — PubSub server (default: `Glorbo.PubSub`).
    * `:companies` — list of company slugs to subscribe to. Defaults
      to `[]`; production callers pass the full roster from the
      application supervisor or a refresh-tick.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    runtime = Keyword.get(opts, :runtime, Glorbo.Shell.Runtime)
    pubsub = Keyword.get(opts, :pubsub, Glorbo.PubSub)
    companies = Keyword.get(opts, :companies, [])

    subscribe_all(pubsub, companies)

    {:ok, %{runtime: runtime, pubsub: pubsub, companies: companies, forwarded: 0}}
  end

  @impl GenServer
  def handle_info(msg, state) do
    if alive?(state.runtime) do
      GenServer.cast(state.runtime, {:shell_event, msg})
      {:noreply, %{state | forwarded: state.forwarded + 1}}
    else
      # Runtime is in flight (initial boot ordering) or restarting.
      # Dropping the event is acceptable: Phase-2 views read from
      # Repo + filesystem on mount, so a fresh subscription
      # reconstructs the relevant state.
      {:noreply, state}
    end
  end

  defp subscribe_all(pubsub, companies) do
    Enum.each(companies, fn co ->
      Enum.each(@per_company_topics, fn t ->
        :ok = PubSub.subscribe(pubsub, "company:#{co}:#{t}")
      end)
    end)

    Enum.each(@global_topics, &(:ok = PubSub.subscribe(pubsub, &1)))
  end

  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(name) when is_atom(name), do: Process.whereis(name) != nil
end
