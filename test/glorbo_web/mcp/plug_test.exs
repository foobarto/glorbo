defmodule GlorboWeb.MCP.PlugTest do
  @moduledoc """
  HTTP-level tests for `GlorboWeb.MCP.Plug` (GEP-29 wave a).

  Drive the plug via `Plug.Test.conn/3` — no Phoenix pipeline, no
  Endpoint. Verifies the Streamable HTTP wire contract:

    * POST with valid JSON-RPC returns 200 + `application/json`
    * `initialize` stamps `Mcp-Session-Id` header
    * notifications (no id) return 202 with no body
    * GET returns 405 in wave (a) — SSE streaming reserved for later
    * DELETE returns 204
    * disallowed Origin returns 403 (DNS-rebind guard)
    * malformed JSON returns -32700 Parse error
    * non-object envelope returns -32600 Invalid Request
    * batch array returns -32600 Invalid Request
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias GlorboWeb.MCP.Plug, as: McpPlug

  @opts McpPlug.init([])

  defp post_json(body_map) do
    json = Jason.encode!(body_map)

    :post
    |> conn("/mcp", json)
    |> put_req_header("content-type", "application/json")
  end

  defp post_raw(raw_body) do
    :post
    |> conn("/mcp", raw_body)
    |> put_req_header("content-type", "application/json")
  end

  describe "POST — JSON-RPC dispatch" do
    test "initialize returns 200 + application/json + Mcp-Session-Id" do
      conn =
        post_json(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{}
        })
        |> McpPlug.call(@opts)

      assert conn.status == 200

      assert Enum.any?(conn.resp_headers, fn {k, v} ->
               k == "content-type" and String.starts_with?(v, "application/json")
             end)

      assert [sid] = get_resp_header(conn, "mcp-session-id")
      assert byte_size(sid) > 0

      body = Jason.decode!(conn.resp_body)
      assert body["jsonrpc"] == "2.0"
      assert body["id"] == 1
      assert body["result"]["protocolVersion"] == "2025-06-18"
    end

    test "tools/list returns the registered catalog" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
        |> McpPlug.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      names = Enum.map(body["result"]["tools"], & &1["name"])
      assert "glorbo.list_companies" in names
    end

    test "notification (no id) returns 202 Accepted with empty body" do
      conn =
        post_json(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })
        |> McpPlug.call(@opts)

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "any method without id is treated as a notification (202, no body)" do
      # Per JSON-RPC 2.0: notification = request with no id. This is a
      # regression guard: a prior revision only 202'd the specific
      # `notifications/initialized` method, and returned `{"id": null, ...}`
      # bodies for every other no-id request — a spec violation.
      for method <- ["ping", "tools/list", "tools/call", "unknown/whatever"] do
        conn =
          post_json(%{"jsonrpc" => "2.0", "method" => method})
          |> McpPlug.call(@opts)

        assert conn.status == 202, "method #{method}: expected 202 for notification"
        assert conn.resp_body == ""
      end
    end

    test "malformed JSON body returns -32700 Parse error" do
      conn =
        post_raw("{this is not json")
        |> McpPlug.call(@opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == -32_700
      assert body["error"]["message"] == "Parse error"
      assert body["id"] == nil
    end

    test "non-object / missing-method envelope returns -32600 Invalid Request" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 5})
        |> McpPlug.call(@opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == -32_600
      assert body["id"] == 5
    end

    test "batch array body is rejected (2025-06-18 no longer supports batches)" do
      conn =
        post_raw(
          Jason.encode!([
            %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"},
            %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}
          ])
        )
        |> McpPlug.call(@opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == -32_600
      assert body["error"]["data"]["reason"] =~ "batch"
    end

    test "unknown method returns -32601 in the result body (still HTTP 200)" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 99, "method" => "nope/nope"})
        |> McpPlug.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == -32_601
      assert body["id"] == 99
    end
  end

  describe "Origin validation (DNS-rebind guard)" do
    test "allowed origin (localhost) passes" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
        |> put_req_header("origin", "http://localhost:4000")
        |> McpPlug.call(@opts)

      assert conn.status == 200
    end

    test "unknown origin (evil.example.com) returns 403" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
        |> put_req_header("origin", "https://evil.example.com")
        |> McpPlug.call(@opts)

      assert conn.status == 403
    end

    test "prefix-matching attack vector (localhost.evil.tld) returns 403" do
      # Regression guard: using String.starts_with?/2 on the raw
      # Origin header admits `http://localhost.evil.tld`. The fix is
      # URI.parse-based exact-host comparison.
      # Note: `http://localhost:4000.evil.tld` is technically URI-parseable
      # as host=`localhost` port=4000 (Erlang :uri_string drops the trailing
      # `.evil.tld`), so browsers wouldn't emit it and we don't test it —
      # the real attack surface is bare-hostname subdomain tricks.
      for bad <- [
            "http://localhost.evil.tld",
            "http://127.0.0.1.evil.tld",
            "http://mylocalhost"
          ] do
        conn =
          post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
          |> put_req_header("origin", bad)
          |> McpPlug.call(@opts)

        assert conn.status == 403, "expected 403 for spoofed origin #{bad}, got #{conn.status}"
      end
    end

    test "missing origin is allowed (native CLI clients)" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
        |> McpPlug.call(@opts)

      assert conn.status == 200
    end
  end

  describe "MCP-Protocol-Version header (GEP-29 wave e)" do
    test "missing header on non-initialize request → defaults to 2025-03-26 (backwards compat)" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
        |> McpPlug.call(@opts)

      assert conn.status == 200
    end

    test "supported current version (2025-06-18) passes" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> McpPlug.call(@opts)

      assert conn.status == 200
    end

    test "supported prior version (2025-03-26) passes" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
        |> put_req_header("mcp-protocol-version", "2025-03-26")
        |> McpPlug.call(@opts)

      assert conn.status == 200
    end

    test "unsupported version → 400 with reason + supported list" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> McpPlug.call(@opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == -32_600
      assert body["error"]["data"]["reason"] =~ "unsupported"
      assert body["error"]["data"]["sent"] == "1999-01-01"
      assert is_list(body["error"]["data"]["supported"])
      assert "2025-06-18" in body["error"]["data"]["supported"]
    end

    test "initialize is exempt from the header check (version negotiated in body)" do
      # Initialize is the first message and carries the version in
      # `params.protocolVersion`; the header requirement only applies
      # from the next request onward. Even with a bogus header,
      # initialize must succeed — otherwise clients can't bootstrap.
      conn =
        post_json(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-06-18"}
        })
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> McpPlug.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["result"]["protocolVersion"] == "2025-06-18"
    end

    test "initialize echoes a supported older protocolVersion from the client" do
      # MCP lifecycle version negotiation: if the client requests
      # 2025-03-26 and we support it, the response MUST echo that
      # version (not our internal @protocol_version). Otherwise a
      # client on an older spec sees a response it can't handle.
      conn =
        post_json(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-03-26"}
        })
        |> McpPlug.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["result"]["protocolVersion"] == "2025-03-26"
    end

    test "initialize replies with our latest when client requests unsupported version" do
      conn =
        post_json(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "1999-01-01"}
        })
        |> McpPlug.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      # Client can inspect + disconnect if incompatible; we always
      # advertise our current version for unknown requests.
      assert body["result"]["protocolVersion"] == "2025-06-18"
    end

    test "notifications/initialized is exempt from the header check" do
      # Nice-to-have pinned here: `notifications/initialized` is the
      # ambiguous post-initialize boundary. Our plug only exempts
      # `"initialize"` specifically — this regression locks that
      # `notifications/initialized` succeeds whether or not the
      # header is set, because it's a notification (no id → 202)
      # and the header check fires BEFORE the notification branch.
      # Missing header defaults to 2025-03-26 (supported) so this
      # passes.
      conn =
        post_json(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
        |> McpPlug.call(@opts)

      assert conn.status == 202
    end
  end

  describe "method routing" do
    test "GET without session header returns 400 Invalid Request" do
      # MCP 2025-06-18 §Session management: clients MUST carry
      # Mcp-Session-Id on subsequent requests once initialize issued one.
      conn =
        :get
        |> conn("/mcp")
        |> McpPlug.call(@opts)

      assert conn.status == 400

      assert %{"error" => %{"code" => -32_600, "message" => "Invalid Request"}} =
               Jason.decode!(conn.resp_body)
    end

    test "GET with unknown session header returns 404 Unknown session" do
      conn =
        :get
        |> conn("/mcp")
        |> put_req_header("mcp-session-id", "nosuch-session")
        |> McpPlug.call(@opts)

      assert conn.status == 404

      assert %{"error" => %{"code" => -32_002, "message" => "Unknown session"}} =
               Jason.decode!(conn.resp_body)
    end

    test "DELETE returns 204" do
      conn =
        :delete
        |> conn("/mcp")
        |> McpPlug.call(@opts)

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "PUT returns 405 with Allow header" do
      conn =
        :put
        |> conn("/mcp")
        |> McpPlug.call(@opts)

      assert conn.status == 405
      assert ["POST, GET, DELETE"] = get_resp_header(conn, "allow")
    end
  end

  describe "Mcp-Client-Name header" do
    test "client name normalizes into context (actor prefix)" do
      # We can't directly observe the context from the plug, but the
      # resolved client can be inferred: initialize succeeds whether
      # or not the header is set, and the name parser is unit-covered
      # elsewhere. This is a smoke-test that weird values don't crash.
      for client <- ["Claude Code", "cursor/1.2", "", "!!!"] do
        conn =
          post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
          |> put_req_header("mcp-client-name", client)
          |> McpPlug.call(@opts)

        assert conn.status == 200
      end
    end
  end

  describe "session lifecycle (GEP-29 wave d.2)" do
    test "initialize starts a Session GenServer keyed to Mcp-Session-Id" do
      conn =
        post_json(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-06-18"}
        })
        |> McpPlug.call(@opts)

      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert GlorboWeb.MCP.Session.exists?(session_id)

      # Clean up so the DynamicSupervisor doesn't leak across tests.
      GlorboWeb.MCP.Session.terminate_session(session_id)
    end

    test "DELETE with session header tears down the session" do
      {:ok, session_id} =
        GlorboWeb.MCP.Session.start_session(%{client: "test", base: "/tmp"})

      conn =
        :delete
        |> conn("/mcp")
        |> put_req_header("mcp-session-id", session_id)
        |> McpPlug.call(@opts)

      assert conn.status == 204
      refute GlorboWeb.MCP.Session.exists?(session_id)
    end

    test "resources/subscribe over HTTP records the subscription on the session" do
      {:ok, session_id} =
        GlorboWeb.MCP.Session.start_session(%{client: "test", base: "/tmp"})

      conn =
        post_json(%{
          "jsonrpc" => "2.0",
          "id" => 10,
          "method" => "resources/subscribe",
          "params" => %{"uri" => "glorbo://audit/acme"}
        })
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> McpPlug.call(@opts)

      assert conn.status == 200
      assert %{"result" => %{}} = Jason.decode!(conn.resp_body)
      assert ["glorbo://audit/acme"] = GlorboWeb.MCP.Session.subscribed_uris(session_id)

      GlorboWeb.MCP.Session.terminate_session(session_id)
    end

    test "POST with unknown session header returns 404 -32002" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 11, "method" => "ping"})
        |> put_req_header("mcp-session-id", "nosuch-session")
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> McpPlug.call(@opts)

      assert conn.status == 404

      assert %{"error" => %{"code" => -32_002, "message" => "Unknown session"}} =
               Jason.decode!(conn.resp_body)
    end

    test "resources/subscribe without a session returns -32002 at JSON-RPC layer" do
      conn =
        post_json(%{
          "jsonrpc" => "2.0",
          "id" => 12,
          "method" => "resources/subscribe",
          "params" => %{"uri" => "glorbo://audit/acme"}
        })
        |> McpPlug.call(@opts)

      assert conn.status == 200

      assert %{"error" => %{"code" => -32_002, "message" => "No active session"}} =
               Jason.decode!(conn.resp_body)
    end

    test "initialize returns 503 when the session supervisor is at capacity" do
      active = DynamicSupervisor.count_children(GlorboWeb.MCP.SessionSupervisor).active

      session_ids =
        for _ <- 1..max(256 - active, 0) do
          {:ok, session_id} =
            GlorboWeb.MCP.Session.start_session(%{
              client: "test",
              base: "/tmp",
              idle_timeout_ms: 5_000
            })

          session_id
        end

      on_exit(fn ->
        Enum.each(session_ids, &GlorboWeb.MCP.Session.terminate_session/1)
      end)

      conn =
        post_json(%{
          "jsonrpc" => "2.0",
          "id" => 99,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-06-18"}
        })
        |> McpPlug.call(@opts)

      assert conn.status == 503

      assert %{
               "id" => 99,
               "error" => %{
                 "code" => -32_000,
                 "message" => "Server error",
                 "data" => %{"reason" => "session_start_failed"}
               }
             } = Jason.decode!(conn.resp_body)
    end
  end
end
