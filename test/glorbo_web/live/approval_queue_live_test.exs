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

  test "renders the CompanyTabs strip with :approvals active", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/approvals")

    assert html =~
             ~r|<a[^>]*href="/companies/acme/approvals"[^>]*class="[^"]*gl-tab gl-tab--active|
  end

  test "empty state when no sentinels", %{conn: conn, base: base} do
    File.rm_rf!(Path.join([base, "companies", "acme", "agents", "ceo", "state"]))
    {:ok, _view, html} = live(conn, ~p"/companies/acme/approvals")
    assert html =~ "No approvals pending"
  end

  # M4.3 — prompt diff panel + keyboard nav.
  test "renders prompt diff panel showing selected task body", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/approvals")
    assert html =~ "gl-approvals__diff"
    # The seeded t-01 fixture has "Ship it." as its prompt body.
    assert html =~ "Ship it."
    # Keyboard hint surface.
    assert html =~ "approve"
    assert html =~ "deny"
  end

  test "y key approves the selected row", %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/approvals")

    render_hook(view, "keydown", %{"key" => "y"})

    # The task file's frontmatter status flips to `approved`. Sentinel
    # cleanup is Gate's responsibility (Phase 3) — not set_approval's.
    task =
      File.read!(
        Path.join([base, "companies", "acme", "projects", "website", "tasks", "t-01.md"])
      )

    assert task =~ ~r/status:\s*approved/
  end

  test "j/k move selection without crashing", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/approvals")

    render_hook(view, "keydown", %{"key" => "j"})
    render_hook(view, "keydown", %{"key" => "k"})

    assert render(view) =~ "gl-approvals__split"
  end
end
