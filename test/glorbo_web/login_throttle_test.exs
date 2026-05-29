defmodule GlorboWeb.LoginThrottleTest do
  @moduledoc """
  Unit coverage for the GEP-0053 D14/D15 login throttle: escalating delay,
  self-reset on success, no hard lockout. The throttle is a single global
  GenServer started in the supervision tree; each test resets it first.
  """
  use ExUnit.Case, async: false

  alias GlorboWeb.LoginThrottle

  setup do
    LoginThrottle.reset()
    :ok
  end

  test "permits an attempt when idle" do
    assert :ok = LoginThrottle.check()
  end

  test "throttles the next attempt after a failure (D14)" do
    assert :ok = LoginThrottle.record_failure()
    assert {:throttled, ms} = LoginThrottle.check()
    assert ms > 0
  end

  test "a success clears the backoff" do
    :ok = LoginThrottle.record_failure()
    assert {:throttled, _} = LoginThrottle.check()

    :ok = LoginThrottle.record_success()
    assert :ok = LoginThrottle.check()
  end

  test "reset clears the backoff (no hard lockout — self-recovers, D15)" do
    for _ <- 1..10, do: LoginThrottle.record_failure()
    assert {:throttled, _} = LoginThrottle.check()

    LoginThrottle.reset()
    assert :ok = LoginThrottle.check()
  end

  test "the delay escalates with consecutive failures" do
    :ok = LoginThrottle.record_failure()
    {:throttled, after_one} = LoginThrottle.check()

    LoginThrottle.reset()
    for _ <- 1..3, do: LoginThrottle.record_failure()
    {:throttled, after_three} = LoginThrottle.check()

    # base_ms=100 (test): 1 failure ⇒ ~100ms, 3 ⇒ ~400ms. The gap dwarfs
    # the few ms of elapsed time between the two measurements.
    assert after_three > after_one
  end
end
