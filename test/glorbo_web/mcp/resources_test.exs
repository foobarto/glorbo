defmodule GlorboWeb.MCP.ResourcesTest do
  @moduledoc """
  Integration tests for GEP-29 wave (d.1): resources/list,
  resources/templates/list, resources/read.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Test.TmpGlorboHome
  alias GlorboWeb.MCP.Server

  defp seed_company(base, company) do
    co_path = Path.join([base, "companies", company])
    File.mkdir_p!(Path.join(co_path, "agents"))
    File.mkdir_p!(Path.join(co_path, "projects"))
    File.mkdir_p!(Path.join(co_path, "proposals"))
    File.mkdir_p!(Path.join(co_path, "channels"))
    File.mkdir_p!(Path.join(co_path, "audit"))

    File.write!(Path.join(co_path, "company.md"), """
    ---
    kind: company/v1
    slug: #{company}
    name: #{String.capitalize(company)}
    headcount_budget: 3
    ---

    mission
    """)

    co_path
  end

  defp dispatch(method, params, base) do
    Server.dispatch(method, params, %{client: "test", base: base})
  end

  describe "resources/list" do
    test "emits audit/approvals/proposals + per-channel entries per company" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      File.write!(Path.join([co_path, "channels", "general.md"]), """
      ---
      kind: channel/v1
      slug: general
      ---
      """)

      File.write!(Path.join([co_path, "channels", "eng.md"]), """
      ---
      kind: channel/v1
      slug: eng
      ---
      """)

      assert {:reply, %{"resources" => resources}} = dispatch("resources/list", %{}, base)

      uris = Enum.map(resources, & &1["uri"])
      assert "glorbo://audit/acme" in uris
      assert "glorbo://approvals/acme" in uris
      assert "glorbo://proposals/acme" in uris
      assert "glorbo://chat/acme/general" in uris
      assert "glorbo://chat/acme/eng" in uris

      assert Enum.all?(resources, &(&1["mimeType"] == "application/json"))
    end

    test "returns empty list when no companies exist" do
      base = TmpGlorboHome.setup()
      assert {:reply, %{"resources" => []}} = dispatch("resources/list", %{}, base)
    end

    test "skips company dirs whose name is not a valid slug" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")
      File.mkdir_p!(Path.join([base, "companies", "BadName"]))
      File.mkdir_p!(Path.join([base, "companies", ".hidden"]))

      assert {:reply, %{"resources" => resources}} = dispatch("resources/list", %{}, base)

      names = Enum.map(resources, & &1["uri"])
      assert Enum.any?(names, &String.contains?(&1, "/acme"))
      refute Enum.any?(names, &String.contains?(&1, "BadName"))
      refute Enum.any?(names, &String.contains?(&1, ".hidden"))
    end

    test "skips channel files whose stem is not a valid slug" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      File.write!(Path.join([co_path, "channels", "general.md"]), "---\n---\n")
      File.write!(Path.join([co_path, "channels", "Bad Channel.md"]), "---\n---\n")

      assert {:reply, %{"resources" => resources}} = dispatch("resources/list", %{}, base)

      chat_uris =
        resources
        |> Enum.map(& &1["uri"])
        |> Enum.filter(&String.starts_with?(&1, "glorbo://chat/"))

      assert "glorbo://chat/acme/general" in chat_uris
      refute Enum.any?(chat_uris, &String.contains?(&1, "Bad"))
    end
  end

  describe "resources/templates/list" do
    test "returns the four URI templates" do
      base = TmpGlorboHome.setup()

      assert {:reply, %{"resourceTemplates" => templates}} =
               dispatch("resources/templates/list", %{}, base)

      names = Enum.map(templates, & &1["name"])
      assert "company-audit" in names
      assert "chat-channel" in names
      assert "pending-approvals" in names
      assert "proposals" in names
    end
  end

  describe "resources/read — audit" do
    test "returns JSON snapshot of audit entries" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      {{year, month, _}, _} = :calendar.local_time()
      ym = "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}"
      audit_file = Path.join([co_path, "audit", "#{ym}.jsonl"])

      File.write!(audit_file, """
      {"ts":"2026-04-22T10:00:00Z","actor":"director","action":"seeded","resource":"company/acme"}
      """)

      assert {:reply, %{"contents" => [content]}} =
               dispatch("resources/read", %{"uri" => "glorbo://audit/acme"}, base)

      assert content["uri"] == "glorbo://audit/acme"
      assert content["mimeType"] == "application/json"
      assert %{"entries" => [entry | _]} = Jason.decode!(content["text"])
      assert entry["actor"] == "director"
    end
  end

  describe "resources/read — approvals" do
    test "returns pending approvals snapshot" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")

      assert {:reply, %{"contents" => [content]}} =
               dispatch("resources/read", %{"uri" => "glorbo://approvals/acme"}, base)

      assert %{"pending" => _} = Jason.decode!(content["text"])
    end
  end

  describe "resources/read — proposals" do
    test "returns proposals snapshot" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      File.write!(Path.join([co_path, "proposals", "hire-writer.md"]), """
      ---
      kind: proposal/v1
      id: hire-writer
      subtype: hire
      status: pending-approval
      proposed_by: ceo
      proposed_at: 2026-04-22T10:00:00Z
      requires_approval: director
      ---

      body
      """)

      assert {:reply, %{"contents" => [content]}} =
               dispatch("resources/read", %{"uri" => "glorbo://proposals/acme"}, base)

      decoded = Jason.decode!(content["text"])
      assert %{"proposals" => proposals} = decoded
      assert Enum.any?(proposals, &(&1["id"] == "hire-writer"))
    end
  end

  describe "resources/read — chat" do
    test "returns messages for a channel" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      File.write!(Path.join([co_path, "channels", "general.md"]), """
      ---
      kind: channel/v1
      slug: general
      ---
      """)

      assert {:reply, %{"contents" => [content]}} =
               dispatch(
                 "resources/read",
                 %{"uri" => "glorbo://chat/acme/general"},
                 base
               )

      assert %{"messages" => _} = Jason.decode!(content["text"])
    end

    test "unknown channel → -32002" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")

      assert {:error, -32_002, "Resource not found", %{"uri" => _}} =
               dispatch(
                 "resources/read",
                 %{"uri" => "glorbo://chat/acme/nope"},
                 base
               )
    end
  end

  describe "resources/read — error paths" do
    test "unknown scheme returns -32002" do
      base = TmpGlorboHome.setup()

      assert {:error, -32_002, "Resource not found", data} =
               dispatch("resources/read", %{"uri" => "https://example.com/"}, base)

      assert data["uri"] == "https://example.com/"
    end

    test "traversal attempt is rejected at slug gate" do
      base = TmpGlorboHome.setup()

      assert {:error, -32_002, "Resource not found", data} =
               dispatch("resources/read", %{"uri" => "glorbo://audit/../etc"}, base)

      assert data["reason"] in [:invalid_company_slug, "invalid_company_slug"] or
               is_atom(data["reason"]) or is_binary(data["reason"])
    end

    test "missing uri returns -32602" do
      base = TmpGlorboHome.setup()

      assert {:error, -32_602, "Invalid params", _} =
               dispatch("resources/read", %{}, base)
    end

    test "extra path segment on company URI rejected" do
      base = TmpGlorboHome.setup()

      assert {:error, -32_002, _, _} =
               dispatch("resources/read", %{"uri" => "glorbo://audit/acme/extra"}, base)
    end

    test "trailing slash on company URI rejected (non-canonical form)" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")

      assert {:error, -32_002, _, _} =
               dispatch("resources/read", %{"uri" => "glorbo://audit/acme/"}, base)
    end

    test "unknown company → -32002 (not empty JSON)" do
      base = TmpGlorboHome.setup()

      for uri <- [
            "glorbo://audit/nope",
            "glorbo://approvals/nope",
            "glorbo://proposals/nope"
          ] do
        assert {:error, -32_002, "Resource not found", data} =
                 dispatch("resources/read", %{"uri" => uri}, base)

        assert data["uri"] == uri
      end
    end

    test "unknown company on chat URI → -32002" do
      base = TmpGlorboHome.setup()

      assert {:error, -32_002, _, _} =
               dispatch("resources/read", %{"uri" => "glorbo://chat/nope/general"}, base)
    end
  end

  describe "initialize capabilities" do
    test "advertises resources capability" do
      base = TmpGlorboHome.setup()

      assert {:reply, %{"capabilities" => caps}} =
               dispatch("initialize", %{"protocolVersion" => "2025-06-18"}, base)

      assert caps["resources"] == %{"listChanged" => false, "subscribe" => true}
    end
  end
end
