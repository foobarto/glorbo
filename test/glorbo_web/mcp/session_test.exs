defmodule GlorboWeb.MCP.SessionTest do
  @moduledoc """
  GEP-29 wave (d.2) — per-session state, resources/subscribe +
  resources/unsubscribe, and PubSub → SSE notification push.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Test.TmpGlorboHome
  alias GlorboWeb.MCP.Server
  alias GlorboWeb.MCP.Session

  defp start_session(base) do
    {:ok, session_id} = Session.start_session(%{client: "test", base: base})

    on_exit(fn -> Session.terminate_session(session_id) end)

    session_id
  end

  defp dispatch(method, params, base, session_id) do
    Server.dispatch(method, params, %{client: "test", base: base, session_id: session_id})
  end

  describe "start_session + exists?" do
    test "issues a session id and registers it" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)

      assert Session.exists?(session_id)
      refute Session.exists?("no-such-session")
    end
  end

  describe "resources/subscribe via Server.dispatch" do
    test "records subscription on the session GenServer" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)

      assert {:reply, %{}} =
               dispatch(
                 "resources/subscribe",
                 %{"uri" => "glorbo://audit/acme"},
                 base,
                 session_id
               )

      assert ["glorbo://audit/acme"] = Session.subscribed_uris(session_id)
    end

    test "tracks multiple URIs of different families" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)

      for uri <- [
            "glorbo://audit/acme",
            "glorbo://proposals/acme",
            "glorbo://approvals/acme",
            "glorbo://chat/acme/general"
          ] do
        assert {:reply, %{}} = dispatch("resources/subscribe", %{"uri" => uri}, base, session_id)
      end

      uris = Session.subscribed_uris(session_id)
      assert length(uris) == 4
      assert "glorbo://audit/acme" in uris
      assert "glorbo://chat/acme/general" in uris
    end

    test "rejects an unsupported URI with -32602" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)

      assert {:error, -32_602, "Invalid params", _} =
               dispatch(
                 "resources/subscribe",
                 %{"uri" => "https://example.com/"},
                 base,
                 session_id
               )
    end

    test "rejects subscription with no active session" do
      base = TmpGlorboHome.setup()

      assert {:error, -32_002, "No active session", _} =
               Server.dispatch(
                 "resources/subscribe",
                 %{"uri" => "glorbo://audit/acme"},
                 %{client: "test", base: base}
               )
    end

    test "unsubscribe removes the URI" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)

      assert {:reply, %{}} =
               dispatch(
                 "resources/subscribe",
                 %{"uri" => "glorbo://audit/acme"},
                 base,
                 session_id
               )

      assert {:reply, %{}} =
               dispatch(
                 "resources/unsubscribe",
                 %{"uri" => "glorbo://audit/acme"},
                 base,
                 session_id
               )

      assert [] = Session.subscribed_uris(session_id)
    end

    test "re-subscribing the same URI is a no-op (no pubsub ref leak)" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)

      for _ <- 1..3 do
        assert {:reply, %{}} =
                 dispatch(
                   "resources/subscribe",
                   %{"uri" => "glorbo://audit/acme"},
                   base,
                   session_id
                 )
      end

      # One subscribe + one unsubscribe should drop the topic fully
      # (no stale refcount holding it open).
      :ok = Session.unsubscribe(session_id, "glorbo://audit/acme")
      :ok = Session.attach_sse(session_id, self())

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:audit",
        {:audit_append, %{"actor" => "director"}}
      )

      refute_receive {:mcp_notification, _, _}, 200
    end

    test "unsubscribe is idempotent for URIs that were never subscribed" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)

      assert {:reply, %{}} =
               dispatch(
                 "resources/unsubscribe",
                 %{"uri" => "glorbo://audit/acme"},
                 base,
                 session_id
               )

      assert [] = Session.subscribed_uris(session_id)
    end
  end

  describe "pubsub → sse notification push" do
    test "audit broadcast on a subscribed company pushes a notification" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)
      :ok = Session.attach_sse(session_id, self())

      assert :ok = Session.subscribe(session_id, "glorbo://audit/acme")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:audit",
        {:audit_append, %{"actor" => "director", "action" => "seeded"}}
      )

      assert_receive {:mcp_notification, "notifications/resources/updated",
                      %{"uri" => "glorbo://audit/acme"}},
                     1_000
    end

    test "chat broadcast on a subscribed channel pushes a notification" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)
      :ok = Session.attach_sse(session_id, self())

      assert :ok = Session.subscribe(session_id, "glorbo://chat/acme/general")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:channels:general",
        {:file_event, "channels/general.md", [:modified]}
      )

      assert_receive {:mcp_notification, "notifications/resources/updated",
                      %{"uri" => "glorbo://chat/acme/general"}},
                     1_000
    end

    test "audit event does NOT notify unrelated family subscriptions" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)
      :ok = Session.attach_sse(session_id, self())

      :ok = Session.subscribe(session_id, "glorbo://audit/acme")
      :ok = Session.subscribe(session_id, "glorbo://chat/acme/general")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:audit",
        {:audit_append, %{"actor" => "director"}}
      )

      # Only the audit URI should be notified — not the chat one.
      assert_receive {:mcp_notification, _, %{"uri" => "glorbo://audit/acme"}}, 500
      refute_receive {:mcp_notification, _, %{"uri" => "glorbo://chat/acme/general"}}, 200
    end

    test "file_event on channels only notifies matching channel URI" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)
      :ok = Session.attach_sse(session_id, self())

      :ok = Session.subscribe(session_id, "glorbo://chat/acme/general")
      :ok = Session.subscribe(session_id, "glorbo://chat/acme/eng")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:channels:general",
        {:file_event, "channels/general.md", [:modified]}
      )

      assert_receive {:mcp_notification, _, %{"uri" => "glorbo://chat/acme/general"}}, 500
      refute_receive {:mcp_notification, _, %{"uri" => "glorbo://chat/acme/eng"}}, 200
    end

    test "no notification when the subscription is elsewhere" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)
      :ok = Session.attach_sse(session_id, self())

      assert :ok = Session.subscribe(session_id, "glorbo://audit/acme")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:widgetco:audit",
        {:audit_append, %{"actor" => "director"}}
      )

      refute_receive {:mcp_notification, _, _}, 200
    end

    test "unsubscribe stops future notifications" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)
      :ok = Session.attach_sse(session_id, self())

      :ok = Session.subscribe(session_id, "glorbo://audit/acme")
      :ok = Session.unsubscribe(session_id, "glorbo://audit/acme")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:audit",
        {:audit_append, %{"actor" => "director"}}
      )

      refute_receive {:mcp_notification, _, _}, 200
    end

    test "no push when no SSE pid is attached" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)

      :ok = Session.subscribe(session_id, "glorbo://audit/acme")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:audit",
        {:audit_append, %{"actor" => "director"}}
      )

      refute_receive {:mcp_notification, _, _}, 200
    end
  end

  describe "sse attach/detach" do
    test "attach replaces a previously-attached pid" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)

      first_pid = spawn(fn -> :timer.sleep(5_000) end)
      :ok = Session.attach_sse(session_id, first_pid)
      :ok = Session.attach_sse(session_id, self())
      :ok = Session.subscribe(session_id, "glorbo://audit/acme")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:audit",
        {:audit_append, %{"actor" => "director"}}
      )

      assert_receive {:mcp_notification, _, _}, 500

      Process.exit(first_pid, :normal)
    end

    test "attached pid exit auto-detaches without a manual call" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)

      fake_sse = spawn(fn -> receive do: (_ -> :ok) end)
      :ok = Session.attach_sse(session_id, fake_sse)
      Process.exit(fake_sse, :normal)

      # Give the DOWN message time to land.
      :timer.sleep(50)

      # Subsequent attach should succeed — if the old monitor ref was
      # still in state, the Session would still be tracking a dead pid.
      :ok = Session.attach_sse(session_id, self())

      :ok = Session.subscribe(session_id, "glorbo://audit/acme")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:audit",
        {:audit_append, %{"actor" => "director"}}
      )

      assert_receive {:mcp_notification, _, _}, 500
    end
  end

  describe "terminate_session" do
    test "unsubscribes PubSub topics so later broadcasts don't reach the dead pid" do
      base = TmpGlorboHome.setup()
      session_id = start_session(base)
      :ok = Session.attach_sse(session_id, self())
      :ok = Session.subscribe(session_id, "glorbo://audit/acme")

      :ok = Session.terminate_session(session_id)
      refute Session.exists?(session_id)

      # Broadcast after termination — no stray messages.
      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:audit",
        {:audit_append, %{"actor" => "director"}}
      )

      refute_receive {:mcp_notification, _, _}, 200
    end
  end
end
