defmodule GlorboWeb.InboxLiveTest do
  @moduledoc """
  `GlorboWeb.InboxLive` — `/companies/:company/inbox`.

  Covers tab switching, approval rendering, audit rendering, deny
  prompt modal.
  """
  use GlorboWeb.LiveCase, async: false

  setup %{base: base} do
    tasks_dir = Path.join([base, "companies/acme/projects/demo/tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([base, "companies/acme/projects/demo/project.md"]), """
    ---
    slug: demo
    name: demo
    ---
    """)

    File.write!(Path.join(tasks_dir, "demo-1.md"), """
    ---
    title: decide X
    status: pending
    assigned_to: ceo
    requires_approval: director
    ---
    prompt body
    """)

    agent_state = Path.join([base, "companies/acme/agents/ceo/state"])
    File.mkdir_p!(agent_state)
    File.write!(Path.join(agent_state, "awaiting-approval-demo-1.md"), "pending\n")

    :ok
  end

  test "renders Mine tab with pending approvals by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/inbox")
    assert html =~ "Inbox"
    assert html =~ "1 pending"
    assert html =~ "demo-1"
    assert html =~ "decide X"
    assert html =~ "approve"
    assert html =~ "deny"
  end

  test "?tab=recent shows audit stream", %{conn: conn, base: base} do
    month = DateTime.utc_now() |> Calendar.strftime("%Y-%m")
    audit_path = Path.join([base, "companies/acme/audit", "#{month}.jsonl"])
    File.mkdir_p!(Path.dirname(audit_path))

    File.write!(audit_path, """
    {"ts":"2026-04-20T10:00:00Z","actor":"director","action":"task.create","target":"projects/demo/tasks/demo-1.md"}
    {"ts":"2026-04-20T09:00:00Z","actor":"ceo","action":"stdout_line","target":"agents/ceo/stdout.log"}
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/inbox?tab=recent")
    assert html =~ "task.create"
    refute html =~ "stdout_line"
  end

  test "?tab=archive shows placeholder", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/inbox?tab=archive")
    assert html =~ "Archive is not wired yet"
  end

  test "deny_prompt opens the deny modal", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/inbox")

    html =
      render_click(view, "deny_prompt", %{"task_path" => "projects/demo/tasks/demo-1.md"})

    assert html =~ "Deny projects/demo/tasks/demo-1.md"
    assert html =~ "reason (optional)"
  end
end
