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

  describe "S1: 11-child base tree (incl. TaskScheduler; Plan 03-05 + Approvals.Gate + PathRequestGate + ProposalsSink + AgentBoot)" do
    test "CompanySupervisor starts 11 children by default (no api-only agents → no Proxy)" do
      {sup_pid, _co, _base} = start_company()
      children = Supervisor.which_children(sup_pid)
      assert length(children) == 11

      modules =
        children
        |> Enum.map(fn {_id, _pid, _type, [mod]} -> mod end)
        |> MapSet.new()

      assert MapSet.member?(modules, Glorbo.Company.AuditLog)
      assert MapSet.member?(modules, Glorbo.Filesystem.Watcher)
      assert MapSet.member?(modules, Glorbo.Company.Router)
      assert MapSet.member?(modules, Glorbo.Company.Scheduler)
      assert MapSet.member?(modules, Glorbo.Company.TaskScheduler)
      assert MapSet.member?(modules, Glorbo.Company.BudgetTracker)
      assert MapSet.member?(modules, Glorbo.Company.AgentSupervisor)
      assert MapSet.member?(modules, Glorbo.Approvals.Gate)
      assert MapSet.member?(modules, Glorbo.PathRequestGate)
      assert MapSet.member?(modules, Glorbo.Company.ProposalsSink)
      assert MapSet.member?(modules, Glorbo.Company.AgentBoot)
      # GAP-4: no api-only agent on disk → Network.Proxy is NOT started
      refute MapSet.member?(modules, Glorbo.Network.Proxy)
    end
  end

  describe "S1b: 12-child tree when an api-only agent is declared (GAP-4)" do
    test "CompanySupervisor starts 12 children when api_only?: true" do
      {sup_pid, _co, _base} = start_company(api_only?: true)
      children = Supervisor.which_children(sup_pid)
      assert length(children) == 12

      modules =
        children
        |> Enum.map(fn {_id, _pid, _type, [mod]} -> mod end)
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

  describe "S3: AgentSupervisor restart isolation" do
    test "killing AgentSupervisor restarts only it; siblings unaffected" do
      {sup_pid, _co, _base} = start_company()

      pids_by_id =
        Supervisor.which_children(sup_pid)
        |> Map.new(fn {id, pid, _type, _mod} -> {id, pid} end)

      agent_sup = pids_by_id[Glorbo.Company.AgentSupervisor]
      router_pid = pids_by_id[Glorbo.Company.Router]

      ref = Process.monitor(agent_sup)
      Process.exit(agent_sup, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent_sup, _}, 2_000

      Process.sleep(100)
      assert Process.alive?(router_pid)

      new_agent_sup =
        Supervisor.which_children(sup_pid)
        |> Enum.find_value(fn
          {Glorbo.Company.AgentSupervisor, pid, _, _} -> pid
          _ -> nil
        end)

      assert is_pid(new_agent_sup)
      assert new_agent_sup != agent_sup
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
      network: api-only
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
          api_only?: true
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
          api_only?: true
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
          api_only?: true
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
          api_only?: true
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
          api_only?: true
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
          api_only?: true
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
          api_only?: true
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
