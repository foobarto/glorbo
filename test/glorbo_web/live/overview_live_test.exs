defmodule GlorboWeb.OverviewLiveTest do
  @moduledoc """
  Plan 04-02 Task 1 — `GlorboWeb.OverviewLive` (/companies).

  Asserts that the multi-company overview renders one `<.company_card>`
  per company directory under `<base>/companies/` and that the empty
  state appears when no companies exist.
  """
  use GlorboWeb.LiveCase, async: false

  test "renders company card for seeded acme", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies")
    assert html =~ "acme"
    assert html =~ "agent"
  end

  test "empty state shown when no companies exist", %{conn: conn, base: base} do
    File.rm_rf!(Path.join([base, "companies", "acme"]))
    {:ok, _view, html} = live(conn, ~p"/companies")
    assert html =~ "No companies yet"
  end

  describe "goals-progress card (backlog #13)" do
    test "no-goals company omits the goals row entirely", %{conn: conn} do
      # Seeded acme has no `goals:` on company.md. Expect no
      # goals-progress row rendered at all.
      {:ok, _view, html} = live(conn, ~p"/companies")
      refute html =~ "gl-company-card__goals"
    end

    test "goals defined + tasks referencing them render a progress bar with pct",
         %{conn: conn, base: base} do
      co_dir = Path.join([base, "companies", "acme"])

      # Seed two goal/v1 files and a project with tasks tagged to those
      # goals — one done, one in-progress. Expected rollup: 2 goals,
      # 3 tasks total, 1 done → 33%.
      goals_dir = Path.join(co_dir, "goals")
      File.mkdir_p!(goals_dir)

      File.write!(Path.join(goals_dir, "ship-v1.md"), """
      ---
      kind: goal/v1
      id: ship-v1
      name: Ship v1
      status: active
      ---
      """)

      File.write!(Path.join(goals_dir, "docs.md"), """
      ---
      kind: goal/v1
      id: docs
      name: Docs pass
      status: active
      ---
      """)

      File.mkdir_p!(Path.join([co_dir, "projects", "blog", "tasks"]))

      File.write!(Path.join([co_dir, "projects", "blog", "project.md"]), """
      ---
      slug: blog
      name: blog
      ---
      """)

      File.write!(Path.join([co_dir, "projects", "blog", "tasks", "a.md"]), """
      ---
      kind: task/v1
      title: draft post
      status: done
      goal: ship-v1
      ---
      """)

      File.write!(Path.join([co_dir, "projects", "blog", "tasks", "b.md"]), """
      ---
      kind: task/v1
      title: edit post
      status: in-progress
      goal: ship-v1
      ---
      """)

      File.write!(Path.join([co_dir, "projects", "blog", "tasks", "c.md"]), """
      ---
      kind: task/v1
      title: docs site
      status: todo
      goal: docs
      ---
      """)

      {:ok, _view, html} = live(conn, ~p"/companies")

      assert html =~ "gl-company-card__goals"
      assert html =~ "2 goals"
      # 1 done / 3 total = 33% (integer div)
      assert html =~ "33%"
      assert html =~ "(1/3)"
    end

    # GEP-63 scope call: the /companies overview card is a *task-completion
    # rollup* (done/total across goals) — touchpoint #6 keeps its "summary
    # math unchanged", and D4's explicit-`progress:` override is scoped to
    # the per-goal *bars* on CompanyLive + GoalsLive (Design §"Progress
    # source-of-truth"), NOT this aggregate. This pins that an explicit
    # `progress:` does NOT move the overview number.
    test "explicit goal progress: does not change the overview task rollup",
         %{conn: conn, base: base} do
      goals_dir = Path.join([base, "companies", "acme", "goals"])
      File.mkdir_p!(goals_dir)

      # Pin progress: 100, but only 1 of 2 linked tasks is done.
      File.write!(Path.join(goals_dir, "ship-v1.md"), """
      ---
      kind: goal/v1
      id: ship-v1
      name: Ship v1
      status: active
      progress: 100
      ---
      """)

      File.mkdir_p!(Path.join([base, "companies", "acme", "projects", "blog", "tasks"]))

      File.write!(Path.join([base, "companies/acme/projects/blog/tasks/a.md"]), """
      ---
      kind: task/v1
      title: done one
      status: done
      goal: ship-v1
      ---
      """)

      File.write!(Path.join([base, "companies/acme/projects/blog/tasks/b.md"]), """
      ---
      kind: task/v1
      title: open one
      status: todo
      goal: ship-v1
      ---
      """)

      {:ok, _view, html} = live(conn, ~p"/companies")

      # Task rollup: 1 done / 2 total → 50% (1/2). The explicit 100 is
      # ignored at the aggregate level.
      assert html =~ "50%"
      assert html =~ "(1/2)"
    end

    # T9 — malformed goal/v1 files (bad YAML, map-valued scalars,
    # non-slug filenames) must be skipped silently by the shared loader
    # rather than crashing the /companies LiveView via `to_string/1` →
    # `Protocol.UndefinedError`.
    test "T9: malformed goal files are silently dropped, render survives",
         %{conn: conn, base: base} do
      goals_dir = Path.join([base, "companies", "acme", "goals"])
      File.mkdir_p!(goals_dir)

      # One valid goal so the card renders at all.
      File.write!(Path.join(goals_dir, "good-goal.md"), """
      ---
      kind: goal/v1
      id: good-goal
      name: shippable goal
      ---
      """)

      # Unclosed flow sequence — unparseable frontmatter → dropped.
      File.write!(Path.join(goals_dir, "broken.md"), """
      ---
      kind: goal/v1
      id: broken
      tags: [a, b
      ---
      """)

      # Map-valued status would crash a naive `to_string/1` → dropped/coerced.
      File.write!(Path.join(goals_dir, "weird.md"), """
      ---
      kind: goal/v1
      id: weird
      status:
        nested: map
      ---
      """)

      # Non-slug filename → skipped by the `Slug.valid?` gate.
      File.write!(Path.join(goals_dir, "Bad Caps.md"), """
      ---
      kind: goal/v1
      id: x
      ---
      """)

      {:ok, _view, html} = live(conn, ~p"/companies")

      assert html =~ "gl-company-card__goals"
      refute html =~ "Protocol.UndefinedError"
    end
  end

  # TODO.md P1 — skip link renders as first focusable element + main
  # has a focusable target id.
  test "layout exposes a skip-to-content link", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies")
    assert html =~ ~s(href="#gl-main-content")
    assert html =~ ~s(class="gl-skip-link")
    assert html =~ ~s(id="gl-main-content")
  end

  describe "new-company slug probe" do
    test "reports `taken` when a dir with the slug exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/companies")
      render_click(view, "new_company", %{})
      html = render_change(view, "new_company_slug_input", %{"slug" => "acme"})
      assert html =~ "✗ taken"
      assert html =~ "gl-input--invalid"
    end

    test "reports `available` for a fresh slug", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/companies")
      render_click(view, "new_company", %{})
      html = render_change(view, "new_company_slug_input", %{"slug" => "widgetco"})
      assert html =~ "✓ available"
      assert html =~ "gl-input--valid"
    end

    test "reports `invalid` for a bad slug pattern", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/companies")
      render_click(view, "new_company", %{})
      html = render_change(view, "new_company_slug_input", %{"slug" => "Bad Slug"})
      assert html =~ "Lowercase letters"
    end

    test "create button disabled when slug is taken", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/companies")
      render_click(view, "new_company", %{})
      html = render_change(view, "new_company_slug_input", %{"slug" => "acme"})
      assert html =~ ~r/<button[^>]+disabled[^>]+>\s*create/
    end
  end

  describe "new-company wizard (paperclip-ux-gaps §13)" do
    test "guided submit navigates into CompanyLive with ?wizard=new_agent",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/companies")
      render_click(view, "new_company", %{})

      assert {:error, {:live_redirect, %{to: to}}} =
               render_submit(view, "new_company_create", %{
                 "slug" => "wizard-target",
                 "_guided" => "1"
               })

      assert to =~ "wizard=new_agent"
    end

    test "plain submit does NOT chain to the wizard", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/companies")
      render_click(view, "new_company", %{})

      html = render_submit(view, "new_company_create", %{"slug" => "plain-target"})
      # Still on OverviewLive, flash shown
      assert html =~ "Created company: plain-target"
    end
  end
end
