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

  test "kanban:move writes new status to the task frontmatter",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    # Find a seeded task's relative path by scanning the fixture tree.
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
      |> List.first()

    assert task_path, "no seeded tasks available in fixture"

    render_hook(view, "kanban:move", %{"task_path" => task_path, "to" => "done"})

    abs = Path.join([base, "companies", "acme", task_path])
    content = File.read!(abs)
    assert content =~ ~r/status:\s*done/
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
    title: "Other project task"
    status: todo
    ---

    body
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban?project=website")
    assert html =~ "Deploy landing page"
    refute html =~ "Other project task"
    assert html =~ "× all projects"
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

  test "open_task splits prompt body from comment history",
       %{conn: conn, base: base} do
    # Seed a task that mixes a markdown `## Sub-section` header in the
    # prompt (must stay in the body) with a real comment (must render
    # in the comments panel). Earlier regex naively split on ANY `## `,
    # which smashed sub-section headers into the comment stream.
    path =
      Path.join([base, "companies", "acme", "projects", "website", "tasks", "mix-body.md"])

    File.write!(path, """
    ---
    title: Mixed body
    status: todo
    ---

    Task prompt

    ## Sub-section in prompt

    Body continues

    ## 2026-04-18T10:00:00Z | director
    Actual comment
    """)

    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    html = render_click(view, "open_task", %{"path" => "projects/website/tasks/mix-body.md"})

    # Prompt body keeps the sub-section header
    assert html =~ "Task prompt"
    assert html =~ "## Sub-section in prompt"
    assert html =~ "Body continues"

    # The real Director comment shows up in the comments panel
    assert html =~ "Actual comment"
    assert html =~ "comments (1)"

    File.rm!(path)
  end

  test "save_task rewrites title + body + priority on disk", %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    render_click(view, "open_task", %{"path" => "projects/website/tasks/t-01.md"})

    render_submit(view, "save_task", %{
      "title" => "Deploy landing page v2",
      "status" => "in-progress",
      "assigned_to" => "ceo",
      "priority" => "high",
      "requires_approval" => "director",
      "body" => "Updated body content."
    })

    path = Path.join([base, "companies", "acme", "projects", "website", "tasks", "t-01.md"])
    content = File.read!(path)

    assert content =~ ~s(title: "Deploy landing page v2")
    assert content =~ "status: in-progress"
    assert content =~ "priority: high"
    assert content =~ "Updated body content."
    # Old body is gone.
    refute content =~ "Ship it."
  end

  test "close_task clears the detail panel", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    render_click(view, "open_task", %{"path" => "projects/website/tasks/t-01.md"})
    html = render_click(view, "close_task")

    refute html =~ "gl-task-detail"
  end

  test "open_task rejects a traversal path", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    html = render_click(view, "open_task", %{"path" => "../../etc/passwd"})

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
end
