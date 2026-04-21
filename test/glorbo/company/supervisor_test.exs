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

  describe "S1: 9-child base tree (incl. TaskScheduler; Plan 03-05 + Approvals.Gate + AgentBoot)" do
    test "CompanySupervisor starts 9 children by default (no api-only agents → no Proxy)" do
      {sup_pid, _co, _base} = start_company()
      children = Supervisor.which_children(sup_pid)
      assert length(children) == 9

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
      assert MapSet.member?(modules, Glorbo.Company.AgentBoot)
      # GAP-4: no api-only agent on disk → Network.Proxy is NOT started
      refute MapSet.member?(modules, Glorbo.Network.Proxy)
    end
  end

  describe "S1b: 10-child tree when an api-only agent is declared (GAP-4)" do
    test "CompanySupervisor starts 10 children when api_only?: true" do
      {sup_pid, _co, _base} = start_company(api_only?: true)
      children = Supervisor.which_children(sup_pid)
      assert length(children) == 10

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
  end
end
