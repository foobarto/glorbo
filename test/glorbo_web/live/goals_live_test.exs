defmodule GlorboWeb.GoalsLiveTest do
  @moduledoc """
  `GlorboWeb.GoalsLive` — `/companies/:co/goals`
  (paperclip-ux-gaps §7). GEP-63: goals are canonical `goals/<id>.md`
  files read via `Glorbo.Company.Goals.list/1`.
  """
  use GlorboWeb.LiveCase, async: false

  defp write_goal(base, filename, body) do
    dir = Path.join([base, "companies", "acme", "goals"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), body)
  end

  defp write_task(base, filename, body) do
    dir = Path.join([base, "companies", "acme", "projects", "foo", "tasks"])
    File.mkdir_p!(dir)

    File.write!(Path.join([base, "companies/acme/projects/foo/project.md"]), """
    ---
    slug: foo
    name: foo
    ---
    """)

    File.write!(Path.join(dir, filename), body)
  end

  setup %{base: base} do
    # A clean company.md (no goals: frontmatter — GEP-63 cut).
    File.write!(Path.join([base, "companies", "acme", "company.md"]), """
    ---
    kind: company/v1
    slug: acme
    name: Acme
    ---
    # Acme
    """)

    write_goal(base, "q4-launch.md", """
    ---
    kind: goal/v1
    id: q4-launch
    name: Launch v2 by end of Q4
    description: Ship the next major release
    status: active
    ---
    """)

    write_goal(base, "eng-ops.md", """
    ---
    kind: goal/v1
    id: eng-ops
    name: Eng ops
    status: paused
    ---
    """)

    write_task(base, "foo-1.md", """
    ---
    kind: task/v1
    title: launch-bug
    status: in-progress
    goal: q4-launch
    ---
    """)

    write_task(base, "foo-2.md", """
    ---
    kind: task/v1
    title: done-item
    status: done
    goal: q4-launch
    ---
    """)

    write_task(base, "foo-3.md", """
    ---
    kind: task/v1
    title: loose-end
    status: todo
    ---
    """)

    :ok
  end

  test "renders one card per goal with task count", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")
    assert html =~ "Launch v2 by end of Q4"
    assert html =~ "q4-launch"
    assert html =~ "Eng ops"
    # q4-launch has 2 tasks total, 1 open
    assert html =~ "total"
    assert html =~ ">2<"
  end

  test "renders (no goal) card for unassigned tasks", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")
    assert html =~ "(no goal)"
    # foo-3 is the single unassigned task
    assert html =~ ">1<"
  end

  test "deep link to kanban carries the goal id", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")
    assert html =~ "kanban?goal=q4-launch"
  end

  test "empty state when no goals + no unassigned tasks", %{conn: conn, base: base} do
    File.rm_rf!(Path.join([base, "companies/acme/projects"]))
    File.rm_rf!(Path.join([base, "companies/acme/goals"]))

    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")
    assert html =~ "No goals yet"
  end

  test "unknown company redirects", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies"}}} =
             live(conn, "/companies/bogus/goals")
  end

  # #253 — goal progress bar derived from done / total tasks per goal.
  test "renders a progress bar with done/total ratio + %", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")

    # q4-launch has 2 tasks total, 1 done → 50% mid state.
    assert html =~ "gl-goal-card__progress-fill"
    assert html =~ "gl-goal-card__progress-fill--mid"
    assert html =~ "1 / 2 done"
    assert html =~ "50%"
  end

  # GEP-63 D4 — explicit `progress:` overrides the derived value.
  test "explicit progress: overrides the derived done/total ratio", %{conn: conn, base: base} do
    # q4-launch derives 50% (mid) from tasks, but pin progress: 100 (done).
    write_goal(base, "q4-launch.md", """
    ---
    kind: goal/v1
    id: q4-launch
    name: Launch v2 by end of Q4
    status: active
    progress: 100
    ---
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")
    # 100 lands in the "done" bucket; the derived 50% would have been "mid".
    assert html =~ "gl-goal-card__progress-fill--done"
    assert html =~ "100%"
    # The done/total label still reflects the linked tasks.
    assert html =~ "1 / 2 done"
  end

  # GEP-63 D4 — an explicit-progress goal with no linked tasks still
  # renders a bar (just the %, no done/total prefix).
  test "explicit progress with zero tasks renders a bare % bar", %{conn: conn, base: base} do
    write_goal(base, "eng-ops.md", """
    ---
    kind: goal/v1
    id: eng-ops
    name: Eng ops
    status: active
    progress: 25
    ---
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")
    assert html =~ "25%"
  end

  # `name` maps to the card title natively (GEP-63); absent it the id
  # is shown.
  test "title falls back to id when the goal file has no name", %{conn: conn, base: base} do
    write_goal(base, "bare.md", "---\nkind: goal/v1\nid: bare\n---\n")
    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")
    # The id renders both as the title and as the slug suffix.
    assert html =~ "bare"
  end

  # T9 — a malformed goal file is skipped silently; the page still
  # renders the valid goals.
  test "T9: a malformed goal file is dropped, render survives", %{conn: conn, base: base} do
    write_goal(base, "broken.md", "---\nkind: goal/v1\nid: broken\ntags: [a, b\n---\n")

    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")
    assert html =~ "Launch v2 by end of Q4"
    refute html =~ "Protocol.UndefinedError"
  end

  # E2E — submitting the add-goal form writes a goals/<id>.md file and
  # the new card renders.
  test "add-goal form writes a goal/v1 file and renders the card", %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme/goals")

    # The form lives in a modal — open it first.
    view |> element("button[phx-click=new_goal_open]") |> render_click()

    html =
      view
      |> form("form[phx-submit=new_goal_submit]",
        goal: %{id: "new-goal", name: "Brand New Goal", description: "fresh"}
      )
      |> render_submit()

    assert html =~ "Goal added."
    assert html =~ "Brand New Goal"

    file = Path.join([base, "companies", "acme", "goals", "new-goal.md"])
    assert File.exists?(file)
    assert File.read!(file) =~ "id: new-goal"
    assert File.read!(file) =~ "name: Brand New Goal"
  end

  test "add-goal form surfaces a duplicate-id error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme/goals")

    view |> element("button[phx-click=new_goal_open]") |> render_click()

    html =
      view
      |> form("form[phx-submit=new_goal_submit]",
        goal: %{id: "q4-launch", name: "Dup"}
      )
      |> render_submit()

    assert html =~ "ID is already in use."
  end
end
