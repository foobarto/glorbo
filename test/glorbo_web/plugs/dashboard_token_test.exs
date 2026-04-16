defmodule GlorboWeb.Plugs.DashboardTokenTest do
  @moduledoc """
  DashboardToken plug (D-06) — optional bearer-token gate for LAN
  exposure. Default disposition is pass-through when the `:glorbo,
  :dashboard_token` app env is unset; when set, request MUST carry
  a `?token=<value>` matching via `Plug.Crypto.secure_compare/2`
  (T-04-14 timing-attack defense).
  """
  use ExUnit.Case, async: false
  import Plug.Test

  setup do
    original = Application.get_env(:glorbo, :dashboard_token)
    on_exit(fn -> Application.put_env(:glorbo, :dashboard_token, original) end)
    :ok
  end

  test "passes through when token is nil (default)" do
    Application.put_env(:glorbo, :dashboard_token, nil)
    conn = conn(:get, "/companies")
    result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
    refute result.halted
  end

  test "passes through when token is empty string" do
    Application.put_env(:glorbo, :dashboard_token, "")
    conn = conn(:get, "/companies")
    result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
    refute result.halted
  end

  test "passes when query-param token matches" do
    Application.put_env(:glorbo, :dashboard_token, "secret")
    conn = conn(:get, "/companies?token=secret")
    result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
    refute result.halted
  end

  test "halts with 401 when token missing" do
    Application.put_env(:glorbo, :dashboard_token, "secret")
    conn = conn(:get, "/companies")
    result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
    assert result.status == 401
    assert result.halted
  end

  test "halts with 401 when token mismatches" do
    Application.put_env(:glorbo, :dashboard_token, "secret")
    conn = conn(:get, "/companies?token=wrong")
    result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
    assert result.status == 401
    assert result.halted
  end

  test "error response body never contains the expected token" do
    Application.put_env(:glorbo, :dashboard_token, "super-secret-42")
    conn = conn(:get, "/companies?token=wrong")
    result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
    refute result.resp_body =~ "super-secret-42"
  end
end
