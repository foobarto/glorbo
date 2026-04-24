defmodule GlorboWeb.TaskChainLiveTest do
  @moduledoc """
  `GlorboWeb.TaskChainLive` — `/companies/:company/tasks/:task_id/chain`.
  Covers the empty-chain view, populated-chain rendering, and drift
  detection when the handoff_chain frontmatter and the audit log
  disagree (GEP-40 chain audit).
  """
  use GlorboWeb.LiveCase, async: false

  setup %{base: base} do
    tasks_dir = Path.join([base, "companies/acme/projects/foo/tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([base, "companies/acme/projects/foo/project.md"]), """
    ---
    slug: foo
    name: foo
    ---
    # foo
    """)

    :ok
  end

  test "empty-chain task renders the no-handoffs copy", %{conn: conn, base: base} do
    File.write!(
      Path.join([base, "companies/acme/projects/foo/tasks/foo-1.md"]),
      """
      ---
      kind: task/v1
      id: foo-1
      title: fresh
      status: todo
      assigned_to: ceo
      ---
      body
      """
    )

    {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-1/chain")

    assert html =~ "chain /"
    assert html =~ "No handoffs recorded"
    refute html =~ "chain drift"
  end

  test "populated handoff_chain renders one entry per hop", %{conn: conn, base: base} do
    File.write!(
      Path.join([base, "companies/acme/projects/foo/tasks/foo-2.md"]),
      """
      ---
      kind: task/v1
      id: foo-2
      title: multi-hop task
      status: in-progress
      assigned_to: engineer
      requested_by: director
      handoff_chain:
        - from: director
          reason: initial dispatch
          to: ceo
          ts: "2026-04-24T14:00:00Z"
        - from: ceo
          reason: needs plan first
          to: researcher
          ts: "2026-04-24T14:05:00Z"
        - from: researcher
          reason: plan done, implement
          to: engineer
          ts: "2026-04-24T14:35:00Z"
      ---
      body
      """
    )

    {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-2/chain")

    assert html =~ "3 steps"
    assert html =~ "requested by"
    assert html =~ "director"
    assert html =~ "ceo"
    assert html =~ "researcher"
    assert html =~ "engineer"
    assert html =~ "initial dispatch"
    assert html =~ "plan done, implement"
    # No audit events seeded → no drift (chain=3, audit=0 → drift WARN
    # on audit-less entries). Seeded audit log is absent for this test
    # so drift fires; that's tested separately below.
  end

  test "drift warning fires when chain and audit disagree", %{conn: conn, base: base} do
    # Chain has 2 entries; audit has 1 reassign → drift (missing audit).
    File.write!(
      Path.join([base, "companies/acme/projects/foo/tasks/foo-3.md"]),
      """
      ---
      kind: task/v1
      id: foo-3
      title: drift task
      status: todo
      assigned_to: engineer
      handoff_chain:
        - from: director
          reason: initial
          to: ceo
          ts: "2026-04-24T14:00:00Z"
        - from: ceo
          reason: plan first
          to: engineer
          ts: "2026-04-24T14:05:00Z"
      ---
      body
      """
    )

    audit_dir = Path.join([base, "companies/acme/audit"])
    File.mkdir_p!(audit_dir)

    month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
    path = Path.join(audit_dir, "#{month}.jsonl")

    entry =
      Jason.encode!(%{
        "ts" => "2026-04-24T14:00:00Z",
        "action" => "task.reassign",
        "target" => "projects/foo/tasks/foo-3.md",
        "actor" => "director",
        "from" => "director",
        "to" => "ceo"
      })

    File.write!(path, entry <> "\n")

    {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-3/chain")

    assert html =~ "chain drift"
    assert html =~ "not in audit log"
    assert html =~ "audit cross-reference"
  end

  test "redirects on unknown task_id", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies/acme/kanban"}}} =
             live(conn, "/companies/acme/tasks/ghost-1/chain")
  end
end
