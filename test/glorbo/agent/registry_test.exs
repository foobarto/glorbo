defmodule Glorbo.Agent.RegistryTest do
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Registry, as: AgentRegistry

  setup do
    # Use a per-test unique registry name via a dynamically-created module alias
    name = Glorbo.Test.UniqueName.gen("test_registry")
    start_supervised!({Registry, keys: :unique, name: name})
    {:ok, registry: name}
  end

  test "RG1: can register a process under {:agent_server, co, ag}", ctx do
    assert {:ok, _} = Registry.register(ctx.registry, {:agent_server, "acme", "engineer"}, :meta)
  end

  test "RG2: lookup returns {pid, meta}", ctx do
    task =
      Task.async(fn ->
        {:ok, _} = Registry.register(ctx.registry, {:agent_server, "acme", "bot"}, :my_meta)

        receive do
          :stop -> :ok
        end
      end)

    # Give the task a moment to register
    Process.sleep(20)

    assert [{pid, :my_meta}] = Registry.lookup(ctx.registry, {:agent_server, "acme", "bot"})
    assert pid == task.pid

    send(task.pid, :stop)
    Task.await(task)
  end

  test "RG3: duplicate registration returns {:error, {:already_registered, pid}}", ctx do
    {:ok, _} = Registry.register(ctx.registry, {:agent_server, "acme", "dup"}, :first)

    assert {:error, {:already_registered, _}} =
             Registry.register(ctx.registry, {:agent_server, "acme", "dup"}, :second)
  end

  test "via/3 helper builds a proper :via tuple" do
    assert {:via, Registry, {AgentRegistry, {:agent_server, "acme", "bot"}}} =
             AgentRegistry.via(:agent_server, "acme", "bot")
  end

  test "AgentRegistry.child_spec/1 returns a valid Registry child spec" do
    spec = AgentRegistry.child_spec([])
    assert is_map(spec) or is_tuple(spec)
  end
end
