defmodule GlorboWeb.CostsLiveTest do
  use GlorboWeb.LiveCase, async: false

  alias Glorbo.{Budget, Repo}

  setup %{base: base} do
    # Seed an agent dir so list_all_agents finds something.
    agent_dir = Path.join([base, "companies/acme/agents/engineer"])
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(agent_dir, "AGENT.md"), """
    ---
    role: engineering
    provider: claude-code
    model: claude-opus-4-6
    ---
    """)

    # Seed ledger rows — this month + two months ago.
    {{y, m, _}, _} = :calendar.universal_time()
    this_month = "#{y}-" <> String.pad_leading("#{m}", 2, "0")
    {prev_y, prev_m} = if m > 2, do: {y, m - 2}, else: {y - 1, m + 10}
    prev_month = "#{prev_y}-" <> String.pad_leading("#{prev_m}", 2, "0")

    Repo.insert!(%Budget{
      agent_slug: "engineer",
      year_month: this_month,
      cost_usd_cents: 543
    })

    Repo.insert!(%Budget{
      agent_slug: "engineer",
      year_month: prev_month,
      cost_usd_cents: 221
    })

    {:ok, this_month: this_month, prev_month: prev_month}
  end

  test "renders summary + table with ledger data", %{conn: conn, this_month: ym} do
    {:ok, _view, html} = live(conn, "/costs")

    assert html =~ "costs"
    assert html =~ "this month"
    assert html =~ "top spender"
    # Engineer row with total $7.64 (543 + 221 cents).
    assert html =~ "engineer"
    assert html =~ "7.64"
    # This month's cell shows $5.43.
    assert html =~ "5.43"
    # Month header is present.
    assert html =~ ym
  end

  test "empty state when no ledger rows", %{conn: conn} do
    Repo.delete_all(Budget)
    {:ok, _view, html} = live(conn, "/costs")
    assert html =~ "No ledger rows yet"
  end

  test "agent slug links back to AgentLive", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/costs")
    assert html =~ ~s(href="/companies/acme/agents/engineer")
  end
end
