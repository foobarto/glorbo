defmodule GlorboWeb.Plugs.DashboardToken do
  @moduledoc """
  Always-enforced bearer-token gate (D-06).

  Behaviour matrix on `Application.get_env(:glorbo, :dashboard_token)`:

    * binary string — the request is authorised when ANY of:
        1. a valid session cookie established by a prior token (browser
           dashboard — see below);
        2. `?token=<value>` query param — browser dashboard, first hit;
        3. `Authorization: Bearer <value>` header — MCP clients and CLIs.
      Token matches are constant-time via `Plug.Crypto.secure_compare/2`
      (defeats T-04-14). None present / mismatch → `401` + `halt/1`.
    * `nil` or `""` — server misconfiguration (Config.load should always
      generate a token). Returns `500 server misconfiguration` and halts.
      This path should never be reached in a correctly booted instance.

  ## Session cookie (browser ergonomics)

  The browser dashboard pipes through `:browser`, which fetches the
  session. When a request arrives with a valid `?token=`, the plug
  records an auth marker in the (signed) session so subsequent requests
  pass via the cookie alone — the operator opens the token URL once and
  then navigates / refreshes / deep-links normally, without `?token=`
  on every request. The marker is a `sha256` fingerprint of the token,
  not the token itself, so rotating `dashboard_token:` invalidates every
  outstanding cookie and the raw secret never lands in a cookie.

  MCP (`:api` pipeline) never fetches a session, so it stays stateless:
  the bearer header must accompany every request, and the plug writes no
  cookie there.

  ## Usage

      pipeline :dashboard do
        plug GlorboWeb.Plugs.DashboardToken
      end
  """
  import Plug.Conn

  @behaviour Plug

  # Session key holding the token fingerprint once a browser has
  # authenticated with a valid `?token=`.
  @session_key "dashboard_auth"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Application.get_env(:glorbo, :dashboard_token) do
      token when is_binary(token) and token != "" ->
        check_token(conn, token)

      other ->
        require Logger

        Logger.error(
          "dashboard_token not configured (got #{inspect(other)}); " <>
            "refusing all requests — fix ~/.glorbo/config.md"
        )

        conn
        |> send_resp(500, "server misconfiguration")
        |> halt()
    end
  end

  defp check_token(conn, expected) do
    cond do
      # 1. Browser already authenticated this session.
      authenticated_via_session?(conn, expected) ->
        conn

      # 2. Valid token supplied — pass, and (if a session is available)
      #    persist the fingerprint so later requests need no `?token=`.
      valid_token_supplied?(conn, expected) ->
        persist_session(conn, expected)

      true ->
        conn
        |> send_resp(401, "unauthorized")
        |> halt()
    end
  end

  defp valid_token_supplied?(conn, expected) do
    supplied = supplied_token(conn)
    is_binary(supplied) and Plug.Crypto.secure_compare(expected, supplied)
  end

  defp authenticated_via_session?(conn, expected) do
    session_fetched?(conn) and
      case get_session(conn, @session_key) do
        marker when is_binary(marker) ->
          Plug.Crypto.secure_compare(fingerprint(expected), marker)

        _ ->
          false
      end
  end

  defp persist_session(conn, expected) do
    if session_fetched?(conn) do
      put_session(conn, @session_key, fingerprint(expected))
    else
      # MCP / :api path — no session to write; bearer is stateless.
      conn
    end
  end

  # The session is only loaded by the `:browser` pipeline's
  # `fetch_session`; on the `:api` pipeline `get_session/put_session`
  # would raise, so guard on the loaded session map (`:plug_session` is
  # set by both `fetch_session` and `Plug.Test.init_test_session`).
  defp session_fetched?(conn), do: is_map(Map.get(conn.private, :plug_session))

  defp fingerprint(token), do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

  defp supplied_token(conn) do
    cond do
      bearer = bearer_token(conn) -> bearer
      query = query_token(conn) -> query
      true -> nil
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> token
      ["bearer " <> token] when token != "" -> token
      _ -> nil
    end
  end

  defp query_token(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["token"] do
      val when is_binary(val) and val != "" -> val
      _ -> nil
    end
  end
end
