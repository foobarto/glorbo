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
end
