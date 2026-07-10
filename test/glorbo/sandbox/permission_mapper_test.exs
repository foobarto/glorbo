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

    test "PM10: unsupported permissions fail loudly" do
      assert_raise ArgumentError, ~r/unsupported permission/, fn ->
        PermissionMapper.to_argv([{"agents", "create", "*"}], @co)
      end
    end

    test "PM11: tasks:update:<project> → --bind of the project's tasks/ subdir" do
      assert PermissionMapper.to_argv([{"tasks", "update", "foo"}], @co) ==
               ["--bind", "/tmp/co/projects/foo/tasks", "/projects/foo/tasks"]
    end

    test "PM12: agents:list:* cannot degrade to an empty policy" do
      assert_raise ArgumentError, ~r/unsupported permission/, fn ->
        PermissionMapper.to_argv([{"agents", "list", "*"}], @co)
      end
    end
  end

  describe "to_argv/2 — task capability mappings" do
    setup do
      co = Path.join(System.tmp_dir!(), "glorbo-pm-tasks-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([co, "projects", "alpha", "tasks"]))
      File.mkdir_p!(Path.join([co, "projects", "beta", "tasks"]))
      on_exit(fn -> File.rm_rf!(co) end)
      {:ok, co: co}
    end

    test "tasks:read:<project> is an exact read-only task mount", %{co: co} do
      assert PermissionMapper.to_argv([{"tasks", "read", "alpha"}], co) == [
               "--ro-bind",
               Path.join([co, "projects", "alpha", "tasks"]),
               "/projects/alpha/tasks"
             ]
    end

    test "wildcard task permissions expand without exposing project roots", %{co: co} do
      argv = PermissionMapper.to_argv([{"tasks", "update", "*"}], co)

      assert argv == [
               "--bind",
               Path.join([co, "projects", "alpha", "tasks"]),
               "/projects/alpha/tasks",
               "--bind",
               Path.join([co, "projects", "beta", "tasks"]),
               "/projects/beta/tasks"
             ]

      refute Path.join(co, "projects") in argv
      refute "/projects" in argv
    end

    test "tasks:create is explicitly Router-mediated", %{co: co} do
      assert PermissionMapper.to_argv([{"tasks", "create", "*"}], co) == []
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

  # PR #35 (codex round-3 F1): cross-agent symlink-segment bypass.
  # Agent A holds `projects:write:foo` → rw on `<co>/projects/foo` →
  # plants `<co>/projects/foo/tasks` → `~/.ssh`; agent B holds
  # `tasks:update:foo` → bwrap resolves the symlink HOST-SIDE before
  # the namespace switch and mounts `~/.ssh` rw inside B's sandbox.
  # `PermissionMapper.to_argv/2` must refuse at argv-emission time.
  describe "to_argv/2 — symlink-segment refusal (codex round-3 F1)" do
    setup do
      co = Path.join(System.tmp_dir!(), "glorbo-pm-symlink-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([co, "projects", "foo"]))
      on_exit(fn -> File.rm_rf!(co) end)
      {:ok, co: co}
    end

    test "tasks:update:<project> refuses when the tasks/ leaf is a symlink", %{co: co} do
      # Simulate agent A's planted symlink at the leaf.
      target = Path.join([System.tmp_dir!(), "victim-#{System.unique_integer([:positive])}"])
      File.mkdir_p!(target)
      :ok = File.ln_s(target, Path.join([co, "projects", "foo", "tasks"]))

      assert_raise ArgumentError, ~r/permission_mapper: mount source/, fn ->
        PermissionMapper.to_argv([{"tasks", "update", "foo"}], co)
      end
    end

    test "projects:write:<name> refuses when an ancestor segment is a symlink", %{co: co} do
      # Plant the symlink ABOVE the leaf — at `<co>/projects/foo`.
      File.rm_rf!(Path.join([co, "projects", "foo"]))
      target = Path.join([System.tmp_dir!(), "vict2-#{System.unique_integer([:positive])}"])
      File.mkdir_p!(target)
      :ok = File.ln_s(target, Path.join([co, "projects", "foo"]))

      assert_raise ArgumentError, ~r/symlinked component/, fn ->
        PermissionMapper.to_argv([{"projects", "write", "foo"}], co)
      end
    end

    test "chat:read:<channel> refuses when the channel file segment is a symlink", %{co: co} do
      File.mkdir_p!(Path.join(co, "channels"))
      target = Path.join([System.tmp_dir!(), "leak-#{System.unique_integer([:positive])}"])
      File.write!(target, "secrets")
      :ok = File.ln_s(target, Path.join([co, "channels", "general.md"]))

      assert_raise ArgumentError, ~r/symlinked component/, fn ->
        PermissionMapper.to_argv([{"chat", "read", "general"}], co)
      end
    end

    test "real (non-symlink) tasks/ dir is allowed", %{co: co} do
      File.mkdir_p!(Path.join([co, "projects", "foo", "tasks"]))

      argv = PermissionMapper.to_argv([{"tasks", "update", "foo"}], co)

      assert argv == [
               "--bind",
               Path.join([co, "projects", "foo", "tasks"]),
               "/projects/foo/tasks"
             ]
    end
  end
end
