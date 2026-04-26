defmodule Glorbo.Shell.EventBusTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.{EventBus, Runtime}

  defp start_pair(opts \\ []) do
    runtime_name = Glorbo.Test.UniqueName.gen("ebus_runtime")
    {:ok, runtime_pid} = Runtime.start_link(name: runtime_name)
    on_exit(fn -> if Process.alive?(runtime_pid), do: GenServer.stop(runtime_pid) end)

    eventbus_name = Glorbo.Test.UniqueName.gen("ebus")

    {:ok, ebus_pid} =
      EventBus.start_link(
        Keyword.merge(
          [
            name: eventbus_name,
            runtime: runtime_name,
            companies: ["acme", "beta"]
          ],
          opts
        )
      )

    on_exit(fn -> if Process.alive?(ebus_pid), do: GenServer.stop(ebus_pid) end)

    %{runtime: runtime_name, eventbus: eventbus_name, ebus_pid: ebus_pid}
  end

  test "subscribes to per-company topics for every company in the roster" do
    %{eventbus: ebus} = start_pair()

    # Broadcast to a per-company topic; EventBus should forward to Runtime.
    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:audit",
      {:audit_append, %{action: "task.create"}}
    )

    state = :sys.get_state(Process.whereis(ebus))
    # Sync via :sys.get_state — handle_info is processed before the call returns.
    assert state.forwarded == 1
  end

  test "forwards each PubSub event to Runtime as {:shell_event, raw_msg}" do
    %{runtime: rt, eventbus: eb} = start_pair()

    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:approvals",
      {:approval_requested, "projects/x/tasks/x.md"}
    )

    # PubSub is async; flush EventBus's mailbox first, then Runtime's.
    _ = :sys.get_state(Process.whereis(eb))
    state = Runtime.state(rt)
    assert state.event_count == 1
    assert hd(state.events) == {:approval_requested, "projects/x/tasks/x.md"}
  end

  test "global topics (`glorbo:companies`) are subscribed regardless of roster" do
    %{runtime: rt, eventbus: eb} = start_pair(companies: [])

    Phoenix.PubSub.broadcast(Glorbo.PubSub, "glorbo:companies", {:company_created, "delta"})

    _ = :sys.get_state(Process.whereis(eb))
    state = Runtime.state(rt)
    assert state.event_count == 1
  end

  test "drops events when the runtime is no longer alive (no crash)" do
    runtime_name = Glorbo.Test.UniqueName.gen("ebus_runtime_dead")
    {:ok, runtime_pid} = Runtime.start_link(name: runtime_name)

    eventbus_name = Glorbo.Test.UniqueName.gen("ebus_after_dead")

    {:ok, ebus_pid} =
      EventBus.start_link(
        name: eventbus_name,
        runtime: runtime_name,
        companies: ["acme"]
      )

    on_exit(fn -> if Process.alive?(ebus_pid), do: GenServer.stop(ebus_pid) end)

    # Kill Runtime first; EventBus stays up.
    GenServer.stop(runtime_pid)
    refute Process.whereis(runtime_name)

    # PubSub broadcast — EventBus receives, sees Runtime is gone, drops.
    Phoenix.PubSub.broadcast(Glorbo.PubSub, "company:acme:audit", {:tick, 1})

    # EventBus must still be alive; forwarded count stays zero (dropped).
    assert Process.alive?(ebus_pid)
    state = :sys.get_state(ebus_pid)
    assert state.forwarded == 0
  end
end
