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

  @doc """
  True if `conn` already carries a valid `dashboard_token` — via a prior
  bootstrap session cookie, a `?token=` query param, or an
  `Authorization: Bearer` header. Pure predicate, no side effects.

  Used by `GlorboWeb.AuthController` to gate `/setup` during BOOTSTRAP
  (GEP-0053): the token is what authorises setting a passphrase before one
  exists. Returns `false` when no token is configured.
  """
  @spec authorized?(Plug.Conn.t()) :: boolean()
  def authorized?(conn) do
    case Application.get_env(:glorbo, :dashboard_token) do
      token when is_binary(token) and token != "" ->
        authenticated_via_session?(conn, token) or valid_token_supplied?(conn, token)

      _ ->
        false
    end
  end

  @doc """
  Persist the token fingerprint into the session so subsequent requests
  in the BOOTSTRAP setup flow need no `?token=` (keeps the raw token out
  of the rendered `/setup` form). No-op when no token is configured or no
  session is loaded.
  """
  @spec remember(Plug.Conn.t()) :: Plug.Conn.t()
  def remember(conn) do
    case Application.get_env(:glorbo, :dashboard_token) do
      token when is_binary(token) and token != "" -> persist_session(conn, token)
      _ -> conn
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
        conn
        |> persist_session(expected)
        |> maybe_strip_query_token()

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

  # C-120: once the session cookie carries the auth fingerprint, the
  # raw `?token=` no longer needs to sit in the address bar. If it
  # authenticated via the query param AND we persisted a session
  # cookie (browser path), 302-redirect to the same path with `token`
  # stripped from the query string. This keeps the secret out of
  # browser history, bookmarks, and the `Referer` header beyond the
  # single redirect hop. Header-auth (MCP / `:api`) never has a
  # session and never sets `?token=`, so it is untouched.
  #
  # Only redirects on safe (idempotent, body-less) methods — a POST
  # carrying `?token=` must not be turned into a GET redirect that
  # silently drops its body. Such requests still authenticate; they
  # just don't get the cosmetic strip.
  defp maybe_strip_query_token(conn) do
    if session_fetched?(conn) and conn.method in ["GET", "HEAD"] and
         is_binary(query_token(conn)) and safe_request_path?(conn.request_path) do
      conn = fetch_query_params(conn)
      stripped = Map.delete(conn.query_params, "token")

      location =
        case stripped do
          empty when map_size(empty) == 0 -> conn.request_path
          params -> conn.request_path <> "?" <> URI.encode_query(params)
        end

      conn
      |> put_resp_header("location", location)
      |> put_resp_header("referrer-policy", "no-referrer")
      |> send_resp(302, "")
      |> halt()
    else
      conn
    end
  end

  # Gemini deep-dive F4 (open-redirect defense): a request with
  # `request_path = "//evil.com/foo"` would produce
  # `Location: //evil.com/foo` — a PROTOCOL-RELATIVE URL that browsers
  # follow off-origin. Bandit ought to normalise `//` to `/`, but
  # defense-in-depth: only redirect to paths that begin with a
  # single `/` and contain no embedded scheme delimiter, no NUL, no
  # CR/LF (request-smuggling), and no backslash (some clients
  # treat `\\` as `/` for path purposes). Anything weird → leave the
  # `?token=` in the URL (cosmetic regression, security-safe).
  # Single regex match instead of multiple `String.contains?/2` passes;
  # also drops the redundant `starts_with?("/\\")` (already covered by
  # the backslash-anywhere check). (Copilot review on PR #29.)
  @unsafe_redirect_chars ~r/[\\\x00\r\n]|:\/\//

  defp safe_request_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not Regex.match?(@unsafe_redirect_chars, path)
  end

  defp safe_request_path?(_), do: false

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
