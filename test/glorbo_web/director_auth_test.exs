defmodule GlorboWeb.DirectorAuthTest do
  @moduledoc """
  Unit coverage for the GEP-0053 browser-auth gate, exercised in isolation
  (no router) so it stands independent of the dashboard wiring.

  Covers the state machine, the constant-time session marker, the plug
  (dead-render) gate, and the `on_mount` (socket) gate. The connected-socket
  re-validation timer is covered by the LiveView integration test once the
  router is wired (C2b).
  """
  # async: false — these mutate the global :director_password_hash app-env.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias GlorboWeb.DirectorAuth

  setup do
    original = Application.get_env(:glorbo, :director_password_hash)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:glorbo, :director_password_hash)
        val -> Application.put_env(:glorbo, :director_password_hash, val)
      end
    end)

    :ok
  end

  defp bootstrap, do: Application.delete_env(:glorbo, :director_password_hash)
  defp configure(hash), do: Application.put_env(:glorbo, :director_password_hash, hash)
  defp degraded, do: Application.put_env(:glorbo, :director_password_hash, :malformed)
  defp a_hash(secret \\ "director-secret"), do: Pbkdf2.hash_pwd_salt(secret)

  defp gate(session) do
    conn(:get, "/companies")
    |> init_test_session(session)
    |> DirectorAuth.call([])
  end

  describe "auth_state/0" do
    test "absent hash → :bootstrap" do
      bootstrap()
      assert DirectorAuth.auth_state() == :bootstrap
    end

    test "valid hash → {:configured, hash}" do
      hash = a_hash()
      configure(hash)
      assert DirectorAuth.auth_state() == {:configured, hash}
    end

    test ":malformed → :degraded (fail-closed)" do
      degraded()
      assert DirectorAuth.auth_state() == :degraded
    end
  end

  describe "session_marker/1" do
    test "is deterministic for a given hash" do
      hash = a_hash()
      assert DirectorAuth.session_marker(hash) == DirectorAuth.session_marker(hash)
    end

    test "is domain-separated from a plain sha256(hash) (D5)" do
      hash = a_hash()
      plain = :crypto.hash(:sha256, hash) |> Base.url_encode64(padding: false)
      refute DirectorAuth.session_marker(hash) == plain
    end

    test "rotates with the passphrase (different hash → different marker)" do
      refute DirectorAuth.session_marker(a_hash("a")) == DirectorAuth.session_marker(a_hash("b"))
    end
  end

  describe "call/2 — BOOTSTRAP" do
    test "redirects to /setup and halts" do
      bootstrap()
      conn = gate(%{})
      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/setup"]
    end
  end

  describe "call/2 — CONFIGURED" do
    test "valid director_auth session passes through" do
      hash = a_hash()
      configure(hash)
      conn = gate(%{"director_auth" => DirectorAuth.session_marker(hash)})
      refute conn.halted
    end

    test "no session → redirect to /login" do
      configure(a_hash())
      conn = gate(%{})
      assert conn.halted
      assert get_resp_header(conn, "location") == ["/login"]
    end

    test "a GEP-48 dashboard_auth (token) marker alone does NOT grant access (D2)" do
      configure(a_hash())
      # Token fingerprint present, but NO director_auth passphrase marker.
      conn = gate(%{"dashboard_auth" => "any-token-fingerprint"})
      assert conn.halted
      assert get_resp_header(conn, "location") == ["/login"]
    end

    test "a marker for a different hash → redirect to /login (rotation invalidates)" do
      configure(a_hash("current"))
      stale = DirectorAuth.session_marker(a_hash("old"))
      conn = gate(%{"director_auth" => stale})
      assert conn.halted
      assert get_resp_header(conn, "location") == ["/login"]
    end
  end

  describe "call/2 — DEGRADED" do
    test "fails closed with a 503 (never reverts to bootstrap)" do
      degraded()
      conn = gate(%{})
      assert conn.halted
      assert conn.status == 503
      assert conn.resp_body =~ "reset-password"
    end
  end

  describe "on_mount(:ensure_director)" do
    defp mount(session) do
      DirectorAuth.on_mount(:ensure_director, %{}, session, %Phoenix.LiveView.Socket{})
    end

    test "CONFIGURED + valid session → :cont" do
      hash = a_hash()
      configure(hash)

      assert {:cont, %Phoenix.LiveView.Socket{}} =
               mount(%{"director_auth" => DirectorAuth.session_marker(hash)})
    end

    test "CONFIGURED + no marker → :halt (redirect /login)" do
      configure(a_hash())
      assert {:halt, socket} = mount(%{})
      assert socket.redirected
    end

    test "BOOTSTRAP → :halt (redirect /setup)" do
      bootstrap()
      assert {:halt, socket} = mount(%{})
      assert socket.redirected
    end

    test "DEGRADED → :halt" do
      degraded()
      assert {:halt, socket} = mount(%{})
      assert socket.redirected
    end
  end
end
