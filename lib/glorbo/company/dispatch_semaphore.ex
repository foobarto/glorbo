defmodule Glorbo.Company.DispatchSemaphore do
  @moduledoc """
  Per-company concurrency cap for in-flight agent dispatches (GEP-46 D1).

  One GenServer per company, registered as
  `{:company_child, <co>, :dispatch_semaphore}` per GEP-12. Sits as a
  sibling under `Glorbo.Company.Supervisor`; per-company crash
  isolation per GEP-2.

  ## Contract

    * `acquire/2` — `call/2` (serialised by the GenServer mailbox; this
      is the atomicity boundary for the cap check). Returns
      `{:ok, token()}` when a slot is available, or `:throttled` when
      the company is at the configured cap. The caller is responsible
      for `release/2`-ing on dispatch completion (success OR failure).

    * `release/2` — `cast/2` (no acknowledgement required). Frees the
      slot identified by `token`. Idempotent against double-release
      and against tokens belonging to a different generation of this
      semaphore.

    * `cap/1` — read the configured cap. `:unbounded` when no
      `max_concurrent_dispatches:` was set in `company.md`.

  ## Crash recovery

  When `acquire/2` succeeds, the semaphore monitors the calling
  process. If the holder crashes before calling `release/2`, the
  `{:DOWN, _, ...}` message frees the slot automatically — no stale
  tokens.

  When the semaphore itself crashes, its supervisor restarts it with
  an empty `in_flight` map. The state is intentionally non-durable —
  the worst case is a brief window of permissiveness while in-flight
  dispatches drain naturally; this is acceptable per GEP-46 D7
  (concurrency caps are application-layer, not security-load-bearing).
  """
  use GenServer

  @typedoc "Opaque token returned by `acquire/2` and passed back to `release/2`."
  @type token :: reference()

  @typedoc "Configured cap. `:unbounded` when `max_concurrent_dispatches` was unset."
  @type cap :: :unbounded | pos_integer()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Try to claim a dispatch slot. `ctx` carries the agent slug and the
  invocation_id for observability + audit cross-referencing; it is not
  inspected by the cap check.

  Returns `{:ok, token}` immediately when a slot is free or the cap is
  `:unbounded`. Returns `:throttled` when at the cap; the caller is
  expected to fall back into its own pending-wake queue and retry on
  the next free signal.
  """
  @spec acquire(GenServer.server(), %{required(:agent) => String.t(), optional(any) => any}) ::
          {:ok, token()} | :throttled
  def acquire(server, %{} = ctx) do
    GenServer.call(server, {:acquire, self(), ctx})
  end

  @doc """
  Release a previously-acquired slot. No-op if the token is unknown
  (already-released, or held by a previous generation of this server).
  """
  @spec release(GenServer.server(), token()) :: :ok
  def release(server, token) when is_reference(token) do
    GenServer.cast(server, {:release, token})
  end

  @doc "Read the configured cap (or `:unbounded`)."
  @spec cap(GenServer.server()) :: cap()
  def cap(server) do
    GenServer.call(server, :cap)
  end

  @doc """
  Read the current in-flight count. Mostly for tests + dashboard
  observability.
  """
  @spec in_flight(GenServer.server()) :: non_neg_integer()
  def in_flight(server) do
    GenServer.call(server, :in_flight)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      company: Keyword.fetch!(opts, :company),
      cap: normalize_cap(Keyword.get(opts, :cap, :unbounded)),
      # token (ref) => %{pid, monitor_ref, agent, invocation_id, acquired_at}
      in_flight: %{},
      # pid => MapSet.new() of tokens it holds — used for O(1) cleanup
      # on :DOWN. A single pid can hold multiple tokens (per-agent
      # max_concurrency > 1 with the same Agent.Server caller).
      pids: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, _pid, _ctx}, _from, %{cap: :unbounded} = state) do
    # No bookkeeping when unbounded — return a synthetic token so
    # release/2 stays cheap and idempotent. Don't track pids; the
    # cost would be unbounded growth on a busy company that never
    # cared about the cap.
    {:reply, {:ok, make_ref()}, state}
  end

  def handle_call({:acquire, pid, ctx}, _from, state) do
    if map_size(state.in_flight) >= state.cap do
      {:reply, :throttled, state}
    else
      token = make_ref()
      monitor_ref = Process.monitor(pid)

      holder = %{
        pid: pid,
        monitor_ref: monitor_ref,
        agent: Map.get(ctx, :agent, ""),
        invocation_id: Map.get(ctx, :invocation_id, ""),
        acquired_at: DateTime.utc_now()
      }

      pids = Map.update(state.pids, pid, MapSet.new([token]), &MapSet.put(&1, token))
      in_flight = Map.put(state.in_flight, token, holder)

      {:reply, {:ok, token}, %{state | in_flight: in_flight, pids: pids}}
    end
  end

  def handle_call(:cap, _from, state), do: {:reply, state.cap, state}

  def handle_call(:in_flight, _from, state),
    do: {:reply, map_size(state.in_flight), state}

  @impl true
  def handle_cast({:release, token}, %{cap: :unbounded} = state) do
    # Synthetic tokens from the unbounded path aren't tracked. No-op.
    _ = token
    {:noreply, state}
  end

  def handle_cast({:release, token}, state) do
    {:noreply, drop_token(state, token)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.get(state.pids, pid) do
      nil ->
        {:noreply, state}

      tokens ->
        new_state = Enum.reduce(tokens, state, fn t, acc -> drop_token(acc, t) end)
        {:noreply, new_state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp drop_token(state, token) do
    case Map.pop(state.in_flight, token) do
      {nil, _} ->
        state

      {%{pid: pid, monitor_ref: mref}, in_flight} ->
        Process.demonitor(mref, [:flush])

        pids =
          case Map.get(state.pids, pid) do
            nil ->
              state.pids

            set ->
              new_set = MapSet.delete(set, token)

              if MapSet.size(new_set) == 0 do
                Map.delete(state.pids, pid)
              else
                Map.put(state.pids, pid, new_set)
              end
          end

        %{state | in_flight: in_flight, pids: pids}
    end
  end

  defp normalize_cap(nil), do: :unbounded
  defp normalize_cap(:unbounded), do: :unbounded
  defp normalize_cap(n) when is_integer(n) and n >= 1, do: n
  defp normalize_cap(_), do: :unbounded
end
