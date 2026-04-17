defmodule Glorbo.Company.AgentSupervisorTest do
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Spec
  alias Glorbo.Company.AgentSupervisor

  setup do
    reg_name = :"agsup_reg_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: reg_name})

    sup_name = :"agsup_#{System.unique_integer([:positive])}"
    sup = start_supervised!({AgentSupervisor, name: sup_name, company: "acme"})

    {:ok, sup: sup, registry: reg_name}
  end

  defp make_spec(slug) do
    %Spec{
      slug: slug,
      company: "acme",
      role: "x",
      provider: "claude-code",
      model: "claude-opus-4-6",
      permissions: [],
      heartbeat: nil,
      network: :none,
      skills: [],
      budget_usd_cents_month: nil,
      timeout_seconds: 300,
      file_path: "/tmp/agent.md"
    }
  end

  defp stub_agent_opts(registry) do
    # Use a dispatch fun that does nothing so Agent.Server doesn't actually
    # call Dispatch (which would need adapters/etc). Registry must be passed
    # so Agent.Server + Task.Supervisor names resolve correctly.
    [
      registry: registry,
      dispatch_fun: fn _spec, _task, _opts -> {:ok, %{exit_status: 0}} end,
      inbox_scan_fun: fn _spec -> nil end
    ]
  end

  # ---------------------------------------------------------------------------
  # AS1 — start_link
  # ---------------------------------------------------------------------------

  test "AS1: start_link produces a running DynamicSupervisor", ctx do
    assert is_pid(ctx.sup)
    assert Process.alive?(ctx.sup)
    assert %{workers: 0, active: 0} = DynamicSupervisor.count_children(ctx.sup)
  end

  # ---------------------------------------------------------------------------
  # AS2 — start_agent
  # ---------------------------------------------------------------------------

  test "AS2: start_agent spawns a 2-child subtree + registers", ctx do
    assert {:ok, subtree_pid} =
             AgentSupervisor.start_agent(
               ctx.sup,
               make_spec("engineer"),
               stub_agent_opts(ctx.registry)
             )

    assert Process.alive?(subtree_pid)

    # Agent.Server + Task.Supervisor both registered
    assert [{server_pid, _}] =
             Registry.lookup(ctx.registry, {:agent_server, "acme", "engineer"})

    assert [{task_sup_pid, _}] =
             Registry.lookup(ctx.registry, {:agent_task_sup, "acme", "engineer"})

    assert Process.alive?(server_pid)
    assert Process.alive?(task_sup_pid)

    assert [{^subtree_pid, _}] =
             Registry.lookup(ctx.registry, {:agent_subtree, "acme", "engineer"})
  end

  # ---------------------------------------------------------------------------
  # AS3 — 3 distinct agents
  # ---------------------------------------------------------------------------

  test "AS3: 3 distinct agents yield 3 active children in the DynamicSupervisor", ctx do
    opts = stub_agent_opts(ctx.registry)

    {:ok, _} = AgentSupervisor.start_agent(ctx.sup, make_spec("engineer"), opts)
    {:ok, _} = AgentSupervisor.start_agent(ctx.sup, make_spec("designer"), opts)
    {:ok, _} = AgentSupervisor.start_agent(ctx.sup, make_spec("writer"), opts)

    assert %{active: 3, workers: 0, supervisors: 3} =
             DynamicSupervisor.count_children(ctx.sup)
  end

  # ---------------------------------------------------------------------------
  # AS4 — duplicate slug rejected
  # ---------------------------------------------------------------------------

  test "AS4: starting two agents with the same slug returns {:error, {:already_started, _}}",
       ctx do
    opts = stub_agent_opts(ctx.registry)

    {:ok, _} = AgentSupervisor.start_agent(ctx.sup, make_spec("duplicate"), opts)

    assert {:error, {:already_started, _}} =
             AgentSupervisor.start_agent(ctx.sup, make_spec("duplicate"), opts)
  end

  # ---------------------------------------------------------------------------
  # AS5 — kill Agent.Server → one_for_all restart
  # ---------------------------------------------------------------------------

  test "AS5: killing Agent.Server restarts both children (one_for_all) - others unaffected",
       ctx do
    opts = stub_agent_opts(ctx.registry)

    {:ok, _} = AgentSupervisor.start_agent(ctx.sup, make_spec("a1"), opts)
    {:ok, _} = AgentSupervisor.start_agent(ctx.sup, make_spec("a2"), opts)

    [{a1_server, _}] = Registry.lookup(ctx.registry, {:agent_server, "acme", "a1"})
    [{a1_task_sup, _}] = Registry.lookup(ctx.registry, {:agent_task_sup, "acme", "a1"})
    [{a2_server, _}] = Registry.lookup(ctx.registry, {:agent_server, "acme", "a2"})

    ref_task_sup = Process.monitor(a1_task_sup)

    Process.exit(a1_server, :kill)

    # one_for_all means the sibling Task.Supervisor is also killed + restarted
    assert_receive {:DOWN, ^ref_task_sup, :process, ^a1_task_sup, _}, 1_000

    # Give supervisor time to restart
    Process.sleep(100)

    # Both Agent.Server + Task.Supervisor for a1 restarted under NEW pids
    [{new_a1_server, _}] = Registry.lookup(ctx.registry, {:agent_server, "acme", "a1"})
    [{new_a1_task_sup, _}] = Registry.lookup(ctx.registry, {:agent_task_sup, "acme", "a1"})
    assert new_a1_server != a1_server
    assert new_a1_task_sup != a1_task_sup

    # a2 is completely unaffected
    [{still_a2_server, _}] = Registry.lookup(ctx.registry, {:agent_server, "acme", "a2"})
    assert still_a2_server == a2_server
  end

  # ---------------------------------------------------------------------------
  # AS6 — kill Task.Supervisor → one_for_all restart
  # ---------------------------------------------------------------------------

  test "AS6: killing Task.Supervisor restarts both children", ctx do
    opts = stub_agent_opts(ctx.registry)
    {:ok, _} = AgentSupervisor.start_agent(ctx.sup, make_spec("t1"), opts)

    [{server_pid, _}] = Registry.lookup(ctx.registry, {:agent_server, "acme", "t1"})
    [{task_sup_pid, _}] = Registry.lookup(ctx.registry, {:agent_task_sup, "acme", "t1"})

    ref = Process.monitor(server_pid)
    Process.exit(task_sup_pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^server_pid, _}, 1_000

    Process.sleep(100)

    # Both restarted
    [{new_server, _}] = Registry.lookup(ctx.registry, {:agent_server, "acme", "t1"})
    assert new_server != server_pid
  end

  # ---------------------------------------------------------------------------
  # AS8 — stop_agent terminates the subtree
  # ---------------------------------------------------------------------------

  test "AS8: stop_agent/2 removes the agent subtree and deregisters", ctx do
    opts = stub_agent_opts(ctx.registry)
    {:ok, subtree} = AgentSupervisor.start_agent(ctx.sup, make_spec("victim"), opts)

    assert :ok = AgentSupervisor.stop_agent(ctx.sup, "acme", "victim", ctx.registry)

    refute Process.alive?(subtree)
    # Registry cleanup is driven by DOWN monitors and happens async after
    # the subtree dies. Poll briefly rather than racing.
    assert_eventually(fn ->
      Registry.lookup(ctx.registry, {:agent_server, "acme", "victim"}) == []
    end)
  end

  defp assert_eventually(fun, deadline_ms \\ 500) do
    t0 = System.monotonic_time(:millisecond)

    do_assert_eventually =
      fn loop ->
        cond do
          fun.() ->
            :ok

          System.monotonic_time(:millisecond) - t0 > deadline_ms ->
            flunk("condition did not hold within #{deadline_ms}ms")

          true ->
            Process.sleep(10)
            loop.(loop)
        end
      end

    do_assert_eventually.(do_assert_eventually)
  end

  test "AS8b: stop_agent on unknown slug returns {:error, :not_found}", ctx do
    assert {:error, :not_found} =
             AgentSupervisor.stop_agent(ctx.sup, "acme", "does-not-exist", ctx.registry)
  end
end
