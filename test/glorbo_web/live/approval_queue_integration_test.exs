defmodule GlorboWeb.ApprovalQueueIntegrationTest do
  @moduledoc """
  Plan 04-02 Task 3 — UI-03 end-to-end verification.

  Boots the per-company supervision tree (AuditLog + Watcher + Gate +
  Router + Scheduler + BudgetTracker + AgentSupervisor), mounts the
  approval queue, clicks Approve on the seeded t-01 sentinel, and
  asserts that:

    1. `projects/website/tasks/t-01.md` frontmatter flips to
       `status: approved` (via `GlorboWeb.Actions.set_approval/4`
       → `Glorbo.TaskDefinition.write/2`).
    2. An `approval.approved` JSONL line lands in the current
       month's audit file.

  Tagged `:integration` + `:inotify` because the Watcher requires
  inotify-tools.
  """
  use GlorboWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :inotify

  setup %{base: base} do
    start_supervised!(
      {Glorbo.Company.Supervisor,
       [
         name: Glorbo.Test.UniqueName.gen("acme_approval_sup"),
         company: "acme",
         base: base
       ]}
    )

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

  test "approve click rewrites task frontmatter and emits audit event",
       %{conn: conn, base: base} do
    task_path =
      Path.join([base, "companies", "acme", "projects", "website", "tasks", "t-01.md"])

    original = File.read!(task_path)
    refute original =~ "status: approved"

    {:ok, view, _html} = live(conn, ~p"/companies/acme/approvals")
    render_click(view, "approve", %{"task_path" => "projects/website/tasks/t-01.md"})

    updated = File.read!(task_path)
    assert updated =~ "status: approved"

    audit_path =
      Path.join([base, "companies", "acme", "audit"])
      |> File.ls!()
      |> Enum.find(&String.ends_with?(&1, ".jsonl"))
      |> then(&Path.join([base, "companies", "acme", "audit", &1]))

    audit = File.read!(audit_path)
    assert audit =~ "approval.approved"
    assert audit =~ "director"
  end
end
