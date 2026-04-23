defmodule Glorbo.Network.ProxyTokens do
  @moduledoc """
  Ephemeral per-dispatch credentials for the HTTPS CONNECT proxy
  (GEP-23 §Per-dispatch token). One token per `Agent.Dispatch.execute/3`
  call; registered before bwrap starts, revoked after the sandbox exits.

  ## Why

  Before this module, `Glorbo.Network.Proxy` identified callers purely
  by netns membership: pasta isolates each agent into a private netns,
  the proxy is the only loopback endpoint inside it, so "whoever
  connects is that company." That's a valid boundary for isolation
  but it gives the proxy no way to distinguish between different
  agents of the same company, or between two parallel dispatches of
  the same agent — both of which matter for audit + rate-limiting.

  The token binds every CONNECT to a specific dispatch. Proxy reads
  `Proxy-Authorization: Basic <token>` on the CONNECT line, resolves
  to `{company, agent, dispatch_id}`, and carries that context into
  classifier decisions + audit events.

  ## Lifecycle

      # Before bwrap:
      {:ok, token} = ProxyTokens.register(%{
        company: "acme",
        agent: "engineer",
        dispatch_id: "d-abc123",
        expires_in_ms: 600_000
      })

      # Injected into the agent's HTTPS_PROXY env:
      "http://<token>@127.0.0.1:<port>"

      # Proxy resolves on each CONNECT:
      {:ok, %{company: "acme", agent: "engineer", dispatch_id: "d-abc123"}} =
        ProxyTokens.resolve(token)

      # After dispatch end:
      :ok = ProxyTokens.revoke(token)

  ## Expiry

  Every entry stores a monotonic-millisecond expiry. `resolve/1`
  returns `:error` for expired entries and lazy-deletes them. A
  periodic reaper process (`start_link/1`) additionally sweeps the
  table every minute so memory doesn't grow linearly with dispatch
  count between active lookups.

  ## Storage

  Single public named ETS table (`:glorbo_proxy_tokens`). The
  production tree starts the reaper under `Glorbo.Application` which
  also creates the table. Tests that exercise the registry in
  isolation can call `ensure_started/0`.
  """
  use GenServer

  @table :glorbo_proxy_tokens
  @reap_interval_ms :timer.minutes(1)
  @token_bytes 32

  @type entry :: %{
          required(:company) => String.t(),
          required(:agent) => String.t(),
          required(:dispatch_id) => String.t(),
          required(:expires_at) => integer()
        }

  @type register_opts :: %{
          required(:company) => String.t(),
          required(:agent) => String.t(),
          required(:dispatch_id) => String.t(),
          required(:expires_in_ms) => pos_integer()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Guarantee the ETS table exists. Idempotent. Use from tests that
  exercise the registry without starting the full application tree.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    if :ets.whereis(@table) == :undefined do
      _ = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Allocate + register a token. Returns the url-safe 32-byte string
  the caller should put into `HTTPS_PROXY=http://<token>@...`.
  """
  @spec register(register_opts()) :: {:ok, String.t()}
  def register(%{
        company: company,
        agent: agent,
        dispatch_id: dispatch_id,
        expires_in_ms: ttl_ms
      })
      when is_binary(company) and is_binary(agent) and is_binary(dispatch_id) and
             is_integer(ttl_ms) and ttl_ms > 0 do
    ensure_started()
    token = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
    expires_at = now_ms() + ttl_ms

    :ets.insert(@table, {
      token,
      %{
        company: company,
        agent: agent,
        dispatch_id: dispatch_id,
        expires_at: expires_at
      }
    })

    {:ok, token}
  end

  @doc """
  Resolve a token into its `{company, agent, dispatch_id}` context.
  Returns `:error` when the token is unknown or expired. Expired
  entries are deleted as a side-effect.
  """
  @spec resolve(String.t()) :: {:ok, entry()} | :error
  def resolve(token) when is_binary(token) do
    ensure_started()

    case :ets.lookup(@table, token) do
      [{^token, %{expires_at: exp} = entry}] ->
        if exp >= now_ms() do
          {:ok, entry}
        else
          :ets.delete(@table, token)
          :error
        end

      _ ->
        :error
    end
  end

  def resolve(_), do: :error

  @doc """
  Remove a token. Idempotent — returns `:ok` whether the token was
  present or not. Callers invoke this after dispatch completion.
  """
  @spec revoke(String.t()) :: :ok
  def revoke(token) when is_binary(token) do
    ensure_started()
    _ = :ets.delete(@table, token)
    :ok
  end

  def revoke(_), do: :ok

  @doc false
  @spec size() :: non_neg_integer()
  def size do
    ensure_started()
    :ets.info(@table, :size) || 0
  end

  # ---------------------------------------------------------------------------
  # Reaper GenServer — idle sweep every minute
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_started()
    schedule_reap()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reap, state) do
    reap_expired()
    schedule_reap()
    {:noreply, state}
  end

  defp schedule_reap do
    Process.send_after(self(), :reap, @reap_interval_ms)
  end

  defp reap_expired do
    now = now_ms()

    :ets.foldl(
      fn {token, %{expires_at: exp}}, acc ->
        if exp < now, do: [token | acc], else: acc
      end,
      [],
      @table
    )
    |> Enum.each(&:ets.delete(@table, &1))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
