defmodule Glorbo.Agent.RegistryTest do
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Registry, as: AgentRegistry

  test "via/3 builds the canonical :via tuple for {kind, company, agent}" do
    assert {:via, Registry, {AgentRegistry, {:agent_server, "acme", "bot"}}} =
             AgentRegistry.via(:agent_server, "acme", "bot")
  end

  test "child_spec/1 returns a unique-keyed Registry rooted at the module name" do
    spec = AgentRegistry.child_spec([])

    # Spec is a map with id pointing at the module + start MFA wiring a
    # Registry. Caller-visible contract: `keys: :unique` and `name:
    # AgentRegistry` so other modules can `Registry.lookup(AgentRegistry,
    # ...)` against it.
    assert %{id: id, start: {Registry, :start_link, [opts]}} = spec
    assert id == AgentRegistry
    assert Keyword.fetch!(opts, :name) == AgentRegistry
    assert Keyword.fetch!(opts, :keys) == :unique
  end
end
