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

  test "?tab=archive shows empty-state when nothing archived", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/inbox?tab=archive")
    assert html =~ "Nothing archived yet"
  end

  test "archiving an approval hides it from Mine and shows under Archive",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme/inbox")

    render_click(view, "archive", %{"key" => "approval:projects/demo/tasks/demo-1.md"})

    # Approval no longer visible on Mine
    html = render(view)
    refute html =~ "decide X"

    # Archive tab carries the approval + an unarchive button
    {:ok, _v2, archive_html} = live(conn, ~p"/companies/acme/inbox?tab=archive")
    assert archive_html =~ "decide X"
    assert archive_html =~ "unarchive"
  end

  test "unarchive restores an archived approval", %{conn: conn, base: base} do
    # Seed an archived entry directly to keep the test self-contained.
    :ok =
      Glorbo.Inbox.Archive.add(base, "acme", "approval:projects/demo/tasks/demo-1.md")

    {:ok, view, html} = live(conn, ~p"/companies/acme/inbox?tab=archive")
    assert html =~ "unarchive"

    render_click(view, "unarchive", %{"key" => "approval:projects/demo/tasks/demo-1.md"})

    {:ok, _v2, mine_html} = live(conn, ~p"/companies/acme/inbox")
    assert mine_html =~ "decide X"
  end

  test "deny_prompt opens the deny modal", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/inbox")

    html =
      render_click(view, "deny_prompt", %{"task_path" => "projects/demo/tasks/demo-1.md"})

    assert html =~ "Deny projects/demo/tasks/demo-1.md"
    assert html =~ "reason (optional)"
  end

  describe "stuck-on sentinels (LoopDetector)" do
    setup %{base: base} do
      state_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
      File.mkdir_p!(state_dir)

      File.write!(Path.join(state_dir, "stuck-on-demo-1.md"), """
      ---
      kind: loop_detected
      agent: ceo
      task_id: demo-1
      task_path: projects/demo/tasks/demo-1.md
      failure_count: 3
      first_failure_ts: 2026-04-21T10:00:00Z
      last_failure_ts: 2026-04-21T10:06:00Z
      ---
      stuck body
      """)

      :ok
    end

    test "Mine tab renders a stuck row with retry/skip/stop buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/inbox")
      assert html =~ "Stuck agents"
      assert html =~ "demo-1"
      assert html =~ "@ceo"
      assert html =~ "3 consecutive failures"
      assert html =~ "stuck_resolve"
      # Three distinct decision values should all appear.
      assert html =~ ~s(phx-value-decision="retry")
      assert html =~ ~s(phx-value-decision="skip")
      assert html =~ ~s(phx-value-decision="stop")
    end

    test "retry deletes the sentinel only", %{conn: conn, base: base} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/inbox")

      render_click(view, "stuck_resolve", %{
        "decision" => "retry",
        "sentinel_path" => "agents/ceo/state/stuck-on-demo-1.md"
      })

      refute File.exists?(Path.join([base, "companies/acme/agents/ceo/state/stuck-on-demo-1.md"]))
    end

    test "skip reassigns the task to director + deletes sentinel",
         %{conn: conn, base: base} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/inbox")

      render_click(view, "stuck_resolve", %{
        "decision" => "skip",
        "sentinel_path" => "agents/ceo/state/stuck-on-demo-1.md"
      })

      task_path = Path.join([base, "companies/acme/projects/demo/tasks/demo-1.md"])
      content = File.read!(task_path)
      assert content =~ "assigned_to: director"

      refute File.exists?(Path.join([base, "companies/acme/agents/ceo/state/stuck-on-demo-1.md"]))
    end

    test "stop marks task as denied + deletes sentinel",
         %{conn: conn, base: base} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/inbox")

      render_click(view, "stuck_resolve", %{
        "decision" => "stop",
        "sentinel_path" => "agents/ceo/state/stuck-on-demo-1.md"
      })

      task_path = Path.join([base, "companies/acme/projects/demo/tasks/demo-1.md"])
      content = File.read!(task_path)
      assert content =~ "status: denied"

      refute File.exists?(Path.join([base, "companies/acme/agents/ceo/state/stuck-on-demo-1.md"]))
    end
  end
end
