defmodule GlorboWeb.Plugs.DashboardToken do
  @moduledoc """
  Optional bearer-token gate (D-06).

  Behaviour matrix on `Application.get_env(:glorbo, :dashboard_token)`:

    * `nil` (default) — plug is a no-op. Trust relies on loopback bind
      + host-user ownership of `~/.glorbo/`. This is v0.0.1's default
      deployment posture.
    * `""` — treated the same as `nil` (empty string means "not set").
    * binary string — request MUST carry a matching token. Two
      mechanisms are accepted:
        1. `?token=<value>` query param — used by the browser dashboard.
        2. `Authorization: Bearer <value>` header — used by MCP clients
           (threatmodel T11) and other non-browser callers.
      Match is via `Plug.Crypto.secure_compare/2` (constant-time,
      defeats T-04-14 timing attack). Mismatch or missing token
      → `401 unauthorized` + `halt/1`. The response body deliberately
      omits the expected secret (T-04-05 / never leak).

  ## Usage

      pipeline :dashboard do
        plug GlorboWeb.Plugs.DashboardToken
      end
  """
  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Application.get_env(:glorbo, :dashboard_token) do
      nil -> conn
      "" -> conn
      expected when is_binary(expected) -> check_token(conn, expected)
    end
  end

  defp check_token(conn, expected) do
    supplied = supplied_token(conn)

    if supplied && Plug.Crypto.secure_compare(expected, supplied) do
      conn
    else
      conn
      |> send_resp(401, "unauthorized")
      |> halt()
    end
  end

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
