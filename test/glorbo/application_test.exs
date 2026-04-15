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
          Glorbo.ContainerManager,
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

  test "Glorbo.CompanySupervisor starts empty" do
    assert DynamicSupervisor.count_children(Glorbo.CompanySupervisor) ==
             %{active: 0, specs: 0, supervisors: 0, workers: 0}
  end

  test "a company supervisor can be started under Glorbo.CompanySupervisor with all 5 per-company stubs" do
    spec =
      {Glorbo.Company.Supervisor, [company: :smoke_test, name: :smoke_test_company_sup]}

    assert {:ok, pid} = DynamicSupervisor.start_child(Glorbo.CompanySupervisor, spec)

    children = Supervisor.which_children(pid)
    assert length(children) == 5

    ids =
      children
      |> Enum.map(fn {id, _, _, _} -> id end)
      |> Enum.sort()

    expected = [
      Glorbo.Company.AuditLog,
      Glorbo.Company.BudgetTracker,
      Glorbo.Company.FileWatcher,
      Glorbo.Company.Router,
      Glorbo.Company.Scheduler
    ]

    assert ids == expected

    DynamicSupervisor.terminate_child(Glorbo.CompanySupervisor, pid)
  end
end
