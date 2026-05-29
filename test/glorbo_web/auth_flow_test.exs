defmodule GlorboWeb.AuthFlowTest do
  @moduledoc """
  End-to-end wiring for the GEP-0053 browser-auth gate (C2b): proves the
  `DirectorAuth` plug + `live_session` are actually wired into the router —
  the dead render AND the LiveView route are gated, and the `/login` /
  `/setup` entry points render under the right state.

  Exhaustive auth-controller coverage (CSRF-403, single-shot, throttle,
  return_to) lands with the hardening in C3.
  """
  use GlorboWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    # Tests here flip auth state; snapshot + restore the global hash.
    original = Application.get_env(:glorbo, :director_password_hash)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:glorbo, :director_password_hash)
        val -> Application.put_env(:glorbo, :director_password_hash, val)
      end
    end)

    # A conn with NO director session (the ConnCase default injects one).
    {:ok, anon: Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})}
  end

  describe "CONFIGURED — dead render gate (plug)" do
    test "unauthenticated request to a dashboard route → 302 /login", %{anon: anon} do
      conn = get(anon, "/companies")
      assert redirected_to(conn) == "/login"
    end

    test "authenticated request passes (200 dead render)", %{conn: conn} do
      # `conn` carries a valid director_auth session (ConnCase default).
      conn = get(conn, "/companies")
      assert html_response(conn, 200)
    end
  end

  describe "CONFIGURED — LiveView route gate (live_session/on_mount)" do
    test "unauthenticated live mount → redirect /login", %{anon: anon} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(anon, "/companies")
    end

    test "authenticated live mount succeeds", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/companies")
    end
  end

  describe "live socket re-validation (D1)" do
    test "a passphrase change disconnects an already-open tab on the next re-check", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/companies")

      # Simulate a passphrase reset/change while the tab is open: the live
      # hash no longer matches the marker the socket mounted with.
      Application.put_env(:glorbo, :director_password_hash, Pbkdf2.hash_pwd_salt("rotated"))

      # Fire the periodic re-check the on_mount hook armed (the real timer
      # fires every 60s; we trigger it directly).
      send(view.pid, :director_revalidate)

      assert_redirect(view, "/login")
    end
  end

  describe "/login" do
    test "renders the form with a CSRF token (CONFIGURED)", %{anon: anon} do
      html = anon |> get("/login") |> html_response(200)
      assert html =~ "Passphrase"
      assert html =~ "_csrf_token"
    end

    test "redirects to /setup in BOOTSTRAP", %{anon: anon} do
      Application.delete_env(:glorbo, :director_password_hash)
      assert redirected_to(get(anon, "/login")) == "/setup"
    end
  end

  describe "/setup (BOOTSTRAP)" do
    setup do
      Application.delete_env(:glorbo, :director_password_hash)
      :ok
    end

    test "renders with a valid dashboard_token", %{anon: anon} do
      token = Application.get_env(:glorbo, :dashboard_token, "test-token")
      html = anon |> get("/setup?token=#{token}") |> html_response(200)
      assert html =~ "Set your passphrase"
      assert html =~ "_csrf_token"
    end

    test "401 without a token", %{anon: anon} do
      conn = get(anon, "/setup")
      assert conn.status == 401
    end
  end

  describe "/setup (CONFIGURED)" do
    test "is single-shot — redirects to /login once a passphrase exists", %{conn: conn} do
      # Default test state is CONFIGURED; /setup must not re-plant.
      assert redirected_to(get(conn, "/setup")) == "/login"
    end
  end

  describe "POST /login (CONFIGURED)" do
    test "correct passphrase establishes the director session and redirects to /" do
      # test_helper configures the instance with this passphrase.
      conn =
        submit(build_conn(), "/login", "/login", %{"passphrase" => "test-director-passphrase"})

      assert redirected_to(conn) == "/"

      hash = Application.get_env(:glorbo, :director_password_hash)

      assert get_session(conn, GlorboWeb.DirectorAuth.session_key()) ==
               GlorboWeb.DirectorAuth.session_marker(hash)
    end

    test "wrong passphrase re-renders with a generic error and no session" do
      conn = submit(build_conn(), "/login", "/login", %{"passphrase" => "nope-wrong"})
      assert html_response(conn, 200) =~ "Incorrect passphrase"
      assert get_session(conn, GlorboWeb.DirectorAuth.session_key()) == nil
    end

    test "POST without the CSRF token is rejected (protect_from_forgery, D8)" do
      # Phoenix.ConnTest sets `plug_skip_csrf_protection: true` on test
      # conns (build_conn, conn_test.ex:153), so CSRF is normally bypassed
      # in tests. Un-skip it on a recycled conn (which won't be re-recycled
      # by dispatch) to prove the :browser pipeline actually enforces
      # protect_from_forgery on this POST form — a real browser request
      # without the hidden _csrf_token is rejected (D8).
      conn =
        build_conn()
        |> get("/login")
        |> recycle()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        post(conn, "/login", %{"passphrase" => "test-director-passphrase"})
      end
    end
  end

  describe "POST /setup (BOOTSTRAP)" do
    setup do
      # Isolate the config write to a per-test tmp root so we don't pollute
      # the shared test base; force BOOTSTRAP.
      base = Glorbo.Test.TmpGlorboHome.setup()
      orig_base = Application.get_env(:glorbo, :glorbo_base)
      Application.put_env(:glorbo, :glorbo_base, base)
      Application.delete_env(:glorbo, :director_password_hash)
      on_exit(fn -> Application.put_env(:glorbo, :glorbo_base, orig_base) end)
      {:ok, base: base}
    end

    test "valid passphrase + token writes the hash and flips the node to CONFIGURED", %{
      base: base
    } do
      token = Application.get_env(:glorbo, :dashboard_token, "test-token")

      conn =
        submit(build_conn(), "/setup?token=#{token}", "/setup?token=#{token}", %{
          "passphrase" => "a-strong-passphrase",
          "passphrase_confirmation" => "a-strong-passphrase"
        })

      assert redirected_to(conn) == "/"
      # D3: running node now CONFIGURED.
      assert is_binary(Application.get_env(:glorbo, :director_password_hash))
      # Persisted to disk + verifiable.
      assert {:ok, %{director_password_hash: stored}} = Glorbo.Config.load(base)
      assert Pbkdf2.verify_pass("a-strong-passphrase", stored)
    end

    test "mismatched confirmation re-renders with an error and writes nothing", %{base: base} do
      token = Application.get_env(:glorbo, :dashboard_token, "test-token")

      conn =
        submit(build_conn(), "/setup?token=#{token}", "/setup?token=#{token}", %{
          "passphrase" => "a-strong-passphrase",
          "passphrase_confirmation" => "different"
        })

      assert html_response(conn, 200) =~ "do not match"
      assert {:ok, %{director_password_hash: nil}} = Glorbo.Config.load(base)
    end
  end

  # GET the form (seeds the CSRF token into the session cookie), extract the
  # masked token from the rendered form, then POST it via a recycled conn
  # (which carries the session cookie). Mirrors how a real browser submits.
  defp submit(conn, get_path, post_path, params) do
    conn = get(conn, get_path)
    token = csrf_from(html_response(conn, 200))

    conn
    |> recycle()
    |> post(post_path, Map.put(params, "_csrf_token", token))
  end

  defp csrf_from(html) do
    html
    |> Floki.parse_document!()
    |> Floki.attribute(~s(input[name="_csrf_token"]), "value")
    |> List.first()
  end
end
