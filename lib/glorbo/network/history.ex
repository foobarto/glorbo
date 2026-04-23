defmodule Glorbo.Network.History do
  @moduledoc """
  Per-company egress decision cache (GEP-23 §Proxy daemon).

  An ETS-backed cache keyed by `{host, port}` returning a prior
  verdict (`:allow` or `:deny`) plus the reason and an expiry
  timestamp. `Glorbo.Network.Proxy.classify_unlisted/5` consults the
  cache before invoking the (potentially LLM-backed) classifier, so
  a repeat CONNECT to an already-classified host short-circuits and
  doesn't re-invoke the classifier.

  Scope per GEP-23:

    * One table per company — `:"glorbo_network_history_<company>"`.
    * Entries carry `{verdict, reason, expires_at}`; `fetch/3`
      returns `{:hit, verdict, reason}` if still valid, `:miss`
      otherwise (and evicts the stale row as a side effect).
    * TTL is per-entry, configurable per `put/6`. Default 6 hours
      — long enough to make repeat LLM classifier calls cheap,
      short enough that allowlist/classifier changes propagate
      within the Director's typical working-day window.
    * No persistence. The cache is advisory; cold-start rebuilds
      from the classifier.

  The cache is NOT:

    * A replacement for the allowlist. The Proxy still checks the
      allowlist first (config + `network_allow:` frontmatter
      extensions); only fall-through hosts hit the cache.
    * A revocation mechanism. Denying a host permanently needs
      config, not cache invalidation.
  """

  use GenServer

  @default_ttl_ms 6 * 60 * 60 * 1_000

  @type verdict :: :allow | :deny
  @type host_key :: {String.t(), pos_integer()}
  @type entry :: {verdict(), atom(), integer()}

  @type start_opts :: [
          name: GenServer.name(),
          company: String.t(),
          now_fun: (-> integer())
        ]

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec child_spec(start_opts()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc """
  Look up `{host, port}`. Returns `{:hit, verdict, reason}` when the
  cache holds an entry that hasn't expired, `:miss` otherwise.
  """
  @spec fetch(GenServer.name(), String.t(), pos_integer(), keyword()) ::
          {:hit, verdict(), atom()} | :miss
  def fetch(server, host, port, opts \\ []) when is_binary(host) and is_integer(port) do
    GenServer.call(server, {:fetch, host, port, opts})
  end

  @doc """
  Store `{host, port} → {verdict, reason}` with optional `:ttl_ms`
  (default #{@default_ttl_ms} ms). Replaces any prior entry.
  """
  @spec put(GenServer.name(), String.t(), pos_integer(), verdict(), atom(), keyword()) :: :ok
  def put(server, host, port, verdict, reason, opts \\ [])
      when is_binary(host) and is_integer(port) and verdict in [:allow, :deny] and
             is_atom(reason) do
    GenServer.call(server, {:put, host, port, verdict, reason, opts})
  end

  @doc """
  Drop every cached entry for this company. Useful on config reload
  and in tests.
  """
  @spec flush(GenServer.name()) :: :ok
  def flush(server), do: GenServer.call(server, :flush)

  @doc "Total number of live entries (test + introspection aid)."
  @spec size(GenServer.name()) :: non_neg_integer()
  def size(server), do: GenServer.call(server, :size)

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    now_fun = Keyword.get(opts, :now_fun, &System.monotonic_time/0)

    # Unnamed ETS — the GenServer holds the tid in state and no
    # user-input-derived atom is created (GEP-12 T-03-15).
    table = :ets.new(:network_history, [:set, :protected, read_concurrency: true])

    {:ok, %{table: table, now_fun: now_fun, company: company}}
  end

  @impl true
  def handle_call({:fetch, host, port, opts}, _from, state) do
    key = {host, port}
    now = state.now_fun.()

    now_ms =
      Keyword.get_lazy(opts, :now_ms, fn ->
        System.convert_time_unit(now, :native, :millisecond)
      end)

    case :ets.lookup(state.table, key) do
      [{^key, {verdict, reason, expires_at}}] ->
        if now_ms < expires_at do
          {:reply, {:hit, verdict, reason}, state}
        else
          :ets.delete(state.table, key)
          {:reply, :miss, state}
        end

      [] ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:put, host, port, verdict, reason, opts}, _from, state) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    now_ms =
      System.convert_time_unit(state.now_fun.(), :native, :millisecond)

    :ets.insert(state.table, {{host, port}, {verdict, reason, now_ms + ttl_ms}})
    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  def handle_call(:size, _from, state) do
    {:reply, :ets.info(state.table, :size), state}
  end
end
