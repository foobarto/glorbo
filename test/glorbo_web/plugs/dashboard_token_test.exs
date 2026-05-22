defmodule GlorboWeb.Plugs.DashboardTokenTest do
  @moduledoc """
  DashboardToken plug (D-06) — always-enforced bearer-token gate.
  A missing or empty `:dashboard_token` config is a server
  misconfiguration (Config.load should always generate one); the plug
  returns 500 rather than silently allowing access.
  """
  use ExUnit.Case, async: false
  import Plug.Test

  setup do
    original = Application.get_env(:glorbo, :dashboard_token)
    on_exit(fn -> Application.put_env(:glorbo, :dashboard_token, original) end)
    :ok
  end

  test "halts with 500 when dashboard_token is nil (server misconfiguration)" do
    Application.put_env(:glorbo, :dashboard_token, nil)
    conn = conn(:get, "/companies")
    result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
    assert result.status == 500
    assert result.halted
    assert result.resp_body == "server misconfiguration"
  end

  test "halts with 500 when dashboard_token is empty string" do
    Application.put_env(:glorbo, :dashboard_token, "")
    conn = conn(:get, "/companies")
    result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
    assert result.status == 500
    assert result.halted
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

  # Threatmodel T11 — MCP clients land on /mcp without a browser
  # session, so they can't pass `?token=`. Accept the token via
  # `Authorization: Bearer <token>` as the non-browser mechanism.
  describe "T11 bearer-header path (for MCP)" do
    test "passes when Authorization: Bearer <token> matches" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      conn =
        conn(:post, "/mcp", "{}")
        |> Plug.Conn.put_req_header("authorization", "Bearer secret")
        |> Plug.Conn.put_req_header("content-type", "application/json")

      result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
      refute result.halted
    end

    test "accepts lowercase `bearer ` scheme too" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      conn =
        conn(:post, "/mcp", "{}")
        |> Plug.Conn.put_req_header("authorization", "bearer secret")

      result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
      refute result.halted
    end

    test "halts when Authorization header bears a different token" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      conn =
        conn(:post, "/mcp", "{}")
        |> Plug.Conn.put_req_header("authorization", "Bearer wrong")

      result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
      assert result.status == 401
      assert result.halted
    end

    test "query-token still works when header is absent" do
      Application.put_env(:glorbo, :dashboard_token, "secret")
      conn = conn(:post, "/mcp?token=secret", "{}")
      result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
      refute result.halted
    end

    test "header token takes precedence over query token" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      conn =
        conn(:post, "/mcp?token=wrong", "{}")
        |> Plug.Conn.put_req_header("authorization", "Bearer secret")

      result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
      refute result.halted
    end
  end

  # The browser dashboard pipes through `:browser` (which fetches the
  # session), so a valid `?token=` is read once and persisted to the
  # session cookie. Subsequent requests carrying the cookie pass without
  # the token in the URL — the operator opens the token URL once and
  # then browses normally. MCP (`:api` pipeline, no session) stays
  # stateless and must send the bearer header every time.
  describe "session cookie (browser)" do
    test "valid query token persists auth to the session" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      result =
        conn(:get, "/companies?token=secret")
        |> Plug.Test.init_test_session(%{})
        |> GlorboWeb.Plugs.DashboardToken.call([])

      # C-120: the first browser hit redirects (302) to strip the
      # token from the URL, but the auth marker is persisted on that
      # redirect response so the follow-up request authenticates by
      # cookie.
      assert result.status == 302
      assert result.halted
      assert Plug.Conn.get_session(result) != %{}, "expected an auth marker in the session"
    end

    test "a request with the established session cookie passes without a token" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      authed =
        conn(:get, "/companies?token=secret")
        |> Plug.Test.init_test_session(%{})
        |> GlorboWeb.Plugs.DashboardToken.call([])

      # Carry the exact session the first request established.
      result =
        conn(:get, "/companies")
        |> Plug.Test.init_test_session(Plug.Conn.get_session(authed))
        |> GlorboWeb.Plugs.DashboardToken.call([])

      refute result.halted
    end

    test "rotated token invalidates an old session cookie" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      authed =
        conn(:get, "/companies?token=secret")
        |> Plug.Test.init_test_session(%{})
        |> GlorboWeb.Plugs.DashboardToken.call([])

      old_session = Plug.Conn.get_session(authed)
      # Operator rotates the token; the old cookie must no longer pass.
      Application.put_env(:glorbo, :dashboard_token, "rotated")

      result =
        conn(:get, "/companies")
        |> Plug.Test.init_test_session(old_session)
        |> GlorboWeb.Plugs.DashboardToken.call([])

      assert result.status == 401
      assert result.halted
    end

    test "raw token is not stored verbatim in the session" do
      Application.put_env(:glorbo, :dashboard_token, "super-secret-42")

      authed =
        conn(:get, "/companies?token=super-secret-42")
        |> Plug.Test.init_test_session(%{})
        |> GlorboWeb.Plugs.DashboardToken.call([])

      refute authed |> Plug.Conn.get_session() |> inspect() =~ "super-secret-42"
    end

    test "no session (MCP api path) still works statelessly via bearer" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      # No init_test_session — mirrors the :api pipeline that never
      # fetches a session. Bearer must still pass and not crash.
      result =
        conn(:post, "/mcp", "{}")
        |> Plug.Conn.put_req_header("authorization", "Bearer secret")
        |> GlorboWeb.Plugs.DashboardToken.call([])

      refute result.halted
    end
  end

  # C-120: once the session cookie carries auth, the raw ?token= must
  # not linger in the URL (browser history / bookmarks / Referer leak
  # window). The first authenticated browser hit 302-redirects to the
  # token-less URL.
  describe "C-120 strip ?token= from URL after cookie set" do
    test "redirects to the token-less path on the first browser hit" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      result =
        conn(:get, "/companies?token=secret")
        |> Plug.Test.init_test_session(%{})
        |> GlorboWeb.Plugs.DashboardToken.call([])

      assert result.status == 302
      assert result.halted
      location = Plug.Conn.get_resp_header(result, "location") |> List.first()
      assert location == "/companies"
      refute location =~ "token"
    end

    test "redirect location preserves other query params, drops only token" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      result =
        conn(:get, "/companies?token=secret&project=web&tab=open")
        |> Plug.Test.init_test_session(%{})
        |> GlorboWeb.Plugs.DashboardToken.call([])

      assert result.status == 302
      location = Plug.Conn.get_resp_header(result, "location") |> List.first()
      refute location =~ "token"
      assert location =~ "project=web"
      assert location =~ "tab=open"
      assert String.starts_with?(location, "/companies?")
    end

    test "sets Referrer-Policy: no-referrer on the redirect" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      result =
        conn(:get, "/companies?token=secret")
        |> Plug.Test.init_test_session(%{})
        |> GlorboWeb.Plugs.DashboardToken.call([])

      assert Plug.Conn.get_resp_header(result, "referrer-policy") == ["no-referrer"]
    end

    test "redirect response does not echo the raw token" do
      Application.put_env(:glorbo, :dashboard_token, "super-secret-42")

      result =
        conn(:get, "/companies?token=super-secret-42")
        |> Plug.Test.init_test_session(%{})
        |> GlorboWeb.Plugs.DashboardToken.call([])

      location = Plug.Conn.get_resp_header(result, "location") |> List.first()
      refute location =~ "super-secret-42"
      refute result.resp_body =~ "super-secret-42"
    end

    test "does NOT redirect a POST carrying ?token= (would drop body)" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      result =
        conn(:post, "/companies?token=secret", "{}")
        |> Plug.Test.init_test_session(%{})
        |> GlorboWeb.Plugs.DashboardToken.call([])

      # Still authenticates, just no cosmetic strip on a non-idempotent
      # method.
      refute result.halted
    end

    test "does NOT redirect the stateless bearer-header (api) path" do
      Application.put_env(:glorbo, :dashboard_token, "secret")

      result =
        conn(:get, "/mcp")
        |> Plug.Conn.put_req_header("authorization", "Bearer secret")
        |> GlorboWeb.Plugs.DashboardToken.call([])

      refute result.halted
    end
  end
end
