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
end
