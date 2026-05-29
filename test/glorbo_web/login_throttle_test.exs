defmodule GlorboWeb.LoginThrottleTest do
  @moduledoc """
  Unit coverage for the GEP-0053 D14/D15 login throttle: atomic
  reserve-or-reject, escalating delay, self-reset on success, no hard
  lockout. The throttle is a single global GenServer started in the
  supervision tree; each test resets it first.
  """
  use ExUnit.Case, async: false

  alias GlorboWeb.LoginThrottle

  setup do
    LoginThrottle.reset()
    :ok
  end

  test "permits the first attempt when idle" do
    assert :ok = LoginThrottle.reserve()
  end

  test "the next attempt within the window is throttled (D14)" do
    assert :ok = LoginThrottle.reserve()
    assert {:throttled, ms} = LoginThrottle.reserve()
    assert ms > 0
  end

  test "a success clears the backoff" do
    assert :ok = LoginThrottle.reserve()
    assert {:throttled, _} = LoginThrottle.reserve()

    :ok = LoginThrottle.record_success()
    assert :ok = LoginThrottle.reserve()
  end

  test "reset clears the backoff (no hard lockout — self-recovers, D15)" do
    assert :ok = LoginThrottle.reserve()
    assert {:throttled, _} = LoginThrottle.reserve()

    LoginThrottle.reset()
    assert :ok = LoginThrottle.reserve()
  end

  test "a parallel burst admits AT MOST ONE — the pre-hash gate isn't bypassed (codex final High)" do
    results =
      1..20
      |> Task.async_stream(fn _ -> LoginThrottle.reserve() end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)

    # All 20 reserves serialize through the GenServer: the first bumps the
    # backoff, the other 19 see it and are throttled. So at most one /login
    # ever reaches the PBKDF2 verify per window.
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:throttled, _}, &1)) == 19
  end

  test "a throttled (rejected) attempt does not ratchet the delay further" do
    assert :ok = LoginThrottle.reserve()
    {:throttled, first} = LoginThrottle.reserve()
    # Hammering while throttled must not extend the lockout (would let an
    # attacker keep the sole operator out — D15).
    {:throttled, second} = LoginThrottle.reserve()
    assert second <= first
  end
end
