defmodule GlorboWeb.KanbanLiveTest do
  @moduledoc """
  Plan 04-02 Task 2 — `GlorboWeb.KanbanLive`
  (/companies/:company/kanban).

  Happy-path assertions: exact 3-column header labels (D-23), the
  read-only banner, and rendering of the seeded `t-01` task with its
  lightning glyph (`requires_approval: director`).
  """
  use GlorboWeb.LiveCase, async: false

  test "renders three columns with exact header labels", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")
    assert html =~ "todo"
    assert html =~ "in progress"
    assert html =~ "done"
    # M4.1: columns are now drop targets with the KanbanLane hook
    assert html =~ ~s|phx-hook="KanbanLane"|
    assert html =~ ~s|data-status="in-progress"|
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

  test "sidebar exposes PROJECTS rail with project-scoped kanban links", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")
    # The "Kanban" nav item was removed from the sidebar; project rows
    # under /PROJECTS now route to a project-scoped kanban board.
    assert html =~ ~r|href="/companies/acme/kanban\?project=website"|
    refute html =~ ~r|<a[^>]*>\s*<span[^>]*>▤</span>\s*<span[^>]*>Kanban</span>|
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
    assert html =~ "⚠ approval"
    assert html =~ "gl-task-card--approval"
  end

  test "new_task button opens inline form", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    html = render_click(view, "new_task")
    assert html =~ ~s(id="new-task-project")
    assert html =~ ~s(id="new-task-title")
  end

  test "new_task_create writes a new task markdown", %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")
    render_click(view, "new_task")

    render_submit(view, "new_task_create", %{
      "project" => "website",
      "title" => "Probe from tests"
    })

    # Should exist at projects/website/tasks/t-XX.md with our title.
    tasks_dir = Path.join([base, "companies", "acme", "projects", "website", "tasks"])
    files = File.ls!(tasks_dir) |> Enum.filter(&String.ends_with?(&1, ".md"))

    matched =
      Enum.any?(files, fn f ->
        path = Path.join(tasks_dir, f)

        case File.read(path) do
          {:ok, content} -> content =~ "Probe from tests" and content =~ "status: todo"
          _ -> false
        end
      end)

    assert matched, "new task file was not written with the expected frontmatter"
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

  test "clicking a task opens the detail panel with frontmatter + body", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/kanban")

    html =
      render_click(view, "open_task", %{"path" => "projects/website/tasks/t-01.md"})

    assert html =~ "gl-task-detail"
    # Frontmatter field + body from the seeded t-01.md fixture.
    assert html =~ "Deploy landing page"
    assert html =~ "Ship it."
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
end
