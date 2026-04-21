defmodule GlorboWeb.Components.SidebarTest do
  @moduledoc """
  `GlorboWeb.Components.Sidebar` — sentinel counter regression
  test (Round 8 badge/list mismatch).

  An `awaiting-approval-<slug>.md` whose `<slug>` doesn't match
  any task file in `projects/*/tasks/` is **not** counted by the
  Approvals badge, because ApprovalQueueLive and InboxLive filter
  those orphan sentinels out. A badge counting them would lead
  directors to a "1 pending" button that opens an empty list —
  user-visible lying.
  """
  use ExUnit.Case, async: true

  alias GlorboWeb.Components.Sidebar

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-sidebar-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  defp seed(base, company, opts) do
    co_dir = Path.join([base, "companies", company])
    File.mkdir_p!(Path.join([co_dir, "agents", "ceo", "state"]))
    File.mkdir_p!(Path.join([co_dir, "projects", "abc", "tasks"]))

    for task_id <- Keyword.get(opts, :tasks, []) do
      File.write!(
        Path.join([co_dir, "projects", "abc", "tasks", "#{task_id}.md"]),
        "---\ntitle: #{task_id}\nstatus: todo\n---\n\nbody\n"
      )
    end

    for sentinel_id <- Keyword.get(opts, :sentinels, []) do
      File.write!(
        Path.join([co_dir, "agents", "ceo", "state", "awaiting-approval-#{sentinel_id}.md"]),
        "---\nrequested_at: \"2026-04-21T00:00:00Z\"\n---\n\npending\n"
      )
    end

    :ok
  end

  test "counts matching sentinels (task exists)", %{base: base} do
    seed(base, "acme", tasks: ["abc-01"], sentinels: ["abc-01"])
    assert 1 == Sidebar.count_pending_approvals_for_test("acme", base)
  end

  test "orphan sentinels (no matching task file) are NOT counted", %{base: base} do
    seed(base, "acme", tasks: [], sentinels: ["ghost-9"])
    assert 0 == Sidebar.count_pending_approvals_for_test("acme", base)
  end

  test "mixed: counts live, skips orphan", %{base: base} do
    seed(base, "acme", tasks: ["abc-01"], sentinels: ["abc-01", "ghost-9"])
    assert 1 == Sidebar.count_pending_approvals_for_test("acme", base)
  end

  test "malformed task_id (no -N suffix) is skipped", %{base: base} do
    seed(base, "acme", tasks: [], sentinels: ["deploy-prod"])
    assert 0 == Sidebar.count_pending_approvals_for_test("acme", base)
  end

  test "nil company → 0", %{base: base} do
    assert 0 == Sidebar.count_pending_approvals_for_test(nil, base)
  end

  test "missing company dir → 0", %{base: base} do
    assert 0 == Sidebar.count_pending_approvals_for_test("never-existed", base)
  end
end
