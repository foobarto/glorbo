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

      # Seed goals on company.md and a project with tasks tagged
      # to those goals — one done, one in-progress. Expected
      # rollup: 2 goals, 3 tasks total, 1 done → 33%.
      File.write!(Path.join(co_dir, "company.md"), """
      ---
      kind: company/v1
      slug: acme
      name: acme
      goals:
        - slug: ship-v1
          title: Ship v1
          status: active
        - slug: docs
          title: Docs pass
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
