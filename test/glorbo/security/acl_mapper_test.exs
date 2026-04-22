defmodule Glorbo.Security.ACLMapperTest do
  use ExUnit.Case, async: true

  alias Glorbo.Security.ACLMapper

  describe "parse_permission/1" do
    test "parses valid three-part permission" do
      assert {:ok, {"projects", "write", "website-redesign"}} =
               ACLMapper.parse_permission("projects:write:website-redesign")
    end

    test "returns error for malformed input" do
      assert {:error, :malformed} = ACLMapper.parse_permission("garbage")
    end

    test "returns error for unknown resource" do
      assert {:error, :unknown_resource} = ACLMapper.parse_permission("unknown:write:foo")
    end

    test "parses agents:create:* (verb in whitelist)" do
      assert {:ok, {"agents", "create", "*"}} =
               ACLMapper.parse_permission("agents:create:*")
    end

    test "returns error for traversal-like scope" do
      assert {:error, :invalid_scope} = ACLMapper.parse_permission("projects:write:../audit")
      assert {:error, :invalid_scope} = ACLMapper.parse_permission("chat:read:..")
    end

    test "parses two-part input as malformed" do
      assert {:error, :malformed} = ACLMapper.parse_permission("projects:write")
    end

    test "parses empty string as malformed" do
      assert {:error, :malformed} = ACLMapper.parse_permission("")
    end
  end

  describe "check_action/2" do
    test "returns :ok when permission matches" do
      perms = [{"projects", "write", "website-redesign"}]
      assert :ok = ACLMapper.check_action(perms, {"projects", "write", "website-redesign"})
    end

    test "returns error when scope does not match" do
      perms = [{"projects", "write", "website-redesign"}]

      assert {:error, {:permission_denied, "projects:write:marketing"}} =
               ACLMapper.check_action(perms, {"projects", "write", "marketing"})
    end

    test "wildcard scope matches any target" do
      perms = [{"projects", "write", "*"}]
      assert :ok = ACLMapper.check_action(perms, {"projects", "write", "anything"})
    end

    test "action mismatch is denied" do
      perms = [{"chat", "read", "*"}]

      assert {:error, {:permission_denied, "chat:write:general"}} =
               ACLMapper.check_action(perms, {"chat", "write", "general"})
    end

    test "empty permissions denies everything" do
      assert {:error, {:permission_denied, "projects:read:foo"}} =
               ACLMapper.check_action([], {"projects", "read", "foo"})
    end

    test "multiple permissions checked in order" do
      perms = [
        {"chat", "read", "*"},
        {"projects", "write", "website-redesign"}
      ]

      assert :ok = ACLMapper.check_action(perms, {"projects", "write", "website-redesign"})
      assert :ok = ACLMapper.check_action(perms, {"chat", "read", "general"})
    end
  end

  describe "acl_entries/2" do
    test "baseline entries for agent with no permissions" do
      entries = ACLMapper.acl_entries("glorbo-acme-x", [])

      assert {"glorbo-acme-x", :rwx, "agents/x/outbox"} in entries
      assert {"glorbo-acme-x", :rwx, "agents/x/workspace"} in entries
      assert {"glorbo-acme-x", :rwx, "agents/x/state"} in entries
      assert {"glorbo-acme-x", :r, "agents/x/inbox"} in entries

      # Only baseline — no extra entries
      assert length(entries) == 4
    end

    test "projects:write adds rwx entry" do
      perms = [{"projects", "write", "website-redesign"}]
      entries = ACLMapper.acl_entries("glorbo-acme-engineer", perms)

      assert {"glorbo-acme-engineer", :rwx, "projects/website-redesign"} in entries
    end

    test "projects:read adds rx entry" do
      perms = [{"projects", "read", "docs"}]
      entries = ACLMapper.acl_entries("glorbo-acme-engineer", perms)

      assert {"glorbo-acme-engineer", :rx, "projects/docs"} in entries
    end

    test "projects:write:* adds rwx on projects" do
      perms = [{"projects", "write", "*"}]
      entries = ACLMapper.acl_entries("glorbo-acme-eng", perms)

      assert {"glorbo-acme-eng", :rwx, "projects"} in entries
    end

    test "projects:read:* adds rx on projects" do
      perms = [{"projects", "read", "*"}]
      entries = ACLMapper.acl_entries("glorbo-acme-eng", perms)

      assert {"glorbo-acme-eng", :rx, "projects"} in entries
    end

    test "chat:read:* adds r on channels" do
      perms = [{"chat", "read", "*"}]
      entries = ACLMapper.acl_entries("glorbo-acme-engineer", perms)

      assert {"glorbo-acme-engineer", :r, "channels"} in entries
    end

    test "chat:read:<channel> adds r on specific channel file" do
      perms = [{"chat", "read", "general"}]
      entries = ACLMapper.acl_entries("glorbo-acme-eng", perms)

      assert {"glorbo-acme-eng", :r, "channels/general.md"} in entries
    end

    test "chat:write produces NO ACL entry (Elixir is sole writer D-08)" do
      perms = [{"chat", "write", "*"}]
      entries = ACLMapper.acl_entries("glorbo-acme-eng", perms)

      # Only baseline entries — no channel write ACL
      assert length(entries) == 4
    end

    test "agents:message produces no ACL entry" do
      perms = [{"agents", "message", "ceo"}]
      entries = ACLMapper.acl_entries("glorbo-acme-eng", perms)

      assert length(entries) == 4
    end

    test "agents:create produces no ACL entry" do
      perms = [{"agents", "create", "*"}]
      entries = ACLMapper.acl_entries("glorbo-acme-eng", perms)

      assert length(entries) == 4
    end

    test "tasks:update adds rwx on projects/<scope>/tasks" do
      perms = [{"tasks", "update", "website-redesign"}]
      entries = ACLMapper.acl_entries("glorbo-acme-eng", perms)

      assert {"glorbo-acme-eng", :rwx, "projects/website-redesign/tasks"} in entries
    end

    test "combined permissions produce deterministic sorted output" do
      perms = [
        {"projects", "write", "website-redesign"},
        {"chat", "read", "*"}
      ]

      entries = ACLMapper.acl_entries("glorbo-acme-engineer", perms)

      # Verify sorting by path for deterministic permissions_hash
      paths = Enum.map(entries, fn {_, _, path} -> path end)
      assert paths == Enum.sort(paths)
    end
  end
end
