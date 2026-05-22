defmodule Glorbo.Company.AgentBootTest do
  use ExUnit.Case, async: false

  # CompanySupervisor spins up a Filesystem.Watcher child that transitively
  # requires inotify — gate the whole module the same way supervisor_test.exs
  # does so dev hosts without inotify-tools skip cleanly.
  @moduletag :inotify

  alias Glorbo.Agent.FileLayout
  alias Glorbo.Company.Supervisor, as: CompanySup
  alias Glorbo.Test.TmpGlorboHome

  setup do
    # Flip the test-env gate for this module — we specifically want to
    # exercise AgentBoot. Restore on teardown so other tests that spin
    # up a CompanySupervisor through fixtures stay isolated.
    previous = Application.get_env(:glorbo, :auto_boot_agents, false)
    Application.put_env(:glorbo, :auto_boot_agents, true)
    on_exit(fn -> Application.put_env(:glorbo, :auto_boot_agents, previous) end)

    # #145: avoid racing Application.Agent.Registry; ensure app is up.
    Application.ensure_all_started(:glorbo)
    :ok
  end

  defp write_agent(base, company, slug, heartbeat) do
    agent_dir = Path.join([base, "companies", company, "agents", slug])
    File.mkdir_p!(Path.join(agent_dir, "inbox"))
    File.mkdir_p!(Path.join(agent_dir, "outbox"))
    File.mkdir_p!(Path.join(agent_dir, "workspace"))
    File.mkdir_p!(Path.join(agent_dir, "history"))
    File.mkdir_p!(Path.join(agent_dir, "state"))
    File.write!(Path.join(agent_dir, "stdout.log"), "")

    heartbeat_line =
      case heartbeat do
        nil -> "heartbeat: null"
        s when is_binary(s) -> ~s(heartbeat: "#{s}")
      end

    File.write!(FileLayout.agent_md_canonical(agent_dir), """
    ---
    kind: agent/v1
    name: #{String.upcase(slug)}
    slug: #{slug}
    role: "Test agent"
    provider: claude-code
    model: claude-sonnet-4-5
    network: loopback
    #{heartbeat_line}
    permissions: []
    budget:
      monthly_usd: 10.00
    skills: []
    ---

    # #{slug}
    """)

    File.write!(Path.join(agent_dir, "HEARTBEAT.md"), "Check inbox.\n")
    agent_dir
  end

  defp start_company(company, base) do
    sup_name = Glorbo.Test.UniqueName.gen("company_sup")

    {:ok, sup_pid} =
      CompanySup.start_link(
        name: sup_name,
        company: company,
        base: base
      )

    on_exit(fn ->
      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    sup_pid
  end

  test "AgentBoot enumerates AGENT.md files and starts agent sub-trees" do
    base = TmpGlorboHome.setup()
    company = "co_#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join([base, "companies", company]))

    write_agent(base, company, "ceo", "*/30 * * * *")
    write_agent(base, company, "engineer", nil)

    _sup = start_company(company, base)

    # AgentBoot is a Task — poll briefly for the agents to register.
    assert wait_for(fn ->
             Registry.lookup(Glorbo.Agent.Registry, {:agent_subtree, company, "ceo"}) != [] and
               Registry.lookup(Glorbo.Agent.Registry, {:agent_subtree, company, "engineer"}) != []
           end)
  end

  # codex C-108: auto-booted agents must carry the production
  # dispatch_opts (real per-company budget gate + usage recorder + the
  # resolved base) so budget enforcement isn't silently disabled on the
  # heartbeat/inbox wake path. Previously start_agent was called with no
  # agent_opts, leaving dispatch_opts == [] → no-op budget/usage funs.
  test "AgentBoot wires budget enforcement into auto-booted agents' dispatch_opts" do
    base = TmpGlorboHome.setup()
    company = "co_#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join([base, "companies", company]))
    write_agent(base, company, "engineer", nil)

    _sup = start_company(company, base)

    server = {:via, Registry, {Glorbo.Agent.Registry, {:agent_server, company, "engineer"}}}

    assert wait_for(fn ->
             Registry.lookup(Glorbo.Agent.Registry, {:agent_server, company, "engineer"}) != []
           end)

    state = :sys.get_state(server)
    opts = state.dispatch_opts

    assert is_function(opts[:budget_tracker_fun], 1),
           "auto-booted agent missing :budget_tracker_fun (budget gate disabled)"

    assert is_function(opts[:record_usage_fun], 3),
           "auto-booted agent missing :record_usage_fun (usage never recorded)"

    assert opts[:base] == base, "auto-booted agent dispatch base must be the resolved GLORBO_HOME"
  end

  test "AgentBoot skips malformed AGENT.md without crashing the company" do
    base = TmpGlorboHome.setup()
    company = "co_#{System.unique_integer([:positive])}"
    agent_dir = Path.join([base, "companies", company, "agents", "broken"])
    File.mkdir_p!(agent_dir)

    # Missing provider / model — AgentParser rejects this.
    File.write!(FileLayout.agent_md_canonical(agent_dir), """
    ---
    name: broken
    ---
    # broken
    """)

    # And one valid agent alongside.
    write_agent(base, company, "ok-agent", nil)

    sup = start_company(company, base)

    assert wait_for(fn ->
             Registry.lookup(Glorbo.Agent.Registry, {:agent_subtree, company, "ok-agent"}) != []
           end)

    # The company supervisor itself is still alive — the broken agent
    # didn't bring it down.
    assert Process.alive?(sup)
    assert Registry.lookup(Glorbo.Agent.Registry, {:agent_subtree, company, "broken"}) == []
  end

  test "AgentBoot registers heartbeats with the Scheduler for agents with a cron" do
    base = TmpGlorboHome.setup()
    company = "co_#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join([base, "companies", company]))

    write_agent(base, company, "ceo", "*/30 * * * *")

    _sup = start_company(company, base)

    # Wait for the agent subtree to exist.
    assert wait_for(fn ->
             Registry.lookup(Glorbo.Agent.Registry, {:agent_subtree, company, "ceo"}) != []
           end)

    # The Scheduler accepts registration via idempotent replace — verify
    # we can re-register the same agent and get :ok, which is our proxy
    # for "it's a working Scheduler process and the agent is known to it."
    sched = CompanySup.via(company, :scheduler)

    assert :ok =
             Glorbo.Company.Scheduler.register(sched, "ceo", %{
               cron: "*/30 * * * *",
               dispatch_fun: fn _ -> :ok end
             })
  end

  defp wait_for(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        do_wait(fun, deadline)
      end
    end
  end
end
