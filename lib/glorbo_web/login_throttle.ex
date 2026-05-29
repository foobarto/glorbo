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

  @doc """
  Atomically permit-or-reject the next attempt AND pre-record it as a
  pending failure, in one GenServer call. Call BEFORE the PBKDF2 verify.

  This is a single call (not `check` + later `record_failure`) on purpose:
  a burst of N parallel `/login` requests would otherwise all pass an
  independent `check/0` before any of them recorded a failure, and all N
  would run PBKDF2 concurrently — bypassing the pre-hash gate (codex final
  review, High). Because the increment happens inside the same serialized
  GenServer call that returns `:ok`, the FIRST concurrent reserver gets
  `:ok` and bumps the backoff; the rest see it and get `{:throttled, …}`,
  so at most one verify proceeds per backoff window. On a correct
  passphrase the caller then calls `record_success/0` to clear the
  pre-recorded failure.
  """
  @spec reserve() :: :ok | {:throttled, non_neg_integer()}
  def reserve, do: GenServer.call(__MODULE__, :reserve)

  @doc "Clear the backoff after a successful verify."
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
  def handle_call(:reserve, _from, state) do
    now = now_ms()

    if now < state.next_allowed_at do
      # Inside the backoff window — reject WITHOUT bumping (so a flood of
      # rejected attempts can't ratchet the delay to the cap and lock the
      # operator out longer than the legitimate escalation).
      {:reply, {:throttled, state.next_allowed_at - now}, state}
    else
      # Permit this attempt and pre-record it as a pending failure. Concurrent
      # reservers serialize through this call: the next one sees the bumped
      # next_allowed_at and is throttled, so only this attempt reaches PBKDF2.
      fails = state.fails + 1

      next_allowed_at =
        if fails <= state.free do
          state.next_allowed_at
        else
          exp = min(fails - state.free - 1, @max_exponent)
          delay = min(state.base_ms * Integer.pow(2, exp), state.max_ms)
          now + delay
        end

      {:reply, :ok, %{state | fails: fails, next_allowed_at: next_allowed_at}}
    end
  end

  def handle_call(:record_success, _from, state) do
    {:reply, :ok, %{state | fails: 0, next_allowed_at: now_ms()}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | fails: 0, next_allowed_at: now_ms()}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
