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
    assert html =~ "Read-only view"
  end

  test "seeded t-01 task with requires_approval: director shows lightning icon",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/kanban")
    assert html =~ "Deploy landing page"
    assert html =~ "Requires Director approval"
  end
end
