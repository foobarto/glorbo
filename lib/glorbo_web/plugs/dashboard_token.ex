defmodule GlorboWeb.Plugs.DashboardToken do
  @moduledoc """
  Optional bearer-token gate (D-06).

  Behaviour matrix on `Application.get_env(:glorbo, :dashboard_token)`:

    * `nil` (default) — plug is a no-op. Trust relies on loopback bind
      + host-user ownership of `~/.glorbo/`. This is v0.0.1's default
      deployment posture.
    * `""` — treated the same as `nil` (empty string means "not set").
    * binary string — request MUST carry `?token=<value>` matching the
      configured secret via `Plug.Crypto.secure_compare/2` (constant-
      time, defeats T-04-14 timing attack). Mismatch or missing token
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
    conn = fetch_query_params(conn)
    supplied = conn.query_params["token"] || ""

    if Plug.Crypto.secure_compare(expected, supplied) do
      conn
    else
      conn
      |> send_resp(401, "unauthorized")
      |> halt()
    end
  end
end
