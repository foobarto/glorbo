defmodule Glorbo.ApplicationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Asserts the OTP supervision tree shape DESIGN.md §4.1 requires.

  In Phase 1 the tree is all stubs, but every branch must be addressable by
  name so later phases can reach into them without renaming.
  """

  test "Glorbo.Application supervision tree starts cleanly" do
    for mod <- [
          Glorbo.Repo,
          Glorbo.CompanySupervisor,
          GlorboWeb.Endpoint,
          Glorbo.PubSub,
          GlorboWeb.Telemetry
        ] do
      pid = Process.whereis(mod)

      assert is_pid(pid),
             "Expected #{inspect(mod)} to be a live pid at boot, got #{inspect(pid)}"

      assert Process.alive?(pid)
    end
  end

  test "Glorbo.CompanySupervisor has no uninitialised specs" do
    # Any company supervisors running here are started by sibling tests
    # (LiveView mount, phase integration); DynamicSupervisor children are
    # all `supervisors` — assert that shape rather than demanding emptiness,
    # which is fragile under test ordering.
    counts = DynamicSupervisor.count_children(Glorbo.CompanySupervisor)
    assert counts.active == counts.supervisors
    assert counts.workers == 0
  end

  @tag :inotify
  test "a company supervisor can be started under Glorbo.CompanySupervisor" do
    # Current child shape: AuditLog, Watcher, Router, Scheduler,
    # TaskScheduler, BudgetTracker, AgentSupervisor, Approvals.Gate,
    # PathRequestGate, ProposalsSink, AgentBoot = 11 children.
    # Network.Proxy only joins when an proxy agent is on disk
    # (GAP-4); smoke_test has none → 11, not 12.
    base = Path.join(System.tmp_dir!(), "glorbo_app_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([base, "companies", "smoke_test"]))
    on_exit(fn -> File.rm_rf!(base) end)

    spec =
      {Glorbo.Company.Supervisor,
       [company: "smoke_test", base: base, name: :smoke_test_company_sup]}

    assert {:ok, pid} = DynamicSupervisor.start_child(Glorbo.CompanySupervisor, spec)

    children = Supervisor.which_children(pid)
    assert length(children) == 11

    ids =
      children
      |> Enum.map(fn {id, _, _, _} -> id end)
      |> MapSet.new()

    for expected <- [
          Glorbo.Company.AuditLog,
          Glorbo.Filesystem.Watcher,
          Glorbo.Company.Router,
          Glorbo.Company.Scheduler,
          Glorbo.Company.TaskScheduler,
          Glorbo.Company.BudgetTracker,
          Glorbo.Company.AgentSupervisor,
          Glorbo.Approvals.Gate,
          Glorbo.PathRequestGate,
          Glorbo.Company.ProposalsSink,
          Glorbo.Company.AgentBoot
        ] do
      assert MapSet.member?(ids, expected), "missing child #{inspect(expected)}"
    end

    DynamicSupervisor.terminate_child(Glorbo.CompanySupervisor, pid)
  end
end
