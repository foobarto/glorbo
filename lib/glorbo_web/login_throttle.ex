defmodule GlorboWeb.LoginThrottle do
  @moduledoc """
  Escalating-delay throttle for `/login` passphrase attempts (GEP-0053
  D14/D15).

  A single O(1) global counter — the dashboard is single-user, so there is
  nothing to key on (and on the loopback bind every request is 127.0.0.1
  anyway). `AuthController.login_submit` consults `check/0` **before** the
  PBKDF2 verify, so a throttled attempt burns zero hashing cost; on the
  result it calls `record_failure/0` or `record_success/0`.

  ## Why escalating delay, not lockout (D15)

  A hard "locked for N minutes" state would let any local process (or an
  attacker who reached the port) lock the *sole* director out of their own
  dashboard — a self-inflicted DoS. Instead the delay grows exponentially
  per consecutive failure (capped), and **self-clears** as time passes: the
  operator who knows the passphrase gets in after one short backoff, while
  a brute-forcer is reduced to a handful of guesses per minute (irrelevant
  against a real passphrase + a 210k-round PBKDF2). No attacker-controlled
  value is ever stored, so the table cannot grow.

  Rejection is immediate — `check/0` returns `{:throttled, retry_after_ms}`
  and the caller responds at once. We never `Process.sleep` inside the
  request (that would hold a Bandit acceptor and turn the delay itself into
  a connection-exhaustion vector — D14).

  Params come from `config :glorbo, GlorboWeb.LoginThrottle` —
  `base_ms` (first backoff), `max_ms` (cap), `free_attempts` (failures
  before any delay). Defaults below; test config shrinks them.
  """
  use GenServer

  @default_base_ms 500
  @default_max_ms 5_000
  @default_free_attempts 0
  @max_exponent 16

  # ── client ──────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Permit or reject the next attempt. Call BEFORE the PBKDF2 verify."
  @spec check() :: :ok | {:throttled, non_neg_integer()}
  def check, do: GenServer.call(__MODULE__, :check)

  @doc "Record a failed attempt — grows the backoff."
  @spec record_failure() :: :ok
  def record_failure, do: GenServer.call(__MODULE__, :record_failure)

  @doc "Record a success — clears the backoff."
  @spec record_success() :: :ok
  def record_success, do: GenServer.call(__MODULE__, :record_success)

  @doc "Clear all throttle state (test/recovery helper)."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    cfg = Application.get_env(:glorbo, __MODULE__, [])

    {:ok,
     %{
       base_ms: Keyword.get(cfg, :base_ms, @default_base_ms),
       max_ms: Keyword.get(cfg, :max_ms, @default_max_ms),
       free: Keyword.get(cfg, :free_attempts, @default_free_attempts),
       fails: 0,
       next_allowed_at: now_ms()
     }}
  end

  @impl true
  def handle_call(:check, _from, state) do
    now = now_ms()

    reply =
      if now < state.next_allowed_at, do: {:throttled, state.next_allowed_at - now}, else: :ok

    {:reply, reply, state}
  end

  def handle_call(:record_failure, _from, state) do
    fails = state.fails + 1

    next_allowed_at =
      if fails <= state.free do
        state.next_allowed_at
      else
        exp = min(fails - state.free - 1, @max_exponent)
        delay = min(state.base_ms * Integer.pow(2, exp), state.max_ms)
        now_ms() + delay
      end

    {:reply, :ok, %{state | fails: fails, next_allowed_at: next_allowed_at}}
  end

  def handle_call(:record_success, _from, state) do
    {:reply, :ok, %{state | fails: 0, next_allowed_at: now_ms()}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | fails: 0, next_allowed_at: now_ms()}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
