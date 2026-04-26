defmodule Glorbo.Shell.RuntimeTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Runtime

  defp start_runtime(opts \\ []) do
    name = Glorbo.Test.UniqueName.gen("shell_runtime")
    {:ok, pid} = Runtime.start_link(Keyword.put(opts, :name, name))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, name}
  end

  test "init returns empty events + count = 0" do
    {_pid, name} = start_runtime()
    state = Runtime.state(name)
    assert state.events == []
    assert state.event_count == 0
  end

  test "cast {:shell_event, _} accumulates onto events list and increments count" do
    {_pid, name} = start_runtime()

    GenServer.cast(name, {:shell_event, {:audit_append, %{action: "task.create"}}})
    GenServer.cast(name, {:shell_event, {:approval_requested, "x"}})

    # Sync round-trip via state/1 to flush both casts.
    state = Runtime.state(name)
    assert state.event_count == 2
    assert length(state.events) == 2
    # Most-recent first.
    assert hd(state.events) == {:approval_requested, "x"}
  end

  test "events list is capped at @max_events (256)" do
    {_pid, name} = start_runtime()

    Enum.each(1..300, fn i ->
      GenServer.cast(name, {:shell_event, {:tick, i}})
    end)

    state = Runtime.state(name)
    assert state.event_count == 300
    assert length(state.events) == 256
    # Most-recent (highest tick) preserved at the head.
    assert hd(state.events) == {:tick, 300}
    # Oldest 44 events evicted; tick=45 is the oldest still present.
    assert List.last(state.events) == {:tick, 45}
  end
end
