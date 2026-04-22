defmodule GlorboWeb.MCP.ServerTest do
  @moduledoc """
  Unit tests for the MCP JSON-RPC dispatcher (GEP-29 wave a).
  Exercises the Server module in isolation from the HTTP plug — no
  Phoenix, no sockets, just the pure dispatch function.
  """
  use ExUnit.Case, async: true

  alias GlorboWeb.MCP.Server
  alias Glorbo.Test.TmpGlorboHome

  @ctx_empty %{client: "test", base: "/nonexistent"}

  describe "protocol methods" do
    test "initialize returns protocolVersion, capabilities, serverInfo" do
      assert {:reply, result} = Server.dispatch("initialize", %{}, @ctx_empty)
      assert result["protocolVersion"] == "2025-06-18"
      assert result["capabilities"]["tools"]["listChanged"] == false
      assert result["serverInfo"]["name"] == "glorbo"
      assert is_binary(result["serverInfo"]["version"])
    end

    test "ping returns empty result" do
      assert {:reply, %{}} = Server.dispatch("ping", %{}, @ctx_empty)
    end

    test "notifications/initialized yields no reply (notification)" do
      assert :no_reply = Server.dispatch("notifications/initialized", %{}, @ctx_empty)
    end

    test "unknown method returns -32601" do
      assert {:error, -32_601, "Method not found", %{method: "nope"}} =
               Server.dispatch("nope", %{}, @ctx_empty)
    end
  end

  describe "tools/list" do
    test "includes glorbo.list_companies descriptor" do
      assert {:reply, %{"tools" => tools}} = Server.dispatch("tools/list", %{}, @ctx_empty)

      names = Enum.map(tools, & &1["name"])
      assert "glorbo.list_companies" in names

      lc = Enum.find(tools, &(&1["name"] == "glorbo.list_companies"))
      assert is_binary(lc["description"])
      assert lc["inputSchema"]["type"] == "object"
      assert lc["inputSchema"]["additionalProperties"] == false
    end
  end

  describe "tools/call (returns CallToolResult per MCP spec)" do
    test "unknown tool returns JSON-RPC error -32000 (protocol-level)" do
      assert {:error, -32_000, "Tool not found", %{name: "nope.does_not_exist"}} =
               Server.dispatch(
                 "tools/call",
                 %{"name" => "nope.does_not_exist", "arguments" => %{}},
                 @ctx_empty
               )
    end

    test "missing name param returns -32602" do
      assert {:error, -32_602, "Invalid params", _} =
               Server.dispatch("tools/call", %{"arguments" => %{}}, @ctx_empty)
    end

    test "glorbo.list_companies returns CallToolResult with isError=false" do
      base = TmpGlorboHome.setup()
      acme_dir = Path.join([base, "companies", "acme"])
      File.mkdir_p!(acme_dir)

      File.write!(Path.join(acme_dir, "company.md"), """
      ---
      kind: company/v1
      slug: acme
      name: Acme Corp
      headcount_budget: 3
      ---

      mission
      """)

      ctx = %{client: "test", base: base}

      assert {:reply, result} =
               Server.dispatch(
                 "tools/call",
                 %{"name" => "glorbo.list_companies", "arguments" => %{}},
                 ctx
               )

      # Spec-compliant CallToolResult shape.
      assert result["isError"] == false
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert is_binary(text)

      # Typed data lives in structuredContent.
      assert %{
               "companies" => [
                 %{"slug" => "acme", "name" => "Acme Corp", "headcount_budget" => 3}
               ]
             } =
               result["structuredContent"]
    end

    test "glorbo.list_companies returns empty list when companies/ is missing" do
      ctx = %{
        client: "test",
        base: System.tmp_dir!() <> "/glorbo-mcp-missing-#{System.unique_integer([:positive])}"
      }

      assert {:reply, result} =
               Server.dispatch(
                 "tools/call",
                 %{"name" => "glorbo.list_companies", "arguments" => %{}},
                 ctx
               )

      assert result["isError"] == false
      assert %{"companies" => []} = result["structuredContent"]
    end

    test "tool-execution error surfaces as CallToolResult with isError=true (not JSON-RPC error)" do
      # Construct a scenario where the tool returns {:error, reason}:
      # pass a base path that points at a file instead of a directory,
      # making File.ls choke on it.
      tmp = System.tmp_dir!() <> "/glorbo-mcp-badbase-#{System.unique_integer([:positive])}"
      File.mkdir_p!(tmp)
      companies_path = Path.join(tmp, "companies")
      File.write!(companies_path, "not a dir")

      ctx = %{client: "test", base: tmp}

      assert {:reply, result} =
               Server.dispatch(
                 "tools/call",
                 %{"name" => "glorbo.list_companies", "arguments" => %{}},
                 ctx
               )

      assert result["isError"] == true
      assert %{"reason" => reason} = result["structuredContent"]
      assert reason =~ "ls_failed"
    end
  end
end
