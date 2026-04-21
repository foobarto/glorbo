defmodule GlorboWeb.GoalsLiveTest do
  @moduledoc """
  `GlorboWeb.GoalsLive` — `/companies/:co/goals`
  (paperclip-ux-gaps §7).
  """
  use GlorboWeb.LiveCase, async: false

  setup %{base: base} do
    # Overlay a company.md with goals + tasks referencing them.
    File.write!(Path.join([base, "companies", "acme", "company.md"]), """
    ---
    slug: acme
    name: Acme
    goals:
      - slug: q4-launch
        title: Launch v2 by end of Q4
        description: Ship the next major release
        status: active
      - slug: eng-ops
        title: Eng ops
        status: paused
    ---
    # Acme
    """)

    tasks_dir = Path.join([base, "companies/acme/projects/foo/tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([base, "companies/acme/projects/foo/project.md"]), """
    ---
    slug: foo
    name: foo
    ---
    """)

    File.write!(Path.join(tasks_dir, "foo-1.md"), """
    ---
    title: launch-bug
    status: in-progress
    goal: q4-launch
    ---
    """)

    File.write!(Path.join(tasks_dir, "foo-2.md"), """
    ---
    title: done-item
    status: done
    goal: q4-launch
    ---
    """)

    File.write!(Path.join(tasks_dir, "foo-3.md"), """
    ---
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

  test "deep link to kanban carries the goal slug", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")
    assert html =~ "kanban?goal=q4-launch"
  end

  test "empty state when no goals + no unassigned tasks", %{conn: conn, base: base} do
    File.rm_rf!(Path.join([base, "companies/acme/projects"]))

    File.write!(Path.join([base, "companies", "acme", "company.md"]), """
    ---
    slug: acme
    name: acme
    ---
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")
    assert html =~ "No goals declared"
  end

  test "unknown company redirects", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies"}}} =
             live(conn, "/companies/bogus/goals")
  end

  # #253 — goal progress bar based on done / total tasks per goal.
  test "renders a progress bar with done/total ratio + %", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/goals")

    # q4-launch has 2 tasks total, 1 done → 50% mid state.
    assert html =~ "gl-goal-card__progress-fill"
    assert html =~ "gl-goal-card__progress-fill--mid"
    assert html =~ "1 / 2 done"
    assert html =~ "50%"
  end
end
