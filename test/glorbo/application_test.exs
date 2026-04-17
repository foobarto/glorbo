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

  test "Glorbo.CompanySupervisor starts empty" do
    assert DynamicSupervisor.count_children(Glorbo.CompanySupervisor) ==
             %{active: 0, specs: 0, supervisors: 0, workers: 0}
  end

  @tag :inotify
  test "a company supervisor can be started under Glorbo.CompanySupervisor with Phase-2 children (AuditLog + Watcher)" do
    # Phase 2 Plan 04 (B5): Company.Supervisor starts ONLY AuditLog + Watcher.
    # Router/Scheduler/BudgetTracker are Phase-1 stubs that will join the
    # child list in Phase 3. Keeping them out of Phase 2 preserves the
    # CLAUDE.md crash-isolation invariant and avoids parking empty stubs in
    # a running supervision tree.
    base = Path.join(System.tmp_dir!(), "glorbo_app_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([base, "companies", "smoke_test"]))
    on_exit(fn -> File.rm_rf!(base) end)

    spec =
      {Glorbo.Company.Supervisor,
       [company: "smoke_test", base: base, name: :smoke_test_company_sup]}

    assert {:ok, pid} = DynamicSupervisor.start_child(Glorbo.CompanySupervisor, spec)

    children = Supervisor.which_children(pid)
    assert length(children) == 2

    ids =
      children
      |> Enum.map(fn {id, _, _, _} -> id end)
      |> Enum.sort()

    expected = [
      Glorbo.Company.AuditLog,
      Glorbo.Filesystem.Watcher
    ]

    assert ids == expected

    DynamicSupervisor.terminate_child(Glorbo.CompanySupervisor, pid)
  end
end
