defmodule GlorboWeb.Components.SidebarTest do
  @moduledoc """
  `GlorboWeb.Components.Sidebar` — sentinel counter regression
  test (Round 8 badge/list mismatch).

  An `awaiting-approval-<slug>.md` whose `<slug>` doesn't match
  any task file in `projects/*/tasks/` is **not** counted by the
  sidebar's pending-approvals badge (now displayed on the Inbox
  nav item since backlog #14 folded ApprovalQueueLive into
  InboxLive). A badge counting orphan sentinels would lead
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

  # R22 — memory count helper used by the sidebar `fa-brain` badge.
  # Filename filter must mirror `Glorbo.Agent.Memory` so invalid
  # files never inflate the count shown to the director.
  describe "count_memory_files_for_test/2 — R22 badge count" do
    setup %{base: base} do
      agents_dir = Path.join([base, "companies", "acme", "agents"])
      File.mkdir_p!(Path.join([agents_dir, "ceo", "memory"]))
      {:ok, agents_dir: agents_dir}
    end

    test "counts only valid memory filenames", %{agents_dir: agents_dir} do
      File.write!(Path.join([agents_dir, "ceo", "memory", "user_role.md"]), "")
      File.write!(Path.join([agents_dir, "ceo", "memory", "feedback_tests.md"]), "")
      File.write!(Path.join([agents_dir, "ceo", "memory", "project_layout.md"]), "")
      File.write!(Path.join([agents_dir, "ceo", "memory", "reference_prs.md"]), "")

      # These must be ignored:
      File.write!(Path.join([agents_dir, "ceo", "memory", "MEMORY.md"]), "")
      File.write!(Path.join([agents_dir, "ceo", "memory", "stray.md"]), "")
      File.write!(Path.join([agents_dir, "ceo", "memory", "other_type.md"]), "")
      File.write!(Path.join([agents_dir, "ceo", "memory", "user_UPPERCASE.md"]), "")
      File.write!(Path.join([agents_dir, "ceo", "memory", "user_role.txt"]), "")

      assert 4 == Sidebar.count_memory_files_for_test(agents_dir, "ceo")
    end

    test "no memory dir → 0", %{agents_dir: agents_dir} do
      assert 0 == Sidebar.count_memory_files_for_test(agents_dir, "no-memory-yet")
    end

    test "empty memory dir → 0", %{agents_dir: agents_dir} do
      File.mkdir_p!(Path.join([agents_dir, "lonely", "memory"]))
      assert 0 == Sidebar.count_memory_files_for_test(agents_dir, "lonely")
    end
  end
end
