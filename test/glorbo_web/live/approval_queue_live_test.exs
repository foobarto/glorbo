defmodule GlorboWeb.ApprovalQueueLiveTest do
  @moduledoc """
  Plan 04-02 Task 3 — `GlorboWeb.ApprovalQueueLive`
  (/companies/:company/approvals).

  Renders one ApprovalCard per `agents/*/state/awaiting-approval-*.md`
  sentinel. Uses the seeded acme fixture (t-01 already has
  `requires_approval: director`); the test plants the sentinel file
  that Phase 3's Gate would normally write.
  """
  use GlorboWeb.LiveCase, async: false

  setup %{base: base} do
    sentinel_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
    File.mkdir_p!(sentinel_dir)

    File.write!(
      Path.join(sentinel_dir, "awaiting-approval-t-01.md"),
      """
      ---
      requested_at: "2026-04-16T10:00:00Z"
      ---

      pending director approval
      """
    )

    :ok
  end

  test "renders the pending approval", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/approvals")
    assert html =~ "Deploy landing page"
    assert html =~ "Approve"
    assert html =~ "Deny"
  end

  test "empty state when no sentinels", %{conn: conn, base: base} do
    File.rm_rf!(Path.join([base, "companies", "acme", "agents", "ceo", "state"]))
    {:ok, _view, html} = live(conn, ~p"/companies/acme/approvals")
    assert html =~ "No approvals pending"
  end
end
