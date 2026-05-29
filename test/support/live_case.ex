defmodule GlorboWeb.LiveCase do
  @moduledoc """
  Shared case for LiveView integration tests.

  Extends `GlorboWeb.ConnCase` with:

    * `Phoenix.LiveViewTest` imports
    * per-test isolated `~/.glorbo/` tmp root (via
      `Glorbo.Test.TmpGlorboHome`)
    * seeded `acme` company fixture (via `Glorbo.Test.Fixtures.seed_acme/1`)
    * app-env injection (`:glorbo, :glorbo_base` → tmp root) so
      Wave 1 LiveViews read the isolated filesystem instead of the
      real `~/.glorbo/` during tests

  Usage:

      defmodule GlorboWeb.OverviewLiveTest do
        use GlorboWeb.LiveCase, async: false

        test "renders seeded acme", %{conn: conn, base: base, company: company} do
          {:ok, _lv, html} = live(conn, ~p"/companies")
          assert html =~ "acme"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Same endpoint + verified routes as ConnCase.
      @endpoint GlorboWeb.Endpoint

      use GlorboWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Glorbo.Test.Fixtures

      alias Glorbo.Test.TmpGlorboHome
    end
  end

  setup tags do
    # SQL sandbox for Ecto — same as ConnCase.
    Glorbo.DataCase.setup_sandbox(tags)

    base = Glorbo.Test.TmpGlorboHome.setup()
    seeded = Glorbo.Test.Fixtures.seed_acme(base)

    # Dep-inject the tmp root into the app-env so LVs that resolve the
    # filesystem root via `Application.get_env(:glorbo, :glorbo_base, ...)`
    # pick up the per-test tree. Restore after the test to avoid leaking
    # between cases.
    original = Application.get_env(:glorbo, :glorbo_base)
    Application.put_env(:glorbo, :glorbo_base, base)

    # Start a per-test `Glorbo.Company.AuditLog` registered under the
    # global module name so Director write-actions (post_message,
    # set_approval, wake_agent) can be invoked from LiveViews without
    # the caller threading an `:audit` override. Each test gets an
    # isolated base dir, so JSONL writes stay scoped to the tmp root.
    # Tests that boot a per-company supervision tree themselves (via
    # `:integration` + `:inotify` tags) start their own AuditLog and
    # therefore don't use this fallback — this one is only for unit
    # LV tests that call Actions.* without spinning up the full
    # Glorbo.Company.Supervisor tree.
    audit_pid =
      case Process.whereis(Glorbo.Company.AuditLog) do
        nil ->
          {:ok, pid} =
            ExUnit.Callbacks.start_supervised(
              {Glorbo.Company.AuditLog, [name: Glorbo.Company.AuditLog, base: base]}
            )

          pid

        existing ->
          existing
      end

    ExUnit.Callbacks.on_exit(fn ->
      case original do
        nil -> Application.delete_env(:glorbo, :glorbo_base)
        val -> Application.put_env(:glorbo, :glorbo_base, val)
      end
    end)

    _ = audit_pid

    # The browser dashboard is behind the GEP-0053 passphrase gate
    # (DirectorAuth, plug + on_mount). Seed a valid `director_auth` session
    # so both the dead render and the LiveView socket mount pass. The
    # Bearer header is kept for any :api calls a test makes.
    token = Application.get_env(:glorbo, :dashboard_token, "test-token")

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> GlorboWeb.ConnCase.with_director_session()

    {:ok, conn: conn, base: seeded.base, company: seeded.company}
  end
end
