defmodule GlorboWeb.ActivityLiveTest do
  @moduledoc """
  ActivityLive — cross-company live activity feed (`/activity`).

  Seeds the current-month audit JSONL of the LiveCase fixture
  company with one event so the initial-load path is exercised.
  Real-time append is exercised by emitting a `{:audit_append,
  company, record}` broadcast on the `audit:all` topic and asserting
  the rendered HTML picks it up.
  """
  use GlorboWeb.LiveCase, async: false

  setup %{base: base} do
    ym = current_year_month()
    path = Path.join([base, "companies", "acme", "audit", "#{ym}.jsonl"])
    File.mkdir_p!(Path.dirname(path))

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
        "\n"
      ],
      [:append]
    )

    :ok
  end

  test "renders header + initial entries from every company", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/activity")

    assert html =~ "Activity"
    assert html =~ "live · all companies"
    assert html =~ "company.create"
    # Company tag link points at the per-company audit page.
    assert html =~ ~s(/companies/acme/audit)
  end

  test "shows the company filter dropdown with seeded companies", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/activity")
    assert html =~ ~s(<option value="acme")
    assert html =~ "All companies"
  end

  test "renders a real-time {:audit_append, company, record} broadcast", %{conn: conn} do
    {:ok, view, _} = live(conn, "/activity")

    # Directly emit on `audit:all` — same shape AuditLog.broadcast_append
    # produces in production.
    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "audit:all",
      {:audit_append, "acme",
       %{
         "ts" => "2026-04-16T12:00:00Z",
         "actor" => "director",
         "action" => "chat.post",
         "target" => "channels/general.md",
         "detail" => %{"channel" => "general"}
       }}
    )

    html = render(view)
    assert html =~ "chat.post"
    assert html =~ "director"
  end

  defp current_year_month do
    {:ok, dt} = DateTime.now("Etc/UTC")
    "#{dt.year}-#{String.pad_leading(Integer.to_string(dt.month), 2, "0")}"
  end
end
