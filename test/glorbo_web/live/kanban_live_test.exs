defmodule GlorboWeb.KanbanLiveTest do
  @moduledoc """
  Plan 04-02 Task 2 — `GlorboWeb.KanbanLive`
  (/companies/:company/kanban).

  Happy-path assertions: exact 3-column header labels (D-23), the
  read-only banner, and rendering of the seeded `t-01` task with its
  lightning glyph (`requires_approval: director`).
  """
  use GlorboWeb.LiveCase, async: false

  test "renders four columns including review (task #115/#122)", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")
    assert html =~ "todo"
    assert html =~ "in progress"
    assert html =~ "review"
    assert html =~ "done"
    # M4.1: columns are now drop targets with the KanbanLane hook
    assert html =~ ~s|phx-hook="KanbanLane"|
    assert html =~ ~s|data-status="in-progress"|
    # Drag-to-review sets status=pending (task #115 fix — previously
    # the dropdown offered pending/approved/denied but no lane showed
    # them, so tasks would vanish).
    assert html =~ ~s|data-status="pending"|
  end

  # UAT Round 8 finding: `status: pending-approval` — the state the
  # Approvals.Gate + Router set when an agent reports "done" on a
  # `requires_approval: director` task — was silently dropped by the
  # review column filter. The card would disappear from the board until
  # the Director explicitly approved or denied via the Inbox, so
  # kanban users who dragged approval-gated tasks lost track of them.
  test "renders tasks with status: pending-approval in the review column",
       %{conn: conn, base: base} do
    tasks_dir = Path.join([base, "companies/acme/projects/foo/tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([base, "companies/acme/projects/foo/project.md"]), """
    ---
    kind: project/v1
    slug: foo
    name: foo
    ---
    # foo
    """)

    File.write!(Path.join(tasks_dir, "foo-42.md"), """
    ---
    kind: task/v1
    id: foo-42
    title: gated task awaiting director sign-off
    status: pending-approval
    assigned_to: engineer
    requires_approval: director
    ---
    body
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")
    assert html =~ "gated task awaiting director sign-off"
    assert html =~ ~s|data-status="pending-approval"|
  end

  test "kanban:move writes new status to the task frontmatter",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    # Seed a plain task (not approval-gated) so the drag-to-done
    # happy path exercises the write without tripping the new
    # approval-gate guard.
    plain_rel = "projects/inbox/tasks/plain-#{System.unique_integer([:positive])}.md"
    plain_abs = Path.join([base, "companies", "acme", plain_rel])
    File.mkdir_p!(Path.dirname(plain_abs))

    File.write!(plain_abs, """
    ---
    kind: task/v1
    title: "Plain task"
    status: pending
    ---

    Do the thing.
    """)

    render_hook(view, "kanban:move", %{"task_path" => plain_rel, "to" => "done"})

    assert File.read!(plain_abs) =~ ~r/status:\s*done/
  end

  # Regression for the opencode round-3 finding: dragging a task
  # with `requires_approval: director` straight to done bypasses
  # the Director approval workflow.
  test "kanban:move refuses drag-to-done on a task that requires director approval",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    # Find the seeded approval-gated task (the t-01 fixture sets
    # `requires_approval: director`).
    task_path =
      [base, "companies", "acme", "projects"]
      |> Path.join()
      |> File.ls!()
      |> Enum.flat_map(fn project ->
        dir = Path.join([base, "companies", "acme", "projects", project, "tasks"])

        case File.ls(dir) do
          {:ok, files} ->
            Enum.map(files, &Path.join(["projects", project, "tasks", &1]))

          _ ->
            []
        end
      end)
      |> Enum.find(fn rel ->
        abs = Path.join([base, "companies", "acme", rel])
        File.read!(abs) =~ ~r/requires_approval:\s*director/
      end)

    assert task_path, "fixture should include at least one approval-gated task"

    render_hook(view, "kanban:move", %{"task_path" => task_path, "to" => "done"})

    # Status on disk must NOT have been flipped to done.
    abs = Path.join([base, "companies", "acme", task_path])
    refute File.read!(abs) =~ ~r/status:\s*done/
    # User got a useful flash.
    assert render(view) =~ "requires director approval"
  end

  test "kanban:move rejects a traversal path", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    render_hook(view, "kanban:move", %{
      "task_path" => "../../other/tasks/evil.md",
      "to" => "done"
    })

    assert render(view) =~ "Could not move task"
  end

  test "sidebar exposes a Kanban nav item + PROJECTS rail with project-scoped kanban links",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")

    # Global Kanban sidebar entry (re-added 2026-04-18 after an e2e
    # walkthrough found users couldn't reach /kanban without knowing
    # the `g k` shortcut).
    assert html =~ ~r|<a[^>]*>\s*<span[^>]*>▤</span>\s*<span[^>]*>Kanban</span>|

    # Project rows under /PROJECTS continue to route to a project-
    # scoped kanban board.
    assert html =~ ~r|href="/companies/acme/kanban\?project=website"|
  end

  test "?project=<slug> filters the board to that project's tasks",
       %{conn: conn, base: base} do
    # Seed a task in a second project so the filter has something to hide.
    other_dir = Path.join([base, "companies", "acme", "projects", "other", "tasks"])
    File.mkdir_p!(other_dir)

    File.write!(Path.join(other_dir, "t-99.md"), """
    ---
    kind: task/v1
    title: "Other project task"
    status: todo
    ---

    body
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban?project=website")
    assert html =~ "Deploy landing page"
    refute html =~ "Other project task"
    # #275 — filter chip bar replaces the old "× all projects"
    # button with a chip that clears the project filter.
    assert html =~ ~s(class="gl-kanban__filters")
    assert html =~ "clear all"
  end

  test "seeded t-01 task with requires_approval: director renders the approval tag + modifier",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")
    assert html =~ "Deploy landing page"
    # UAT N7: renamed from "⚠ approval" to "⚠ gated" so the badge
    # clearly marks *metadata* (requires_approval flag) and doesn't
    # visually collide with the distinct "currently awaiting approval"
    # state that lives in /approvals.
    assert html =~ "⚠ gated"
    assert html =~ "gl-task-card--approval"
  end

  test "new_task button opens the modal with project + title + assignee fields",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    html = render_click(view, "new_task")
    # Modal dialog + selectors by name (more stable than DOM ids)
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(name="project")
    assert html =~ ~s(name="title")
    assert html =~ ~s(name="assigned_to")
    assert html =~ ~s(name="priority")
    assert html =~ ~s(name="severity")
    assert html =~ ~s(name="description")
  end

  test "new_task_create writes a new task markdown", %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    render_click(view, "new_task")

    render_submit(view, "new_task_create", %{
      "project" => "website",
      "title" => "Probe from tests"
    })

    # GEP-13: new tasks are `<project>-NN.md`, not `t-NN.md`.
    tasks_dir = Path.join([base, "companies", "acme", "projects", "website", "tasks"])
    files = File.ls!(tasks_dir) |> Enum.filter(&String.ends_with?(&1, ".md"))

    new_file =
      Enum.find(files, fn f ->
        path = Path.join(tasks_dir, f)

        case File.read(path) do
          {:ok, content} -> content =~ "Probe from tests" and content =~ "status: todo"
          _ -> false
        end
      end)

    assert new_file, "new task file was not written with the expected frontmatter"
    assert new_file =~ ~r/\Awebsite-\d+\.md\z/, "expected website-NN.md, got #{inspect(new_file)}"

    # Audit trail: every on-disk mutation must leave a `task.create` row.
    month = DateTime.utc_now() |> Calendar.strftime("%Y-%m")
    audit_path = Path.join([base, "companies", "acme", "audit", "#{month}.jsonl"])
    assert File.exists?(audit_path), "audit JSONL was not written"

    entries =
      audit_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    create_entry = Enum.find(entries, &(&1["action"] == "task.create"))
    assert create_entry, "no task.create audit entry for new task"
    assert create_entry["target"] =~ ~r{^projects/website/tasks/website-\d+\.md$}
    assert create_entry["detail"]["title"] == "Probe from tests"
    assert create_entry["actor"] == "director"
  end

  test "new_task_create rejects an empty title", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    render_click(view, "new_task")

    html =
      render_submit(view, "new_task_create", %{
        "project" => "website",
        "title" => "   "
      })

    assert html =~ "Title can&#39;t be empty" or html =~ "Title can't be empty"
  end

  test "clicking a task opens the editable detail form", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    html =
      render_click(view, "open_task", %{"path" => "projects/website/tasks/t-01.md"})

    assert html =~ "gl-task-detail"
    # Editable form fields — not read-only pre blocks.
    assert html =~ ~s(name="title")
    assert html =~ ~s(name="status")
    assert html =~ ~s(name="body")
    # Prefilled from the seeded t-01.md fixture.
    assert html =~ "Deploy landing page"
    assert html =~ "Ship it."
  end

  test "open_task reads the comment thread from the sibling file (GEP-30 D8)",
       %{conn: conn, base: base} do
    # Under GEP-30 D8 the task file carries only the prompt body;
    # the thread lives in a sibling `<task-id>.comments.md`. A markdown
    # `## Sub-section` header in the prompt must stay put, and the
    # sibling file's comment must render in the comments panel.
    tasks_dir = Path.join([base, "companies", "acme", "projects", "website", "tasks"])

    File.write!(Path.join(tasks_dir, "mix-body.md"), """
    ---
    kind: task/v1
    title: Mixed body
    status: todo
    ---

    Task prompt

    ## Sub-section in prompt

    Body continues
    """)

    File.write!(Path.join(tasks_dir, "mix-body.comments.md"), """
    ---
    kind: task-comments/v1
    task_id: mix-body
    ---

    ## 2026-04-18T10:00:00Z | director
    Actual comment
    """)

    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    html = render_click(view, "open_task", %{"path" => "projects/website/tasks/mix-body.md"})

    # Prompt body keeps the sub-section header
    assert html =~ "Task prompt"
    assert html =~ "## Sub-section in prompt"
    assert html =~ "Body continues"

    # The comment from the sibling file shows up in the comments panel.
    assert html =~ "Actual comment"
    assert html =~ "comments (1)"

    File.rm!(Path.join(tasks_dir, "mix-body.md"))
    File.rm!(Path.join(tasks_dir, "mix-body.comments.md"))
  end

  test "save_task rewrites title + body + priority on disk", %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    render_click(view, "open_task", %{"path" => "projects/website/tasks/t-01.md"})

    # PR #37 (codex round-5 F3): save_task now refuses status
    # transitions to in-progress / done on an approval-gated task
    # that hasn't yet been director-approved (sibling kanban:move
    # already had the gate; save_task was bypassed). The seeded
    # t-01 fixture has `requires_approval: director` + initial
    # status `pending`, so the test now keeps `status: pending`
    # (no transition) and focuses on the title/body/priority
    # writes.
    render_submit(view, "save_task", %{
      "title" => "Deploy landing page v2",
      "status" => "pending",
      "assigned_to" => "ceo",
      "priority" => "high",
      "requires_approval" => "director",
      "body" => "Updated body content."
    })

    path = Path.join([base, "companies", "acme", "projects", "website", "tasks", "t-01.md"])
    content = File.read!(path)

    assert content =~ ~s(title: "Deploy landing page v2")
    assert content =~ "status: pending"
    assert content =~ "priority: high"
    assert content =~ "Updated body content."
    # Old body is gone.
    refute content =~ "Ship it."
  end

  # C-094 — editing a task through the Kanban shelf must leave an
  # append-only audit record (crown jewel), same as TaskLive.
  test "save_task emits a task.edit audit entry", %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    render_click(view, "open_task", %{"path" => "projects/website/tasks/t-01.md"})

    # See PR #37 note above; keep status unchanged so the
    # approval-gate refuse doesn't pre-empt the audit emission
    # the test is actually verifying.
    render_submit(view, "save_task", %{
      "title" => "Audited kanban edit",
      "status" => "pending",
      "assigned_to" => "ceo",
      "priority" => "high",
      "requires_approval" => "director",
      "body" => "x"
    })

    audit_dir = Path.join([base, "companies", "acme", "audit"])
    month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
    audit_path = Path.join(audit_dir, "#{month}.jsonl")

    entries =
      audit_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    edit = Enum.find(entries, &(&1["action"] == "task.edit"))
    assert edit, "expected a task.edit audit entry, got: #{inspect(entries)}"
    assert edit["target"] == "projects/website/tasks/t-01.md"
    assert "requires_approval" in edit["detail"]["changed"]
    assert "status" in edit["detail"]["changed"]
  end

  # PR #37 (codex round-5 F3): save_task previously bypassed the
  # approval gate (sibling kanban:move enforced it; save_task did
  # not). A crafted payload could drag a `requires_approval:
  # director` task straight to `done` or `in-progress` via the
  # save form without the Director's Inbox approval.
  test "save_task REFUSES status=done on an approval-gated task",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    render_click(view, "open_task", %{"path" => "projects/website/tasks/t-01.md"})

    html =
      render_submit(view, "save_task", %{
        "title" => "Deploy landing page",
        "status" => "done",
        "assigned_to" => "ceo",
        "priority" => "high",
        "requires_approval" => "director",
        "body" => "Trying to skip director approval."
      })

    assert html =~ "requires director approval" or html =~ "approve it via the Inbox"

    path = Path.join([base, "companies", "acme", "projects", "website", "tasks", "t-01.md"])
    content = File.read!(path)

    # On-disk file must be unchanged (gate refused the write).
    refute content =~ "status: done"
    refute content =~ "Trying to skip"
  end

  # PR #37 (codex round-5 F3): clearing `requires_approval` on a
  # currently-gate-pending task is the second bypass shape — same
  # outcome (no Director approval needed) by simply removing the
  # gate. Only refused when the form EXPLICITLY clears the field
  # (partial submits that omit it preserve the disk value).
  test "save_task REFUSES explicit clear of requires_approval on a gated task",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    render_click(view, "open_task", %{"path" => "projects/website/tasks/t-01.md"})

    html =
      render_submit(view, "save_task", %{
        "title" => "Deploy landing page",
        "status" => "pending",
        "assigned_to" => "ceo",
        "priority" => "high",
        # Explicit empty — this is the form's "clear" semantics.
        "requires_approval" => "",
        "body" => "Body."
      })

    assert html =~ "Cannot clear" or html =~ "requires_approval"

    path = Path.join([base, "companies", "acme", "projects", "website", "tasks", "t-01.md"])
    content = File.read!(path)

    # On-disk file must still carry the director gate.
    assert content =~ "requires_approval: director"
  end

  test "close_task clears the detail panel", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    render_click(view, "open_task", %{"path" => "projects/website/tasks/t-01.md"})
    html = render_click(view, "close_task")

    refute html =~ "gl-task-detail"
  end

  test "comment_task appends `## ts | director\\n<body>` to the sibling .comments.md (GEP-30 D8)",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    task_rel = "projects/website/tasks/t-01.md"
    render_click(view, "open_task", %{"path" => task_rel})

    render_hook(view, "comment_task", %{"comment" => "Please review by EOD"})

    abs_task = Path.join([base, "companies", "acme", task_rel])
    abs_comments = Glorbo.TaskComments.path_for(abs_task)

    # Task file itself stays unchanged (diff-clean prompt).
    task_content = File.read!(abs_task)
    refute task_content =~ "Please review by EOD"

    # The comment lives in the sibling file.
    comments_content = File.read!(abs_comments)
    assert comments_content =~ "kind: task-comments/v1"
    # Director's comment rendered with lowercase attribution (user
    # 2026-04-19 UAT: all authors are lowercase for consistency).
    assert comments_content =~ " | director\n"
    assert comments_content =~ "Please review by EOD"
  end

  test "comment_task with empty body shows a flash and does not append",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    task_rel = "projects/website/tasks/t-01.md"
    render_click(view, "open_task", %{"path" => task_rel})

    abs = Path.join([base, "companies", "acme", task_rel])
    before = File.read!(abs)

    html = render_hook(view, "comment_task", %{"comment" => "   "})

    assert html =~ "Comment is empty"
    assert File.read!(abs) == before
  end

  test "open_task overlay exposes an `open task page →` link to TaskLive",
       %{conn: conn, base: base} do
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
    kind: task/v1
    title: trace
    status: todo
    ---
    body
    """)

    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    html = render_click(view, "open_task", %{"path" => "projects/demo/tasks/demo-1.md"})

    # Shelf-class marker (not the center-modal variant).
    assert html =~ "gl-shelf-scrim"
    assert html =~ "gl-task-detail--shelf"
    # The JIRA-style "open task page" link points at TaskLive.
    assert html =~ "open task page"
    assert html =~ ~s(href="/companies/acme/tasks/demo-1")
  end

  test "?goal=<slug> filters tasks by their frontmatter goal: field",
       %{conn: conn, base: base} do
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
    kind: task/v1
    title: match the goal
    status: todo
    goal: q4-launch
    ---
    body
    """)

    File.write!(Path.join(tasks_dir, "demo-2.md"), """
    ---
    kind: task/v1
    title: irrelevant task
    status: todo
    ---
    body
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban?goal=q4-launch")
    assert html =~ "match the goal"
    refute html =~ "irrelevant task"
    assert html =~ "goal:q4-launch"
  end

  # #261 — ?who=<slug> filters displayed tasks by `assigned_to`.
  test "?who=<slug> filters displayed tasks by assigned_to",
       %{conn: conn, base: base} do
    tasks_dir = Path.join([base, "companies/acme/projects/wfilter/tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([base, "companies/acme/projects/wfilter/project.md"]), """
    ---
    slug: wfilter
    name: wfilter
    ---
    """)

    File.write!(Path.join(tasks_dir, "wfilter-1.md"), """
    ---
    kind: task/v1
    title: engineer task
    status: todo
    assigned_to: engineer
    ---
    """)

    File.write!(Path.join(tasks_dir, "wfilter-2.md"), """
    ---
    kind: task/v1
    title: ceo task
    status: todo
    assigned_to: ceo
    ---
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban?who=engineer")
    assert html =~ "engineer task"
    refute html =~ "ceo task"
  end

  test "?assignee=<slug> opens new-task drawer with assignee prefilled",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban?assignee=ceo")
    assert html =~ "gl-new-task-drawer"
    assert html =~ ~s(name="assigned_to") and html =~ "ceo"
  end

  test "?new_task=1 opens the empty new-task drawer",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban?new_task=1")
    assert html =~ "gl-new-task-drawer"
  end

  test "sidebar exposes `+ new task` link pointing at ?new_task=1 (feature #59)",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")
    assert html =~ "gl-sidebar__new-task"
    assert html =~ ~s(href="/companies/acme/kanban?new_task=1")
    assert html =~ "+ new task"
  end

  test "drawer closes after a successful new_task_create (E2E round-trip)",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban?new_task=1")
    # Drawer is initially open.
    assert render(view) =~ "gl-new-task-drawer"

    html =
      render_submit(view, "new_task_create", %{
        "project" => "website",
        "title" => "Drawer round-trip"
      })

    # After success the drawer markup is gone and the flash confirms.
    refute html =~ "gl-new-task-drawer"
    assert html =~ "Created website-"
  end

  test "?return_to=/path redirects on cancel when set",
       %{conn: conn} do
    {:ok, view, _} =
      live(
        conn,
        ~p"/companies/acme/kanban?assignee=ceo&return_to=%2Fcompanies%2Facme%2Fagents%2Fceo"
      )

    assert {:error, {:live_redirect, %{to: "/companies/acme/agents/ceo"}}} =
             render_click(view, "new_task_cancel")
  end

  test "?return_to=//evil.com is rejected (open-redirect protection)",
       %{conn: conn} do
    # Threatmodel: "//evil.com/foo" passes a naive `starts_with?(/)`
    # check but the browser navigates to https://evil.com.
    # `same_origin_path?/1` must reject leading "//" and "/\\".
    for hostile <- ["//evil.com", "//evil.com/foo", "/\\\\windows.example"] do
      encoded = URI.encode_www_form(hostile)

      {:ok, view, _} =
        live(conn, ~p"/companies/acme/kanban?return_to=#{encoded}")

      # Expect a noop on cancel — drawer closes but no redirect.
      result = render_click(view, "new_task_cancel")

      refute match?({:error, {:live_redirect, _}}, result),
             "open redirect not blocked for return_to=#{hostile}"
    end
  end

  test ":agent_status PubSub broadcast triggers a re-render (pill color refresh)",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    # Broadcast on the topic the LV subscribes to. The handler bumps
    # `:_agent_status_tick` which forces a re-render — we just assert
    # the view is still alive + renderable.
    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:agents:status",
      {:agent_status, "ceo", :busy, "projects/foo/tasks/bar.md"}
    )

    # Give the message time to flow through
    Process.sleep(50)

    # View should still render (message was handled, not swallowed)
    assert render(view) =~ "Kanban"
  end

  test "open_task rejects a traversal path", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    html = render_click(view, "open_task", %{"path" => "../../etc/passwd"})

    assert html =~ "Invalid task path"
    refute html =~ "gl-task-detail"
  end

  test "open_task rejects non-task project files", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    html = render_click(view, "open_task", %{"path" => "projects/website/project.md"})

    assert html =~ "Invalid task path"
    refute html =~ "gl-task-detail"
  end

  test "open_task rejects symlinked task files", %{conn: conn, base: base} do
    tasks_dir = Path.join([base, "companies", "acme", "projects", "website", "tasks"])
    trap = Path.join(tasks_dir, "trap.md")
    File.ln_s!(Path.join(base, "config.md"), trap)

    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    html = render_click(view, "open_task", %{"path" => "projects/website/tasks/trap.md"})

    assert html =~ "Invalid task path"
    refute html =~ "gl-task-detail"
  end

  test "new_task_create rejects an unknown project", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    render_click(view, "new_task")

    html =
      render_submit(view, "new_task_create", %{
        "project" => "nonexistent",
        "title" => "Whatever"
      })

    assert html =~ "Pick a project"
  end

  # task #126 — assigning a task to an agent via save_task drops a
  # notification file into the agent's inbox, which the wake pipeline
  # picks up on the next inotify tick. Covers: fresh assignment, no
  # dup on same-assignee re-save, skip when director is assignee.
  describe "task assignment triggers agent inbox notification (#126)" do
    setup %{base: base} do
      proj = Path.join([base, "companies", "acme", "projects", "demo", "tasks"])
      File.mkdir_p!(proj)
      path = Path.join(proj, "demo-assign.md")

      File.write!(path, """
      ---
      kind: task/v1
      title: "Initial"
      status: todo
      ---

      body
      """)

      {:ok, task_rel: "projects/demo/tasks/demo-assign.md"}
    end

    test "assigning to an existing agent writes to their inbox",
         %{conn: conn, base: base, task_rel: task_rel} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/kanban?project=demo")
      render_click(view, "open_task", %{"path" => task_rel})

      render_submit(view, "save_task", %{
        "title" => "Pick up this task",
        "status" => "todo",
        "assigned_to" => "ceo",
        "priority" => "",
        "requires_approval" => "",
        "body" => "Please handle this."
      })

      inbox = Path.join([base, "companies/acme/agents/ceo/inbox"])
      assert {:ok, files} = File.ls(inbox)
      notifications = Enum.filter(files, &String.contains?(&1, "task-demo-assign"))
      assert length(notifications) == 1

      content = File.read!(Path.join(inbox, hd(notifications)))
      assert content =~ "from: director"
      assert content =~ "kind: task_assignment"
      assert content =~ "Pick up this task"
    end

    test "assignee=director does NOT write to an inbox",
         %{conn: conn, base: base, task_rel: task_rel} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/kanban?project=demo")
      render_click(view, "open_task", %{"path" => task_rel})

      render_submit(view, "save_task", %{
        "title" => "For Director",
        "status" => "todo",
        "assigned_to" => "director",
        "priority" => "",
        "requires_approval" => "",
        "body" => "x"
      })

      # Director isn't an agent; no inbox dir to write to. agents/ceo
      # stays clean.
      inbox = Path.join([base, "companies/acme/agents/ceo/inbox"])

      files =
        case File.ls(inbox),
          do: (
            {:ok, f} -> f
            _ -> []
          )

      refute Enum.any?(files, &String.contains?(&1, "task-demo-assign"))
    end
  end

  # task #116 — the assigned_to input on the task-detail overlay uses an
  # HTML datalist sourced from company agents + "director". Director is
  # the human operator and always a valid assignment target even though
  # no agents/director/ dir exists.
  test "task detail exposes assignee datalist with agents + director",
       %{conn: conn, base: base} do
    proj = Path.join([base, "companies", "acme", "projects", "website", "tasks"])
    File.mkdir_p!(proj)
    path = Path.join(proj, "site-x1.md")

    File.write!(path, """
    ---
    kind: task/v1
    title: "Sitemap"
    status: todo
    ---

    body
    """)

    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban?project=website")
    html = render_click(view, "open_task", %{"path" => "projects/website/tasks/site-x1.md"})

    assert html =~ ~s(list="gl-assignee-options")
    assert html =~ ~s(<datalist id="gl-assignee-options">)
    # "director" always present; "ceo" comes from the acme fixture.
    assert html =~ ~s(<option value="director")
    assert html =~ ~s(<option value="ceo")
  end

  # #275 — kanban filter chip bar. Each active filter renders as a
  # chip whose × link drops only that filter, preserving the
  # others. "clear all" drops everything.
  describe "filter chips (#275)" do
    test "no chips when no filters active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")
      refute html =~ ~s(class="gl-kanban__filters")
    end

    test "?who=ceo renders a single ASSIGNEE chip", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban?who=ceo")
      assert html =~ ~s(class="gl-kanban__filters")
      assert html =~ "assignee"
      assert html =~ ">ceo<"
      assert html =~ "clear all"
    end

    test "combining project+who renders two chips; each chip links to a URL that drops only itself",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban?project=website&who=ceo")
      # Both chips present.
      assert html =~ "project"
      assert html =~ ">website<"
      assert html =~ "assignee"
      assert html =~ ">ceo<"
      # Project chip's link drops project, keeps who=ceo.
      assert html =~ ~r|/companies/acme/kanban\?who=ceo"[^>]*title="Clear project filter|
      # Assignee chip's link drops who, keeps project=website.
      assert html =~ ~r|/companies/acme/kanban\?project=website"[^>]*title="Clear assignee filter|
      # Clear-all link is bare.
      assert html =~ ~s(href="/companies/acme/kanban" data-phx-link="redirect")
    end

    # E2E: clicking a chip's × link actually drops just that filter and
    # the LV mount re-applies the remaining filters. Uses live_redirect
    # to follow the chip's `navigate=` URL into a fresh mount.
    test "after chip click, re-mount applies only remaining filters",
         %{conn: conn} do
      {:ok, _view, html} =
        live(conn, ~p"/companies/acme/kanban?project=website&who=ceo")

      # Assert both chips are visible.
      assert html =~ ">website<"
      assert html =~ ">ceo<"

      # Simulate clicking the assignee chip by re-mounting at its
      # target URL. The handle_params in the new mount must drop
      # who= but keep project=website. Check the chip bar specifically,
      # not the whole page (where `ceo` appears in agent datalist, task
      # cards, etc.).
      {:ok, _view2, html2} = live(conn, ~p"/companies/acme/kanban?project=website")
      assert html2 =~ ~s(class="gl-kanban__filters")
      assert html2 =~ "project"
      # Only one chip now — the assignee chip-close anchor shouldn't
      # render for this filter combo.
      refute html2 =~ "Clear assignee filter"
    end

    test "after clear-all click, re-mount shows no filter chips",
         %{conn: conn} do
      {:ok, _view, html} =
        live(conn, ~p"/companies/acme/kanban?project=website&who=ceo")

      assert html =~ ~s(class="gl-kanban__filters")

      {:ok, _view2, html2} = live(conn, ~p"/companies/acme/kanban")
      refute html2 =~ ~s(class="gl-kanban__filters")
    end
  end

  # GEP-32 phase 4 follow-up — mirroring AgentLive's provider-aware
  # model combobox in the kanban new-task form. The datalist feeds off
  # the cached `provider_models` projection keyed by the selected
  # assignee's provider.
  describe "new-task model datalist (GEP-32 phase 4 follow-up)" do
    setup %{base: base} do
      # Second agent in acme with a native provider so there's something
      # the cache can key off.
      agent_dir = Path.join([base, "companies", "acme", "agents", "sparky"])

      Enum.each(
        ~w(inbox outbox workspace history state),
        &File.mkdir_p!(Path.join(agent_dir, &1))
      )

      File.write!(Path.join(agent_dir, "AGENT.md"), """
      ---
      kind: agent/v1
      name: Sparky
      slug: sparky
      role: "Research"
      provider: openai
      model: gpt-4o
      network: full
      heartbeat: null
      permissions:
        - projects:read:*
      ---

      # Sparky
      """)

      Glorbo.Repo.insert_all(Glorbo.ProviderModel, [
        %{
          alias: "openai",
          model_id: "gpt-4o",
          raw_json: "{}",
          refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        %{
          alias: "openai",
          model_id: "gpt-5-alpha",
          raw_json: "{}",
          refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        # Noise row under a different provider; must not appear in the
        # datalist when assigned_to has `provider: openai`.
        %{
          alias: "openrouter",
          model_id: "other/only",
          raw_json: "{}",
          refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      :ok
    end

    test "model_options_for_assignee returns cached models for native provider",
         %{base: base} do
      assert GlorboWeb.KanbanLive.model_options_for_assignee(base, "acme", "sparky") ==
               ~w(gpt-4o gpt-5-alpha)
    end

    test "model_options_for_assignee returns [] for director, empty, nil",
         %{base: base} do
      assert GlorboWeb.KanbanLive.model_options_for_assignee(base, "acme", "director") == []
      assert GlorboWeb.KanbanLive.model_options_for_assignee(base, "acme", "") == []
      assert GlorboWeb.KanbanLive.model_options_for_assignee(base, "acme", nil) == []
    end

    test "model_options_for_assignee returns [] for CLI provider (no cache)",
         %{base: base} do
      # `ceo` is seeded with `provider: claude-code` — a CLI provider
      # with no `provider_models` rows.
      assert GlorboWeb.KanbanLive.model_options_for_assignee(base, "acme", "ceo") == []
    end

    test "model_options_for_assignee returns [] for unknown slug",
         %{base: base} do
      assert GlorboWeb.KanbanLive.model_options_for_assignee(base, "acme", "no-such-agent") == []
    end

    test "datalist renders cached models after assignee changes",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/kanban?new_task=1")

      html =
        render_change(view, "new_task_validate", %{
          "assigned_to" => "sparky",
          "title" => "",
          "project" => ""
        })

      assert html =~ ~s(id="gl-new-task-model-options")
      assert html =~ "gpt-4o"
      assert html =~ "gpt-5-alpha"
      refute html =~ "other/only"
    end

    test "model is persisted into task frontmatter on create",
         %{conn: conn, base: base} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/kanban?new_task=1")

      render_submit(view, "new_task_create", %{
        "project" => "website",
        "title" => "Pick the model",
        "assigned_to" => "sparky",
        "model" => "gpt-5-alpha",
        "priority" => "medium",
        "severity" => "",
        "description" => ""
      })

      tasks_dir = Path.join([base, "companies", "acme", "projects", "website", "tasks"])
      {:ok, files} = File.ls(tasks_dir)

      path =
        files
        |> Enum.map(&Path.join(tasks_dir, &1))
        |> Enum.find(fn p -> File.read!(p) =~ "Pick the model" end)

      body = File.read!(path)

      assert body =~ "model: gpt-5-alpha"
      assert body =~ "assigned_to: sparky"
    end
  end
end
