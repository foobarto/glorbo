defmodule Glorbo.Shell.SupervisorTest do
  use ExUnit.Case, async: false

  alias Glorbo.Shell.Runtime
  alias Glorbo.Shell.Supervisor, as: ShellSupervisor

  defp start_tree(extra_opts \\ []) do
    sup_name = Glorbo.Test.UniqueName.gen("shell_sup")
    runtime_name = Glorbo.Test.UniqueName.gen("shell_sup_runtime")
    eventbus_name = Glorbo.Test.UniqueName.gen("shell_sup_eventbus")

    opts =
      Keyword.merge(
        [
          name: sup_name,
          runtime_name: runtime_name,
          eventbus_name: eventbus_name,
          eventbus_opts: [companies: ["acme"]]
        ],
        extra_opts
      )

    {:ok, sup_pid} = ShellSupervisor.start_link(opts)

    on_exit(fn ->
      if Process.alive?(sup_pid), do: Process.exit(sup_pid, :shutdown)
    end)

    %{
      sup: sup_pid,
      sup_name: sup_name,
      runtime: runtime_name,
      eventbus: eventbus_name
    }
  end

  test "start_link launches both children alive" do
    %{runtime: rt, eventbus: eb} = start_tree()

    assert Process.whereis(rt) |> Process.alive?()
    assert Process.whereis(eb) |> Process.alive?()
  end

  test "supervisor child spec count is exactly 2 (EventBus + Runtime)" do
    %{sup_name: sup} = start_tree()

    children = Supervisor.which_children(sup)
    assert length(children) == 2

    ids = Enum.map(children, fn {id, _, _, _} -> id end) |> Enum.sort()
    assert ids == [Glorbo.Shell.EventBus, Glorbo.Shell.Runtime]
  end

  test "rest_for_one: killing Runtime alone restarts only Runtime" do
    %{runtime: rt, eventbus: eb} = start_tree()

    eb_pid_before = Process.whereis(eb)
    rt_pid_before = Process.whereis(rt)

    # Kill Runtime; supervisor restarts it under :rest_for_one (Runtime
    # is the LAST child, so nothing downstream is affected).
    Process.exit(rt_pid_before, :kill)

    # Wait for restart — Process.whereis returns the new pid.
    Process.sleep(50)

    rt_pid_after = Process.whereis(rt)
    assert rt_pid_after != nil
    assert rt_pid_after != rt_pid_before

    # EventBus stayed up — its pid is unchanged.
    assert Process.whereis(eb) == eb_pid_before
  end

  test "rest_for_one: killing EventBus restarts both EventBus and Runtime" do
    %{runtime: rt, eventbus: eb} = start_tree()

    eb_pid_before = Process.whereis(eb)
    rt_pid_before = Process.whereis(rt)

    # Kill EventBus — :rest_for_one restarts everything from EventBus
    # onward, which includes Runtime.
    Process.exit(eb_pid_before, :kill)
    Process.sleep(50)

    eb_pid_after = Process.whereis(eb)
    rt_pid_after = Process.whereis(rt)

    assert eb_pid_after != nil and eb_pid_after != eb_pid_before
    assert rt_pid_after != nil and rt_pid_after != rt_pid_before
  end

  test "PubSub broadcast → EventBus → Runtime end-to-end through the supervised tree" do
    %{runtime: rt, eventbus: eb} = start_tree()

    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:projects",
      {:projects_updated, "demo"}
    )

    # Async PubSub — flush EventBus's mailbox before reading Runtime.
    _ = :sys.get_state(Process.whereis(eb))
    state = Runtime.state(rt)
    assert state.event_count == 1
    assert hd(state.events) == {:projects_updated, "demo"}
  end
end
