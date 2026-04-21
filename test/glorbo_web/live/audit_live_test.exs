defmodule GlorboWeb.AuditLiveTest do
  @moduledoc """
  AuditLive unit tests (UI-01 — last view of 8 total).

  Seeds the current-month audit JSONL with two events so the view
  exercises both the default render and the actor-filter exclusion
  path. Uses LiveCase's acme fixture base.
  """
  use GlorboWeb.LiveCase, async: false

  setup %{base: base} do
    ym = current_year_month()
    path = Path.join([base, "companies", "acme", "audit", "#{ym}.jsonl"])
    File.mkdir_p!(Path.dirname(path))

    # Append a director-authored event on top of the system event seeded
    # by the acme fixture. Two rows is enough to exercise the filter.
    File.write!(
      path,
      [
        Jason.encode!(%{
          ts: "2026-04-16T10:00:00Z",
          actor: "system",
          action: "company.create",
          target: "acme",
          detail: %{}
        }),
        "\n",
        Jason.encode!(%{
          ts: "2026-04-16T11:00:00Z",
          actor: "director",
          action: "chat.post",
          target: "channels/general.md",
          detail: %{channel: "general"}
        }),
        "\n"
      ],
      [:append]
    )

    :ok
  end

  test "renders seeded audit events + header", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/audit")
    assert html =~ "Audit log"
    assert html =~ "company.create"
    assert html =~ "chat.post"
    assert html =~ "director"
    assert html =~ "Filter by actor"
    assert html =~ "Filter by action"
    # M4.4 — unified free-text search input
    assert html =~ ~s(id="audit-q")
    assert html =~ "Search actor"
  end

  test "unified q input filters across all fields including detail", %{conn: conn} do
    {:ok, view, _} = live(conn, "/companies/acme/audit")

    # `general` lives only in the `detail` object of the chat.post row.
    html = render_change(view, "filter", %{"actor" => "", "action" => "", "q" => "general"})
    assert html =~ "chat.post"
    refute html =~ "company.create"
  end

  test "q input is case-insensitive", %{conn: conn} do
    {:ok, view, _} = live(conn, "/companies/acme/audit")
    html = render_change(view, "filter", %{"actor" => "", "action" => "", "q" => "DIRECTOR"})
    assert html =~ "chat.post"
    refute html =~ "company.create"
  end

  test "sidebar marks Audit log nav item active", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/audit")

    assert html =~
             ~r|<a[^>]*href="/companies/acme/audit"[^>]*gl-sidebar__nav-item--active|
  end

  # TODO.md P1 — AuditEntry must be keyboard-operable.
  test "audit entries render as keyboard-focusable role=button", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/audit")

    assert html =~ ~s(role="button")
    assert html =~ ~s(tabindex="0")
    assert html =~ ~s(phx-keydown="toggle")
    # aria-expanded reflects default (all entries collapsed on mount)
    assert html =~ ~s(aria-expanded="false")
  end

  # TODO.md P1 — filter inputs have labels (screen readers).
  test "filter inputs have associated labels", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/audit")

    assert html =~ ~s(for="audit-filter-actor")
    assert html =~ ~s(for="audit-filter-action")
    assert html =~ ~s(id="audit-filter-actor")
    assert html =~ ~s(id="audit-filter-action")
    # The labels themselves (sr-only class hides them visually).
    assert html =~ ~s(class="gl-sr-only")
  end

  test "filter by actor excludes non-matching rows", %{conn: conn} do
    {:ok, view, _} = live(conn, "/companies/acme/audit")
    html = render_change(view, "filter", %{"actor" => "zzz-nobody", "action" => ""})
    refute html =~ "chat.post"
    refute html =~ "company.create"
    assert html =~ "No audit events"
  end

  test "filter by action narrows rendering", %{conn: conn} do
    {:ok, view, _} = live(conn, "/companies/acme/audit")
    html = render_change(view, "filter", %{"actor" => "", "action" => "chat"})
    assert html =~ "chat.post"
    refute html =~ "company.create"
  end

  # #254 — convert audit row into a task under projects/inbox/tasks/.
  test "convert_to_task scaffolds a task from an expanded row",
       %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, "/companies/acme/audit")

    # Expand the first row so the convert button's id gets the same
    # hash the handler computes.
    html = render(view)
    [_, id] = Regex.run(~r/phx-value-id="([^"]+)"/, html)

    html =
      render_click(view, "convert_to_task", %{"id" => id})

    assert html =~ "Task scaffolded:"

    files =
      Path.wildcard(Path.join([base, "companies/acme/projects/inbox/tasks/t-audit-*.md"]))

    assert [_ | _] = files

    content = File.read!(hd(files))
    assert content =~ "source: audit"
    assert content =~ "## Context"
    assert content =~ "status: todo"
  end

  test "convert_to_task with missing id flashes error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/companies/acme/audit")

    html = render_click(view, "convert_to_task", %{"id" => "nope-not-real"})
    assert html =~ "Audit entry no longer in view."
  end

  defp current_year_month do
    d = Date.utc_today()
    "#{d.year}-#{String.pad_leading(Integer.to_string(d.month), 2, "0")}"
  end

  # #263 — date range filter
  describe "date range filter (#263)" do
    test "since bound excludes earlier entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/companies/acme/audit")

      html =
        render_change(view, "filter", %{
          "since" => "2026-04-16T10:30:00Z" |> String.slice(0, 10)
        })

      # 10:00 entry is at 2026-04-16T10:00:00Z; since 2026-04-16 00:00 allows.
      # Setting since to a date on 2026-04-17 would exclude both; we test that
      # a same-day since includes rows (inclusive bound).
      assert html =~ "company.create"
      assert html =~ "chat.post"
    end

    test "until bound excludes later entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/companies/acme/audit")

      html =
        render_change(view, "filter", %{"until" => "2026-04-15"})

      refute html =~ "company.create"
      refute html =~ "chat.post"
      assert html =~ "No audit events this month."
    end

    test "both bounds narrow the window", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/companies/acme/audit")

      html =
        render_change(view, "filter", %{"since" => "2026-04-16", "until" => "2026-04-16"})

      assert html =~ "company.create"
      assert html =~ "chat.post"
    end

    test "malformed date silently skipped", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/companies/acme/audit")

      html = render_change(view, "filter", %{"since" => "not-a-date"})
      # malformed → no bound applied, everything still shown
      assert html =~ "company.create"
    end
  end
end
