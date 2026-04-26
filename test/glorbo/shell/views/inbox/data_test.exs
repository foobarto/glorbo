defmodule Glorbo.Shell.Views.Inbox.DataTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Inbox.Data
  alias Glorbo.Test.TmpGlorboHome

  defp write!(base, rel, body) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
    full
  end

  defp seed_company(base, slug) do
    write!(base, "companies/#{slug}/company.md", "---\nkind: company/v1\nname: #{slug}\n---\n")
  end

  defp seed_task(base, slug, project, task_id, fm) do
    body =
      ["---", "kind: task/v1"] ++
        Enum.map(fm, fn {k, v} -> "#{k}: #{v}" end) ++ ["---", "# #{task_id}"]

    write!(
      base,
      "companies/#{slug}/projects/#{project}/tasks/#{task_id}.md",
      Enum.join(body, "\n") <> "\n"
    )
  end

  defp seed_sentinel(base, slug, agent, task_id) do
    body = """
    ---
    kind: sentinel-approval/v1
    agent: #{agent}
    task_path: projects/demo/tasks/#{task_id}.md
    task_id: #{task_id}
    requested_at: "2026-04-26T10:00:00Z"
    requesting_trigger: pickup
    ---
    """

    write!(
      base,
      "companies/#{slug}/agents/#{agent}/state/awaiting-approval-#{task_id}.md",
      body
    )
  end

  test "empty company → empty list" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")

    assert Data.load_approvals(base, "acme") == []
  end

  test "single sentinel + matching task → one row with title + assignee" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    seed_task(base, "acme", "demo", "demo-01", title: "Wire history", assigned_to: "engineer")
    seed_sentinel(base, "acme", "engineer", "demo-01")

    [row] = Data.load_approvals(base, "acme")
    assert row.task_id == "demo-01"
    assert row.task_path == "projects/demo/tasks/demo-01.md"
    assert row.title == "Wire history"
    assert row.assignee == "engineer"
  end

  test "task title falls back to task_id when frontmatter has no title" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    seed_task(base, "acme", "demo", "demo-02", assigned_to: "ceo")
    seed_sentinel(base, "acme", "ceo", "demo-02")

    [row] = Data.load_approvals(base, "acme")
    assert row.title == "demo-02"
    assert row.assignee == "ceo"
  end

  test "sentinel without matching task → row with nil task_path" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    seed_sentinel(base, "acme", "ghost", "missing-task")

    [row] = Data.load_approvals(base, "acme")
    assert row.task_id == "missing-task"
    assert row.task_path == nil
    assert row.title == "missing-task"
    assert row.assignee == nil
  end

  test "two sentinels return rows sorted by sentinel-path order" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    seed_task(base, "acme", "demo", "task-a", title: "Alpha", assigned_to: "engineer")
    seed_task(base, "acme", "demo", "task-b", title: "Bravo", assigned_to: "ceo")
    seed_sentinel(base, "acme", "engineer", "task-a")
    seed_sentinel(base, "acme", "ceo", "task-b")

    rows = Data.load_approvals(base, "acme")
    assert length(rows) == 2
    # Path.wildcard sorts lexicographically: agents/ceo/... before agents/engineer/...
    assert Enum.map(rows, & &1.task_id) == ["task-b", "task-a"]
  end

  test "non-approval sentinels in `state/` are not picked up" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")

    write!(
      base,
      "companies/acme/agents/engineer/state/stuck-on-foo.md",
      "---\nkind: sentinel-stuck/v1\n---\n"
    )

    assert Data.load_approvals(base, "acme") == []
  end
end
