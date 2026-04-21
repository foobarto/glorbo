defmodule GlorboWeb.TaskLiveTest do
  @moduledoc """
  `GlorboWeb.TaskLive` — `/companies/:company/tasks/:task_id`.

  Covers happy-path render, invalid task-id shape, missing task
  file, and the comment post.
  """
  use GlorboWeb.LiveCase, async: false

  setup %{base: base} do
    # Seed one project + one task so TaskLive has real data to load.
    tasks_dir = Path.join([base, "companies/acme/projects/foo/tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([base, "companies/acme/projects/foo/project.md"]), """
    ---
    slug: foo
    name: foo
    ---
    # foo
    """)

    File.write!(Path.join(tasks_dir, "foo-1.md"), """
    ---
    title: hello task
    assigned_to: ceo
    status: todo
    priority: high
    ---

    original prompt body

    ## 2026-04-20T10:00:00Z | director
    first comment
    """)

    :ok
  end

  test "renders task detail with prompt + comments", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-1")
    assert html =~ "foo-1"
    assert html =~ "hello task"
    assert html =~ "original prompt body"
    assert html =~ "first comment"
    assert html =~ "← back to kanban"
  end

  test "redirects on invalid task-id shape", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies/acme"}}} =
             live(conn, "/companies/acme/tasks/bogus")
  end

  test "redirects when task file doesn't exist", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies/acme/kanban"}}} =
             live(conn, "/companies/acme/tasks/ghost-1")
  end

  test "empty comment flashes error", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/tasks/foo-1")
    html = render_submit(view, "comment_task", %{"comment" => ""})
    assert html =~ "Comment is empty"
  end

  test "valid comment appends to task body", %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/tasks/foo-1")
    render_submit(view, "comment_task", %{"comment" => "ping"})

    path = Path.join([base, "companies/acme/projects/foo/tasks/foo-1.md"])
    content = File.read!(path)
    assert content =~ "ping"
    assert content =~ "| director"
  end

  test "save_task rewrites frontmatter via shared TaskDetailForm",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/tasks/foo-1")

    render_submit(view, "save_task", %{
      "title" => "renamed task",
      "status" => "in-progress",
      "assigned_to" => "ceo",
      "priority" => "low",
      "severity" => ""
    })

    path = Path.join([base, "companies/acme/projects/foo/tasks/foo-1.md"])
    content = File.read!(path)
    assert content =~ ~r/title: "?renamed task"?/
    assert content =~ "status: in-progress"
    assert content =~ "priority: low"
  end

  test "delete_task moves file to history/deleted/",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/tasks/foo-1")

    assert {:error, {:live_redirect, %{to: "/companies/acme/kanban"}}} =
             render_click(view, "delete_task", %{
               "path" => "projects/foo/tasks/foo-1.md"
             })

    refute File.exists?(Path.join([base, "companies/acme/projects/foo/tasks/foo-1.md"]))

    deleted =
      [base, "companies/acme/projects/foo/history/deleted"]
      |> Path.join()
      |> File.ls!()
      |> Enum.filter(&String.contains?(&1, "foo-1.md"))

    assert deleted != []
  end

  # #252 — TaskLive renders a usage strip showing aggregated
  # tokens + cost + dispatch count for this task across the
  # current month's audit.
  describe "usage totals (#252)" do
    setup %{base: base} do
      audit_dir = Path.join([base, "companies/acme/audit"])
      File.mkdir_p!(audit_dir)

      month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
      path = Path.join(audit_dir, "#{month}.jsonl")

      lines = [
        %{
          "action" => "agent.complete",
          "target" => "projects/foo/tasks/foo-1.md",
          "detail" => %{
            "prompt_tokens" => 100,
            "completion_tokens" => 50,
            "cost_usd_cents" => 25
          }
        },
        %{
          "action" => "agent.complete",
          "target" => "projects/foo/tasks/foo-1.md",
          "detail" => %{
            "prompt_tokens" => 200,
            "completion_tokens" => 80,
            "cost_usd_cents" => 44
          }
        },
        # Different task — should NOT count.
        %{
          "action" => "agent.complete",
          "target" => "projects/foo/tasks/other-1.md",
          "detail" => %{
            "prompt_tokens" => 999,
            "completion_tokens" => 999,
            "cost_usd_cents" => 999
          }
        }
      ]

      content = Enum.map_join(lines, "\n", &Jason.encode!/1)
      File.write!(path, content <> "\n")
      :ok
    end

    test "sums tokens + cost for matching target", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-1")
      assert html =~ "dispatches"
      assert html =~ "tokens"
      assert html =~ "cost"
      # Aggregated: 300 in, 130 out, $0.69 (69 cents).
      assert html =~ "300 in / 130 out"
      assert html =~ "0.69"
      # Dispatch count should be 2.
      assert html =~ ">2<"
    end
  end

  test "renders usage strip with zeros when no audit entries",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-1")
    assert html =~ "dispatches"
    assert html =~ "0 in / 0 out"
    assert html =~ "—"
  end

  # #264 — task-scoped history panel reading from Audit.Query.for_task/4.
  describe "history panel (#264)" do
    setup %{base: base} do
      audit_dir = Path.join([base, "companies/acme/audit"])
      File.mkdir_p!(audit_dir)

      month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
      path = Path.join(audit_dir, "#{month}.jsonl")

      lines = [
        %{
          "ts" => "2026-04-20T09:00:00Z",
          "actor" => "ceo",
          "action" => "agent.dispatch",
          "target" => "projects/foo/tasks/foo-1.md",
          "detail" => %{"prompt" => "go do the thing"}
        },
        %{
          "ts" => "2026-04-20T09:05:00Z",
          "actor" => "ceo",
          "action" => "agent.complete",
          "target" => "projects/foo/tasks/foo-1.md",
          "detail" => %{"prompt_tokens" => 100, "completion_tokens" => 50}
        },
        # Different task — must NOT appear in the panel.
        %{
          "ts" => "2026-04-20T10:00:00Z",
          "actor" => "editor",
          "action" => "agent.dispatch",
          "target" => "projects/foo/tasks/other-1.md",
          "detail" => %{}
        }
      ]

      File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
      :ok
    end

    test "renders history entries for this task only", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-1")
      assert html =~ "history · this task"
      assert html =~ "agent.dispatch"
      assert html =~ "agent.complete"
      # Other task's row must not appear.
      refute html =~ "other-1"
      # Deep-link to AuditLive carries ?q= task id.
      assert html =~ ~s(/companies/acme/audit?q=foo-1)
    end

    test "shows empty state when no audit entries for this task",
         %{conn: conn, base: base} do
      # Clear the audit for the second task so the panel is empty.
      audit_dir = Path.join([base, "companies/acme/audit"])
      month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
      File.rm!(Path.join(audit_dir, "#{month}.jsonl"))

      {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-1")
      assert html =~ "No audit events yet for this task"
    end
  end

  # GEP-24 — TaskLive renders a "schedule · ↻ <cron>" row on the
  # usage strip for recurring tasks. The scheduler isn't running in
  # the test harness so the "next fire" suffix is absent; we just
  # check the row itself appears.
  describe "scheduled-task indicator (#268, GEP-24)" do
    setup %{base: base} do
      tasks_dir = Path.join([base, "companies/acme/projects/foo/tasks"])

      File.write!(Path.join(tasks_dir, "foo-1.md"), """
      ---
      title: recurring task
      assigned_to: ceo
      status: todo
      schedule: "0 * * * *"
      ---

      hourly body
      """)

      :ok
    end

    test "renders schedule row on the usage strip for recurring tasks",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-1")
      assert html =~ "schedule"
      assert html =~ "↻ 0 * * * *"
    end
  end

  # #274 — stuck-on sentinel surfaces on the task page with
  # retry/skip/stop affordances symmetric to InboxLive.
  describe "stuck-on sentinel (#274)" do
    setup %{base: base} do
      agent_state = Path.join([base, "companies/acme/agents/ceo/state"])
      File.mkdir_p!(agent_state)

      File.write!(Path.join(agent_state, "stuck-on-foo-1.md"), """
      ---
      task_path: projects/foo/tasks/foo-1.md
      agent: ceo
      detected_at: "2026-04-21T04:00:00Z"
      reason: "3 identical outputs in 5m window"
      ---

      stuck body
      """)

      :ok
    end

    test "renders stuck banner with retry/skip/stop actions for this task",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-1")
      assert html =~ "stuck on this task"
      assert html =~ "ceo"
      assert html =~ "3 identical outputs"
      # Three action buttons wired to stuck_resolve with distinct decisions.
      assert html =~ ~s(phx-value-decision="retry")
      assert html =~ ~s(phx-value-decision="skip")
      assert html =~ ~s(phx-value-decision="stop")
    end

    test "retry deletes the sentinel and refreshes the banner",
         %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, ~p"/companies/acme/tasks/foo-1")

      html =
        render_click(view, "stuck_resolve", %{
          "decision" => "retry",
          "sentinel_path" => "agents/ceo/state/stuck-on-foo-1.md"
        })

      refute html =~ "stuck on this task"
      refute File.exists?(Path.join([base, "companies/acme/agents/ceo/state/stuck-on-foo-1.md"]))
    end

    test "skip reassigns the task to director and clears the sentinel",
         %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, ~p"/companies/acme/tasks/foo-1")

      render_click(view, "stuck_resolve", %{
        "decision" => "skip",
        "sentinel_path" => "agents/ceo/state/stuck-on-foo-1.md"
      })

      task_md = File.read!(Path.join([base, "companies/acme/projects/foo/tasks/foo-1.md"]))
      assert task_md =~ "assigned_to: director"
      refute File.exists?(Path.join([base, "companies/acme/agents/ceo/state/stuck-on-foo-1.md"]))
    end

    test "stop marks the task denied and clears the sentinel",
         %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, ~p"/companies/acme/tasks/foo-1")

      render_click(view, "stuck_resolve", %{
        "decision" => "stop",
        "sentinel_path" => "agents/ceo/state/stuck-on-foo-1.md"
      })

      task_md = File.read!(Path.join([base, "companies/acme/projects/foo/tasks/foo-1.md"]))
      assert task_md =~ "status: denied"
      refute File.exists?(Path.join([base, "companies/acme/agents/ceo/state/stuck-on-foo-1.md"]))
    end
  end

  # R12 (#276) E2E — task-ID autolinking in comments. Unit tests on
  # TaskDetailForm cover the render; this test rounds the trip by
  # asserting the TaskLive mount produces a live anchor the director
  # can click, and the kanban deep-link the anchor points at actually
  # opens the referenced task overlay.
  describe "task-ID autolink in comments (#276 E2E)" do
    setup %{base: base} do
      tasks_dir = Path.join([base, "companies/acme/projects/foo/tasks"])

      # Second task so foo-2 references are valid.
      File.write!(Path.join(tasks_dir, "foo-2.md"), """
      ---
      title: second task
      assigned_to: ceo
      status: todo
      ---

      body of foo-2
      """)

      # Append a comment on foo-1 that references foo-2.
      File.write!(
        Path.join(tasks_dir, "foo-1.md"),
        """
        ---
        title: first task
        assigned_to: ceo
        status: todo
        ---

        original prompt

        ## 2026-04-21T05:00:00Z | director
        please sync with foo-2 before starting
        """
      )

      :ok
    end

    test "TaskLive render shows a working anchor to the referenced task's kanban deep-link",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-1")

      # Anchor rendered with the expected class.
      assert html =~ ~s(<a class="gl-task-ref")
      # Target is the kanban deep-link that opens the referenced task overlay.
      assert html =~ ~s(href="/companies/acme/kanban?task=projects/foo/tasks/foo-2.md")
    end

    test "following the anchor's kanban deep-link resolves to a page that shows foo-2",
         %{conn: conn} do
      # Simulate clicking the autolink — mount kanban at the deep-link URL.
      {:ok, _view, html} =
        live(conn, "/companies/acme/kanban?task=projects/foo/tasks/foo-2.md")

      # Kanban renders the referenced task's overlay (open_task assign
      # populated from the ?task= deep-link param).
      assert html =~ "second task"
      assert html =~ "body of foo-2"
    end
  end
end
