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

  describe "method routing" do
    test "GET returns 405 (SSE not offered in wave a)" do
      conn =
        :get
        |> conn("/mcp")
        |> McpPlug.call(@opts)

      assert conn.status == 405
      assert ["POST, DELETE"] = get_resp_header(conn, "allow")
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
end
