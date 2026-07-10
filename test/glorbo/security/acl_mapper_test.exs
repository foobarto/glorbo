defmodule Glorbo.Security.ACLMapperTest do
  use ExUnit.Case, async: true

  alias Glorbo.Security.ACLMapper

  describe "parse_permission/1" do
    test "accepts underscore-bearing agent scopes" do
      assert {:ok, {"agents", "message", "qa_lead"}} =
               ACLMapper.parse_permission("agents:message:qa_lead")
    end

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

    test "rejects known capability families without an implementation" do
      assert {:error, :not_implemented} = ACLMapper.parse_permission("agents:create:*")
      assert {:error, :not_implemented} = ACLMapper.parse_permission("agents:list:*")
      assert {:error, :not_implemented} = ACLMapper.parse_permission("tasks:write:docs")
    end

    test "rejects unknown actions on known resources" do
      assert {:error, :unknown_action} = ACLMapper.parse_permission("chat:delete:general")
      assert {:error, :unknown_action} = ACLMapper.parse_permission("tasks:approve:docs")
    end

    test "enforces wildcard-only proposal scopes" do
      assert {:ok, {"proposals", "read", "*"}} =
               ACLMapper.parse_permission("proposals:read:*")

      assert {:error, :invalid_scope} = ACLMapper.parse_permission("proposals:read:private")
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

    test "unsupported direct tuples fail loudly instead of weakening the ACL" do
      assert_raise ArgumentError, ~r/unsupported ACL permission/, fn ->
        ACLMapper.acl_entries("glorbo-acme-eng", [{"agents", "create", "*"}])
      end
    end

    test "direct tuples cannot bypass scope validation" do
      assert_raise ArgumentError, ~r/invalid_scope/, fn ->
        ACLMapper.acl_entries("glorbo-acme-eng", [{"projects", "write", "../other"}])
      end
    end

    test "tasks:update adds rwx on projects/<scope>/tasks" do
      perms = [{"tasks", "update", "website-redesign"}]
      entries = ACLMapper.acl_entries("glorbo-acme-eng", perms)

      assert {"glorbo-acme-eng", :rwx, "projects/website-redesign/tasks"} in entries
    end

    test "tasks:read adds rx on projects/<scope>/tasks" do
      entries = ACLMapper.acl_entries("glorbo-acme-eng", [{"tasks", "read", "docs"}])

      assert {"glorbo-acme-eng", :rx, "projects/docs/tasks"} in entries
    end

    test "wildcard task ACLs require and use company-path expansion" do
      root =
        Path.join(System.tmp_dir!(), "glorbo-acl-wildcard-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join([root, "projects", "alpha", "tasks"]))
      File.mkdir_p!(Path.join([root, "projects", "beta", "tasks"]))
      on_exit(fn -> File.rm_rf!(root) end)

      assert_raise ArgumentError, ~r/company-path expansion/, fn ->
        ACLMapper.acl_entries("glorbo-acme-eng", [{"tasks", "update", "*"}])
      end

      entries = ACLMapper.acl_entries("glorbo-acme-eng", [{"tasks", "update", "*"}], root)

      assert {"glorbo-acme-eng", :rwx, "projects/alpha/tasks"} in entries
      assert {"glorbo-acme-eng", :rwx, "projects/beta/tasks"} in entries
      refute Enum.any?(entries, fn {_, _, path} -> String.contains?(path, "*") end)
    end

    test "wildcard task ACL expansion ignores symlinked project directories" do
      root =
        Path.join(System.tmp_dir!(), "glorbo-acl-symlink-#{System.unique_integer([:positive])}")

      victim =
        Path.join(System.tmp_dir!(), "glorbo-acl-victim-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join([root, "projects"]))
      File.mkdir_p!(Path.join(victim, "tasks"))
      :ok = File.ln_s(victim, Path.join([root, "projects", "escape"]))

      on_exit(fn ->
        File.rm_rf!(root)
        File.rm_rf!(victim)
      end)

      entries = ACLMapper.acl_entries("glorbo-acme-eng", [{"tasks", "update", "*"}], root)

      refute Enum.any?(entries, fn {_, _, path} -> String.contains?(path, "escape") end)
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
