defmodule Glorbo.Sandbox.PermissionMapperTest do
  use ExUnit.Case, async: true

  alias Glorbo.Sandbox.PermissionMapper

  @co "/tmp/co"

  describe "to_argv/2 — core projects mapping (PM1–PM5)" do
    test "PM1: empty permission list → empty argv" do
      assert PermissionMapper.to_argv([], @co) == []
    end

    test "PM2: projects:write:<name> → --bind of only that project (sibling invisible)" do
      assert PermissionMapper.to_argv([{"projects", "write", "website-redesign"}], @co) ==
               ["--bind", "/tmp/co/projects/website-redesign", "/projects/website-redesign"]
    end

    test "PM3: projects:read:<name> → --ro-bind" do
      assert PermissionMapper.to_argv([{"projects", "read", "marketing"}], @co) ==
               ["--ro-bind", "/tmp/co/projects/marketing", "/projects/marketing"]
    end

    test "PM4: projects:read:* → --ro-bind of whole projects tree" do
      assert PermissionMapper.to_argv([{"projects", "read", "*"}], @co) ==
               ["--ro-bind", "/tmp/co/projects", "/projects"]
    end

    test "PM5: projects:write:* → --bind of whole projects tree" do
      assert PermissionMapper.to_argv([{"projects", "write", "*"}], @co) ==
               ["--bind", "/tmp/co/projects", "/projects"]
    end
  end

  describe "to_argv/2 — chat permissions (PM6–PM8)" do
    test "PM6: chat:read:* → --ro-bind of channels tree" do
      assert PermissionMapper.to_argv([{"chat", "read", "*"}], @co) ==
               ["--ro-bind", "/tmp/co/channels", "/channels"]
    end

    test "PM7: chat:read:<channel> → single-file --ro-bind" do
      assert PermissionMapper.to_argv([{"chat", "read", "general"}], @co) ==
               ["--ro-bind", "/tmp/co/channels/general.md", "/channels/general.md"]
    end

    test "PM8: chat:write:<channel> → [] (Router mediates)" do
      assert PermissionMapper.to_argv([{"chat", "write", "general"}], @co) == []
      assert PermissionMapper.to_argv([{"chat", "write", "*"}], @co) == []
    end
  end

  describe "to_argv/2 — agents permissions (PM9–PM12)" do
    test "PM9: agents:message:<target> → [] (Router mediates)" do
      assert PermissionMapper.to_argv([{"agents", "message", "ceo"}], @co) == []
      assert PermissionMapper.to_argv([{"agents", "message", "*"}], @co) == []
    end

    test "PM10: agents:create:* → [] (never granted; AGT-05)" do
      assert PermissionMapper.to_argv([{"agents", "create", "*"}], @co) == []
    end

    test "PM11: tasks:update:<project> → --bind of the project's tasks/ subdir" do
      assert PermissionMapper.to_argv([{"tasks", "update", "foo"}], @co) ==
               ["--bind", "/tmp/co/projects/foo/tasks", "/projects/foo/tasks"]
    end

    test "PM12: agents:list:* → [] + warning (D-12 deferred to v0.0.2)" do
      # Capture the Logger warning to keep test output tidy; assert [] return.
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          assert PermissionMapper.to_argv([{"agents", "list", "*"}], @co) == []
        end)

      assert log =~ "agents:list"
    end
  end

  describe "to_argv/2 — composition" do
    test "multiple permissions are flat-concatenated in order" do
      perms = [
        {"projects", "write", "a"},
        {"projects", "read", "b"},
        {"chat", "read", "*"}
      ]

      assert PermissionMapper.to_argv(perms, @co) == [
               "--bind",
               "/tmp/co/projects/a",
               "/projects/a",
               "--ro-bind",
               "/tmp/co/projects/b",
               "/projects/b",
               "--ro-bind",
               "/tmp/co/channels",
               "/channels"
             ]
    end
  end
end
