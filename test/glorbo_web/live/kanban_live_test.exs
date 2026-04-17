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

  test "renders the CompanyTabs strip with :kanban active", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")
    # Active Kanban tab (regression for TODO.md P0 #5 — tab active state).
    assert html =~
             ~r|<a[^>]*href="/companies/acme/kanban"[^>]*class="[^"]*gl-tab gl-tab--active|
  end

  test "seeded t-01 task with requires_approval: director shows lightning icon",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")
    assert html =~ "Deploy landing page"
    assert html =~ "Requires Director approval"
  end
end
