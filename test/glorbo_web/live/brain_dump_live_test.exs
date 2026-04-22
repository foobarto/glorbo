defmodule GlorboWeb.BrainDumpLiveTest do
  @moduledoc """
  `GlorboWeb.BrainDumpLive` — `/companies/:co/braindump` (#230 T1-E).
  """
  use GlorboWeb.LiveCase, async: false

  alias Glorbo.BrainDump

  setup %{base: base} do
    File.write!(Path.join([base, "companies/acme/company.md"]), """
    ---
    slug: acme
    name: Acme
    ---
    """)

    :ok
  end

  test "renders capture surface + empty today list", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/braindump")
    assert html =~ "brain dump"
    assert html =~ "capture"
    assert html =~ "nothing captured today yet."
    assert html =~ "phx-submit=\"capture\""
  end

  test "submitting a dump appends to today's file + shows in the list",
       %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme/braindump")

    view
    |> form("form.gl-braindump__form", body: "refactor the dispatcher")
    |> render_submit()

    today = Date.utc_today() |> Date.to_iso8601()
    path = Path.join([base, "companies/acme/braindump/#{today}.md"])
    assert File.exists?(path)
    content = File.read!(path)
    assert content =~ "refactor the dispatcher"

    assert render(view) =~ "refactor the dispatcher"
  end

  test "convert → task creates an inbox task file and flashes the path",
       %{conn: conn, base: base} do
    {:ok, entry} = BrainDump.capture(base, "acme", "migrate audit to 2026")

    {:ok, view, _html} = live(conn, ~p"/companies/acme/braindump")

    html =
      view
      |> element("button[phx-value-ts='#{entry.ts}']")
      |> render_click()

    assert html =~ "Task scaffolded:"

    [task_file] =
      Path.wildcard(Path.join([base, "companies/acme/projects/inbox/tasks/inbox-*.md"]))

    body = File.read!(task_file)
    assert body =~ "source: braindump"
    assert body =~ entry.ts
  end

  test "rejects an empty capture", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme/braindump")

    html =
      view
      |> form("form.gl-braindump__form", body: "")
      |> render_submit()

    assert html =~ "Can&#39;t capture an empty dump."
  end

  test "unknown company redirects", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies"}}} =
             live(conn, ~p"/companies/ghost/braindump")
  end
end
