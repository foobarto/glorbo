defmodule Glorbo.Company.SupervisorTest do
  use ExUnit.Case, async: false

  # Watcher transitively requires inotify to fully start — gate the whole
  # module so dev hosts without inotify-tools skip cleanly (same pattern as
  # watcher_test.exs).
  @moduletag :inotify

  alias Glorbo.Company.Supervisor, as: CompanySup
  alias Glorbo.Test.TmpGlorboHome

  # Start a CompanySupervisor rooted at an isolated tmp dir + registry.
  defp start_company(overrides \\ []) do
    base = TmpGlorboHome.setup()
    company = Keyword.get(overrides, :company, "co_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([base, "companies", company]))

    sup_name = Glorbo.Test.UniqueName.gen("company_sup")

    # Registry may or may not already be started by the application — start if
    # not already up.
    # #145: avoid racing Application.Agent.Registry; ensure app is up.
    Application.ensure_all_started(:glorbo)

    {:ok, sup_pid} =
      CompanySup.start_link(
        Keyword.merge(
          [name: sup_name, company: company, base: base],
          Keyword.drop(overrides, [:company])
        )
      )

    on_exit(fn ->
      # `Supervisor.stop/1` passes `:normal` through to `GenServer.stop`,
      # which raises if the supervisor exits with a different reason
      # (children that terminate with `:shutdown` propagate up). Either
      # outcome — clean normal exit or shutdown cascade — is fine for
      # test teardown; swallow the exit.
      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {sup_pid, company, base}
  end

  describe "S1: 10-child base tree (AgentSupervisor + AgentBoot now share a :rest_for_one sub-tree)" do
    test "CompanySupervisor starts 10 direct children by default (no proxy agents)" do
      {sup_pid, co, _base} = start_company()
      children = Supervisor.which_children(sup_pid)
      # AuditLog, Watcher, Router, Scheduler, TaskScheduler, BudgetTracker,
      # agent_fleet sub-supervisor, Approvals.Gate, PathRequestGate,
      # ProposalsSink. AgentSupervisor + AgentBoot live under agent_fleet.
      assert length(children) == 10

      ids = Enum.map(children, fn {id, _pid, _type, _mods} -> id end) |> MapSet.new()

      assert MapSet.member?(ids, Glorbo.Company.AuditLog)
      assert MapSet.member?(ids, Glorbo.Filesystem.Watcher)
      assert MapSet.member?(ids, Glorbo.Company.Router)
      assert MapSet.member?(ids, Glorbo.Company.Scheduler)
      assert MapSet.member?(ids, Glorbo.Company.TaskScheduler)
      assert MapSet.member?(ids, Glorbo.Company.BudgetTracker)
      assert MapSet.member?(ids, Glorbo.Approvals.Gate)
      assert MapSet.member?(ids, Glorbo.PathRequestGate)
      assert MapSet.member?(ids, Glorbo.Company.ProposalsSink)
      # The agent_fleet sub-supervisor wraps AgentSupervisor + AgentBoot.
      assert MapSet.member?(ids, {:agent_fleet, co})
      refute MapSet.member?(ids, Glorbo.Network.Proxy)
    end
  end

  describe "S1b: 11-child tree when a proxy agent is declared (GAP-4)" do
    test "CompanySupervisor starts 11 direct children when proxy?: true" do
      {sup_pid, _co, _base} = start_company(proxy?: true)
      children = Supervisor.which_children(sup_pid)
      assert length(children) == 11

      modules =
        children
        |> Enum.map(fn {_id, _pid, _type, mods} ->
          case mods do
            [mod] -> mod
            _ -> nil
          end
        end)
        |> Enum.filter(& &1)
        |> MapSet.new()

      assert MapSet.member?(modules, Glorbo.Network.Proxy)
      assert MapSet.member?(modules, Glorbo.Approvals.Gate)
    end
  end

  describe "S2: one_for_one isolation — single-child crash" do
    test "killing Router restarts only Router; siblings survive" do
      {sup_pid, _co, _base} = start_company()

      pids_by_id =
        Supervisor.which_children(sup_pid)
        |> Map.new(fn {id, pid, _type, _mod} -> {id, pid} end)

      router_pid = pids_by_id[Glorbo.Company.Router]
      watcher_pid = pids_by_id[Glorbo.Filesystem.Watcher]

      assert Process.alive?(router_pid)
      assert Process.alive?(watcher_pid)

      ref = Process.monitor(router_pid)
      Process.exit(router_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^router_pid, _}, 2_000

      # The supervisor restarts it; wait briefly for a new pid.
      Process.sleep(100)

      new_router =
        Supervisor.which_children(sup_pid)
        |> Enum.find_value(fn
          {Glorbo.Company.Router, pid, _, _} -> pid
          _ -> nil
        end)

      assert is_pid(new_router)
      assert new_router != router_pid
      assert Process.alive?(watcher_pid)
    end
  end

  describe "S3: inner AgentSupervisor restart stays scoped to the agent_fleet sub-tree" do
    test "killing inner AgentSupervisor triggers rest_for_one inside the fleet, leaves siblings alone" do
      {sup_pid, co, _base} = start_company()

      pids_by_id =
        Supervisor.which_children(sup_pid)
        |> Map.new(fn {id, pid, _type, _mod} -> {id, pid} end)

      fleet_id = {:agent_fleet, co}
      fleet_pid = pids_by_id[fleet_id]
      router_pid = pids_by_id[Glorbo.Company.Router]
      assert is_pid(fleet_pid)

      inner =
        Supervisor.which_children(fleet_pid)
        |> Map.new(fn {id, pid, _type, _mod} -> {id, pid} end)

      agent_sup_pid = inner[Glorbo.Company.AgentSupervisor]
      ref = Process.monitor(agent_sup_pid)
      Process.exit(agent_sup_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent_sup_pid, _}, 2_000

      Process.sleep(200)

      # Router (sibling at the company level) untouched.
      assert Process.alive?(router_pid)
      # Fleet supervisor itself still alive (same pid); only its inner
      # children restarted.
      assert Process.alive?(fleet_pid)

      new_inner =
        Supervisor.which_children(fleet_pid)
        |> Map.new(fn {id, pid, _type, _mod} -> {id, pid} end)

      new_agent_sup = new_inner[Glorbo.Company.AgentSupervisor]
      assert is_pid(new_agent_sup)
      assert new_agent_sup != agent_sup_pid
    end
  end

  # Regression for the codex-flagged CRITICAL: if AgentSupervisor
  # crashed under the old `:one_for_one` + one-shot `:transient`
  # AgentBoot, the company lost its entire agent fleet forever. The
  # new `:rest_for_one` `agent_fleet` sub-tree rebuilds both.
  describe "S4: AgentSupervisor crash triggers AgentBoot rerun (agent_fleet rest_for_one)" do
    test "killing inner AgentSupervisor forces AgentBoot to rerun (new pid)" do
      {sup_pid, co, _base} = start_company()

      fleet_id = {:agent_fleet, co}

      fleet_pid =
        Supervisor.which_children(sup_pid)
        |> Enum.find_value(fn
          {^fleet_id, pid, _, _} -> pid
          _ -> nil
        end)

      assert is_pid(fleet_pid)

      inner_children =
        Supervisor.which_children(fleet_pid)
        |> Map.new(fn {id, pid, _type, _mod} -> {id, pid} end)

      agent_sup_pid = inner_children[Glorbo.Company.AgentSupervisor]
      assert is_pid(agent_sup_pid)

      ref = Process.monitor(agent_sup_pid)
      Process.exit(agent_sup_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent_sup_pid, _}, 2_000

      Process.sleep(200)

      new_inner =
        Supervisor.which_children(fleet_pid)
        |> Map.new(fn {id, pid, _type, _mod} -> {id, pid} end)

      # Both children come back — AgentSupervisor with a fresh pid, and
      # AgentBoot re-runs from scratch (pid may or may not be alive at
      # check time depending on scan timing, but the child spec must be
      # present).
      new_agent_sup = new_inner[Glorbo.Company.AgentSupervisor]
      assert is_pid(new_agent_sup)
      assert new_agent_sup != agent_sup_pid

      # AgentBoot is registered as a child; pid may be :undefined if
      # the task already exited (it's one-shot, :transient), but the
      # id must appear in the supervisor.
      assert Map.has_key?(new_inner, Glorbo.Company.AgentBoot)
    end
  end

  describe "S5: cross-company isolation (AGT-01 company-granularity)" do
    test "killing one company's children doesn't affect another company's pids" do
      {sup_a, _co_a, _base} = start_company(company: "co-a-#{System.unique_integer([:positive])}")
      {sup_b, _co_b, _base} = start_company(company: "co-b-#{System.unique_integer([:positive])}")

      b_audit_pid =
        Supervisor.which_children(sup_b)
        |> Enum.find_value(fn
          {Glorbo.Company.AuditLog, pid, _, _} -> pid
          _ -> nil
        end)

      a_router_pid =
        Supervisor.which_children(sup_a)
        |> Enum.find_value(fn
          {Glorbo.Company.Router, pid, _, _} -> pid
          _ -> nil
        end)

      ref = Process.monitor(a_router_pid)
      Process.exit(a_router_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^a_router_pid, _}, 2_000

      # Company B's pids are unaffected.
      assert Process.alive?(b_audit_pid)
    end
  end

  # R19a (#283) — agent `network_allow:` frontmatter extends the
  # base proxy allowlist. Directors declare additional hosts an
  # agent needs (e.g. an ops dashboard) without patching the global
  # config.
  describe "per-agent network_allow extends proxy allowlist" do
    setup do
      base = Path.join(System.tmp_dir!(), "glorbo-netallow-#{System.unique_integer([:positive])}")
      company = "acme"
      File.mkdir_p!(Path.join([base, "companies", company, "agents/scout/state"]))

      on_exit(fn -> File.rm_rf!(base) end)
      {:ok, base: base, company: company}
    end

    defp seed_agent(base, company, slug, extra_opts) do
      File.mkdir_p!(Path.join([base, "companies", company, "agents", slug, "state"]))

      frontmatter = """
      slug: #{slug}
      role: Scout
      provider: claude-code
      network: proxy
      #{extra_opts}
      """

      File.write!(
        Path.join([base, "companies", company, "agents", slug, "AGENT.md"]),
        """
        ---
        #{frontmatter}---

        scout body
        """
      )
    end

    test "frontmatter `network_allow:` hosts added to the allowlist",
         %{base: base, company: company} do
      seed_agent(base, company, "scout", """
      network_allow:
        - grafana.internal
        - ops.example.com
      """)

      {:ok, sup_pid} =
        Glorbo.Company.Supervisor.start_link(
          name: Glorbo.Test.UniqueName.gen("company_allow_sup"),
          company: company,
          base: base,
          proxy?: true
        )

      on_exit(fn ->
        if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid, :shutdown)
      end)

      # Find the Network.Proxy and inspect its state.
      proxy_pid =
        sup_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {Glorbo.Network.Proxy, pid, _, _} -> pid
          _ -> nil
        end)

      assert is_pid(proxy_pid)

      state = :sys.get_state(proxy_pid)

      assert MapSet.member?(state.policy.allowlist, "grafana.internal"),
             "expected grafana.internal in #{inspect(MapSet.to_list(state.policy.allowlist))}"

      assert MapSet.member?(state.policy.allowlist, "ops.example.com")

      # Base allowlist still present — api.anthropic.com comes with claude-code.
      assert MapSet.member?(state.policy.allowlist, "api.anthropic.com")
    end

    test "invalid hosts silently filtered (empty strings, schemes, wildcards)",
         %{base: base, company: company} do
      seed_agent(base, company, "scout", """
      network_allow:
        - ""
        - "https://ok.example.com"
        - "*.wildcard.com"
        - "valid.example.com"
      """)

      {:ok, sup_pid} =
        Glorbo.Company.Supervisor.start_link(
          name: Glorbo.Test.UniqueName.gen("company_allow_invalid"),
          company: company,
          base: base,
          proxy?: true
        )

      on_exit(fn ->
        if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid, :shutdown)
      end)

      proxy_pid =
        sup_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {Glorbo.Network.Proxy, pid, _, _} -> pid
          _ -> nil
        end)

      state = :sys.get_state(proxy_pid)
      hosts = MapSet.to_list(state.policy.allowlist)

      assert "valid.example.com" in hosts
      refute "" in hosts
      refute "*.wildcard.com" in hosts
      refute "https://ok.example.com" in hosts
    end

    test "agent without `network_allow` inherits base allowlist only",
         %{base: base, company: company} do
      seed_agent(base, company, "scout", "")

      {:ok, sup_pid} =
        Glorbo.Company.Supervisor.start_link(
          name: Glorbo.Test.UniqueName.gen("company_allow_empty"),
          company: company,
          base: base,
          proxy?: true
        )

      on_exit(fn ->
        if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid, :shutdown)
      end)

      proxy_pid =
        sup_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {Glorbo.Network.Proxy, pid, _, _} -> pid
          _ -> nil
        end)

      state = :sys.get_state(proxy_pid)

      # Base still present.
      assert MapSet.member?(state.policy.allowlist, "api.anthropic.com")
    end

    test "multiple agents' network_allow unions into a single allowlist",
         %{base: base, company: company} do
      seed_agent(base, company, "scout", """
      network_allow:
        - grafana.internal
      """)

      seed_agent(base, company, "analyst", """
      network_allow:
        - datadog.example.com
      """)

      {:ok, sup_pid} =
        Glorbo.Company.Supervisor.start_link(
          name: Glorbo.Test.UniqueName.gen("company_allow_union"),
          company: company,
          base: base,
          proxy?: true
        )

      on_exit(fn ->
        if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid, :shutdown)
      end)

      proxy_pid =
        sup_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {Glorbo.Network.Proxy, pid, _, _} -> pid
          _ -> nil
        end)

      state = :sys.get_state(proxy_pid)

      assert MapSet.member?(state.policy.allowlist, "grafana.internal")
      assert MapSet.member?(state.policy.allowlist, "datadog.example.com")
    end

    # GEP-23 smart-mode Phase 3 (#321). Supervisor composes a
    # classifier_fun from agents' `egress:` blocks; nil when no
    # agent opts into :strict or :smart mode.
    test "no agent opts into smart-mode → proxy classifier_fun is nil",
         %{base: base, company: company} do
      seed_agent(base, company, "scout", "")

      {:ok, sup_pid} =
        Glorbo.Company.Supervisor.start_link(
          name: Glorbo.Test.UniqueName.gen("company_no_smart"),
          company: company,
          base: base,
          proxy?: true
        )

      on_exit(fn ->
        if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid, :shutdown)
      end)

      proxy_pid =
        sup_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {Glorbo.Network.Proxy, pid, _, _} -> pid
          _ -> nil
        end)

      state = :sys.get_state(proxy_pid)
      assert is_nil(state.policy.classifier_fun)
    end

    test "smart-mode agent wires classifier_fun that honours its egress block",
         %{base: base, company: company} do
      seed_agent(base, company, "researcher", """
      egress:
        mode: smart
        allow:
          - docs.python.org
        deny:
          - ads.tracker.example.com
        smart_allow: language documentation
        smart_deny: gambling, banking
      """)

      {:ok, sup_pid} =
        Glorbo.Company.Supervisor.start_link(
          name: Glorbo.Test.UniqueName.gen("company_smart"),
          company: company,
          base: base,
          proxy?: true
        )

      on_exit(fn ->
        if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid, :shutdown)
      end)

      proxy_pid =
        sup_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {Glorbo.Network.Proxy, pid, _, _} -> pid
          _ -> nil
        end)

      state = :sys.get_state(proxy_pid)
      classifier = state.policy.classifier_fun
      assert is_function(classifier, 2)

      # Exact allow list hit → :allow
      assert {:allow, :allowlist} = classifier.("docs.python.org", 443)

      # Exact deny list hit → :deny
      assert {:deny, :denylist} = classifier.("ads.tracker.example.com", 443)

      # Unknown host + smart mode + stub LLM classifier returns
      # :unknown → :unknown verdict. (Phase 3 keeps the stub;
      # Phase 4 swaps in a real LLM dispatch.)
      assert {:unknown, :smart_unknown} = classifier.("mystery.example.com", 443)
    end

    test "strict-mode agent also wires a classifier (returns :unknown instead of calling LLM)",
         %{base: base, company: company} do
      seed_agent(base, company, "auditor", """
      egress:
        mode: strict
        allow:
          - audit.example.com
      """)

      {:ok, sup_pid} =
        Glorbo.Company.Supervisor.start_link(
          name: Glorbo.Test.UniqueName.gen("company_strict"),
          company: company,
          base: base,
          proxy?: true
        )

      on_exit(fn ->
        if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid, :shutdown)
      end)

      proxy_pid =
        sup_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {Glorbo.Network.Proxy, pid, _, _} -> pid
          _ -> nil
        end)

      state = :sys.get_state(proxy_pid)
      classifier = state.policy.classifier_fun
      assert is_function(classifier, 2)

      assert {:allow, :allowlist} = classifier.("audit.example.com", 443)
      # Strict mode: unknown host never reaches LLM, returns
      # :unknown → proxy sends 403 (director-sentinel path is
      # Phase 4).
      assert {:unknown, :no_rule_match} = classifier.("unknown.example.com", 443)
    end
  end
end
