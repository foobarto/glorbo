defmodule GlorboWeb.Plugs.DashboardToken do
  @moduledoc """
  Always-enforced bearer-token gate (D-06).

  Behaviour matrix on `Application.get_env(:glorbo, :dashboard_token)`:

    * binary string — request MUST carry a matching token:
        1. `?token=<value>` query param — browser dashboard.
        2. `Authorization: Bearer <value>` header — MCP clients and CLIs.
      Match via `Plug.Crypto.secure_compare/2` (constant-time, defeats T-04-14).
      Mismatch or missing → `401 unauthorized` + `halt/1`.
    * `nil` or `""` — server misconfiguration (Config.load should always
      generate a token). Returns `500 server misconfiguration` and halts.
      This path should never be reached in a correctly booted instance.

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
