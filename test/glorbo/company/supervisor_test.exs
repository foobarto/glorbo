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
    _ = Registry.start_link(keys: :unique, name: Glorbo.Agent.Registry)

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

  describe "S1: 7-child base tree (6 Plan 03-05 + Approvals.Gate from GAP-5)" do
    test "CompanySupervisor starts 7 children by default (+ Approvals.Gate; no api-only agents → no Proxy)" do
      {sup_pid, _co, _base} = start_company()
      children = Supervisor.which_children(sup_pid)
      assert length(children) == 7

      modules =
        children
        |> Enum.map(fn {_id, _pid, _type, [mod]} -> mod end)
        |> MapSet.new()

      assert MapSet.member?(modules, Glorbo.Company.AuditLog)
      assert MapSet.member?(modules, Glorbo.Filesystem.Watcher)
      assert MapSet.member?(modules, Glorbo.Company.Router)
      assert MapSet.member?(modules, Glorbo.Company.Scheduler)
      assert MapSet.member?(modules, Glorbo.Company.BudgetTracker)
      assert MapSet.member?(modules, Glorbo.Company.AgentSupervisor)
      assert MapSet.member?(modules, Glorbo.Approvals.Gate)
      # GAP-4: no api-only agent on disk → Network.Proxy is NOT started
      refute MapSet.member?(modules, Glorbo.Network.Proxy)
    end
  end

  describe "S1b: 8-child tree when an api-only agent is declared (GAP-4)" do
    test "CompanySupervisor starts 8 children when api_only?: true" do
      {sup_pid, _co, _base} = start_company(api_only?: true)
      children = Supervisor.which_children(sup_pid)
      assert length(children) == 8

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
end
