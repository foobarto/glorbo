defmodule Glorbo.CLI.Lifecycle.BannerTest do
  @moduledoc "GEP-0053 D18 — state-aware startup-banner dashboard URL."
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Lifecycle.Banner

  @base "http://127.0.0.1:4000"

  test "CONFIGURED → bare /login, never the token" do
    url = Banner.dashboard_url(@base, "$pbkdf2-sha512$1$abc$def", "tok-secret")
    assert url == "#{@base}/login"
    refute url =~ "tok-secret"
    refute url =~ "token"
  end

  test "BOOTSTRAP (token present) → /setup?token=" do
    assert Banner.dashboard_url(@base, nil, "tok-secret") == "#{@base}/setup?token=tok-secret"
  end

  test "BOOTSTRAP (no token) → /setup with a config hint, no token leak" do
    url = Banner.dashboard_url(@base, nil, nil)
    assert url =~ "/setup"
    refute url =~ "token=tok"
  end

  test "DEGRADED → /login with a reset hint, never the token" do
    url = Banner.dashboard_url(@base, :malformed, "tok-secret")
    assert url =~ "/login"
    assert url =~ "reset-password"
    refute url =~ "tok-secret"
  end
end
