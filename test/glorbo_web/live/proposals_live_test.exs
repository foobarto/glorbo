defmodule GlorboWeb.ProposalsLiveTest do
  @moduledoc """
  `GlorboWeb.ProposalsLive` — `/companies/:co/proposals` (GEP-28).
  """
  use GlorboWeb.LiveCase, async: false

  setup %{base: base} do
    dir = Path.join([base, "companies/acme/proposals"])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "hire-writer.md"), """
    ---
    kind: proposal/v1
    id: hire-writer
    subtype: hire
    status: pending-approval
    proposed_by: ceo
    proposed_at: "2026-04-23T09:00:00Z"
    requires_approval: director
    ---
    Need a Writer to cover weekly posts.

    Second paragraph should truncate.
    """)

    File.write!(Path.join(dir, "bump-budget.md"), """
    ---
    kind: proposal/v1
    id: bump-budget
    subtype: budget
    status: approved
    proposed_by: ceo
    proposed_at: "2026-04-22T12:00:00Z"
    approved_by: director
    approved_at: "2026-04-22T13:00:00Z"
    requires_approval: director
    ---
    Extra $50 for compute.
    """)

    :ok
  end

  test "renders pending + approved sections with counts", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/proposals")

    assert html =~ "pending"
    assert html =~ "hire-writer"
    assert html =~ "Need a Writer"
    assert html =~ "approved"
    assert html =~ "bump-budget"
    assert html =~ "1 pending"
    assert html =~ "1 approved"
    assert html =~ "0 denied"
  end

  test "approve flips pending-approval → approved on disk + audit",
       %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme/proposals")

    html = render_click(view, "approve", %{"id" => "hire-writer"})

    assert html =~ "Approved hire-writer"

    content = File.read!(Path.join([base, "companies/acme/proposals/hire-writer.md"]))
    assert content =~ "status: approved"
    assert content =~ "approved_by: director"
  end

  test "deny modal opens, deny_confirm writes denial_reason", %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme/proposals")

    html = render_click(view, "deny_prompt", %{"id" => "hire-writer"})
    assert html =~ "Deny hire-writer"
    assert html =~ ~s(name="reason")

    render_submit(view, "deny_confirm", %{"reason" => "Not in this quarter"})

    content = File.read!(Path.join([base, "companies/acme/proposals/hire-writer.md"]))
    assert content =~ "status: denied"
    assert content =~ "denial_reason: \"Not in this quarter\""
  end

  test "approve on non-pending proposal returns an error flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme/proposals")

    # `bump-budget` is already approved — flipping again must fail cleanly.
    html = render_click(view, "approve", %{"id" => "bump-budget"})

    assert html =~ "Approve failed"
    assert html =~ "not_pending"
  end
end
