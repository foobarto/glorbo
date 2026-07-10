defmodule Glorbo.Filesystem.AgentWritableFileTest do
  use ExUnit.Case, async: true

  alias Glorbo.Filesystem.AgentWritableFile

  setup do
    root = Path.join(System.tmp_dir!(), "agent-writable-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "create_exclusive creates a new file exactly once", %{root: root} do
    path = Path.join([root, "outbox", "reply.md"])

    assert :ok = AgentWritableFile.create_exclusive(path, "first")
    assert {:error, :eexist} = AgentWritableFile.create_exclusive(path, "second")
    assert File.read!(path) == "first"
  end

  test "create_exclusive refuses a dangling symlink leaf", %{root: root} do
    outbox = Path.join(root, "outbox")
    File.mkdir_p!(outbox)
    target = Path.join(root, "victim")
    link = Path.join(outbox, "reply.md")
    File.ln_s!(target, link)

    assert {:error, :eexist} = AgentWritableFile.create_exclusive(link, "attack")
    refute File.exists?(target)
  end

  test "create_exclusive refuses a symlinked parent", %{root: root} do
    target = Path.join(root, "target")
    File.mkdir_p!(target)
    File.ln_s!(target, Path.join(root, "outbox"))

    assert {:error, :symlinked_ancestor} =
             AgentWritableFile.create_exclusive(Path.join([root, "outbox", "reply.md"]), "x")

    refute File.exists?(Path.join(target, "reply.md"))
  end
end
