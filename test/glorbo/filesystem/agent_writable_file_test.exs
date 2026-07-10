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

  test "create_exclusive cannot be redirected by swapping its parent after chdir", %{root: root} do
    parent = Path.join(root, "outbox")
    original = Path.join(root, "original-outbox")
    victim = Path.join(root, "victim")
    wrapper = Path.join(root, "delayed-sh")
    ready = Path.join(root, "helper-ready")
    go = Path.join(root, "helper-go")

    File.mkdir_p!(parent)
    File.mkdir_p!(victim)

    File.write!(wrapper, """
    #!/bin/sh
    : > ../helper-ready
    while [ ! -e ../helper-go ]; do sleep 0.01; done
    exec /bin/sh "$@"
    """)

    File.chmod!(wrapper, 0o700)

    task =
      Task.async(fn ->
        AgentWritableFile.create_exclusive(Path.join(parent, "reply.md"), "safe", shell: wrapper)
      end)

    assert eventually(fn -> File.exists?(ready) end)
    File.rename!(parent, original)
    File.ln_s!(victim, parent)
    File.write!(go, "go")

    assert {:error, :symlinked_ancestor} = Task.await(task)
    refute File.exists?(Path.join(victim, "reply.md"))
    refute File.exists?(Path.join(original, "reply.md"))
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
