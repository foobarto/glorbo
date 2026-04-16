defmodule GlorboWeb.KanbanRealtimeTest do
  @moduledoc """
  Plan 04-02 Task 2 — UI-02 sub-second real-time verification.

  Writes a new task file to the seeded company and asserts the
  KanbanLive view renders it within 1.5s of the filesystem event
  propagating through the Phase 3 Watcher → PubSub → LiveView
  pipeline.

  Tagged `:integration` because it boots a per-company supervision
  tree (AuditLog + Watcher + Gate …) via `start_supervised!`. The
  LiveCase setup provides an isolated base dir.
  """
  use GlorboWeb.LiveCase, async: false

  # `:integration` follows Phase 3/Wave 0 convention for tests that boot
  # the per-company supervision tree. `:inotify` is required because the
  # Watcher refuses to start without `inotify-tools`. Both tags are
  # excluded by default in `test_helper.exs`; CI enables them on hosts
  # with inotify installed.
  @moduletag :integration
  @moduletag :inotify

  setup %{base: base} do
    start_supervised!(
      {Glorbo.Company.Supervisor,
       [
         name: :"acme_kanban_sup_#{System.unique_integer([:positive])}",
         company: "acme",
         base: base
       ]}
    )

    :ok
  end

  test "new task file propagates to kanban within 1.5s", %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme/kanban")
    refute render(view) =~ "Fix navbar"

    task_path =
      Path.join([base, "companies", "acme", "projects", "website", "tasks", "t-02.md"])

    File.write!(task_path, """
    ---
    title: "Fix navbar"
    status: in-progress
    assigned_to: ceo
    ---

    Fix the navbar dropdowns.
    """)

    started = System.monotonic_time(:millisecond)

    assert wait_until(1_500, fn -> render(view) =~ "Fix navbar" end),
           "task did not propagate to kanban within 1500ms " <>
             "(elapsed #{System.monotonic_time(:millisecond) - started}ms)"
  end

  defp wait_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(50)
        do_wait_until(deadline, fun)
    end
  end
end
