defmodule GlorboWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use GlorboWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint GlorboWeb.Endpoint

      use GlorboWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import GlorboWeb.ConnCase
    end
  end

  setup tags do
    Glorbo.DataCase.setup_sandbox(tags)
    # DashboardToken plug (MCP/CLI surface) requires a bearer token. Inject
    # the test sentinel so :api tests pass that gate.
    token = Application.get_env(:glorbo, :dashboard_token, "test-token")

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> GlorboWeb.ConnCase.with_director_session()

    {:ok, conn: conn}
  end

  @doc """
  Seed a valid `director_auth` passphrase session (GEP-0053) so the conn
  passes `GlorboWeb.DirectorAuth` on the browser dashboard. The marker is
  derived from the CONFIGURED test hash set in `test_helper.exs`; if the
  app-env hash is absent (a test forced BOOTSTRAP), this is a no-op.
  """
  def with_director_session(conn) do
    case Application.get_env(:glorbo, :director_password_hash) do
      hash when is_binary(hash) ->
        Plug.Test.init_test_session(conn, %{
          GlorboWeb.DirectorAuth.session_key() => GlorboWeb.DirectorAuth.session_marker(hash)
        })

      _ ->
        conn
    end
  end
end
