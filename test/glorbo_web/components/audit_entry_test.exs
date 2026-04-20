defmodule GlorboWeb.Components.AuditEntryTest do
  @moduledoc """
  `GlorboWeb.Components.AuditEntry.audit_entry/1` sentence renderer
  (PLAN P2-3 — paperclip-ux-gaps §10).
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias GlorboWeb.Components.AuditEntry

  defp render_row(entry) do
    assigns = %{entry: entry, expanded: false, id: "row-1"}

    rendered_to_string(~H"""
    <AuditEntry.audit_entry entry={@entry} expanded={@expanded} id={@id} />
    """)
  end

  test "task.create → `<actor> created <target>`" do
    html =
      render_row(%{
        "ts" => "2026-04-20T10:00:00Z",
        "actor" => "director",
        "action" => "task.create",
        "target" => "projects/blog/tasks/blog-1.md"
      })

    assert html =~ "director created projects/blog/tasks/blog-1.md"
  end

  test "task.comment → `<actor> commented on <target>`" do
    html =
      render_row(%{
        "ts" => "2026-04-20T10:00:00Z",
        "actor" => "ceo",
        "action" => "task.comment",
        "target" => "blog-1"
      })

    assert html =~ "ceo commented on blog-1"
  end

  test "agent.dispatch → `<actor> dispatched <task> (<trigger>)`" do
    html =
      render_row(%{
        "ts" => "2026-04-20T10:00:00Z",
        "actor" => "system",
        "action" => "agent.dispatch",
        "target" => "projects/blog/tasks/blog-1.md",
        "detail" => %{"trigger" => "heartbeat"}
      })

    assert html =~ "system dispatched"
    assert html =~ "heartbeat"
  end

  test "agent.complete → `<actor> finished cleanly in <Ns>`" do
    html =
      render_row(%{
        "ts" => "2026-04-20T10:00:42Z",
        "actor" => "ceo",
        "action" => "agent.complete",
        "target" => "projects/blog/tasks/blog-1.md",
        "detail" => %{"exit_status" => "0", "duration_ms" => 42_000}
      })

    assert html =~ "ceo finished cleanly"
    assert html =~ "42s"
  end

  test "agent.complete with non-zero exit → `finished exit=<N>`" do
    html =
      render_row(%{
        "ts" => "2026-04-20T10:00:00Z",
        "actor" => "ceo",
        "action" => "agent.complete",
        "target" => "x",
        "detail" => %{"exit_status" => "2"}
      })

    assert html =~ "finished exit=2"
  end

  test "task.update with status delta → `changed status from X to Y`" do
    html =
      render_row(%{
        "ts" => "2026-04-20T10:00:00Z",
        "actor" => "director",
        "action" => "task.update",
        "target" => "blog-1",
        "detail" => %{"status_from" => "todo", "status_to" => "done"}
      })

    assert html =~ "changed status from todo to done on blog-1"
  end

  test "unknown action falls back to `<action> <target>` without crashing" do
    html =
      render_row(%{
        "ts" => "2026-04-20T10:00:00Z",
        "actor" => "system",
        "action" => "some.weird.event",
        "target" => "whatever"
      })

    assert html =~ "system some.weird.event whatever"
  end
end
