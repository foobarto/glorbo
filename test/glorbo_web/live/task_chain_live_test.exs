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
        "detail" => %{"from" => "director", "to" => "ceo"}
      })

    File.write!(path, entry <> "\n")

    {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-3/chain")

    assert html =~ "chain drift"
    assert html =~ "not in audit log"
    assert html =~ "audit cross-reference"
    # Codex P3: reassign from/to land under `detail` in JSONL.
    # Chain view must read from there, not top-level.
    assert html =~ "director"
    assert html =~ "ceo"
  end

  test "redirects on unknown task_id", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies/acme/kanban"}}} =
             live(conn, "/companies/acme/tasks/ghost-1/chain")
  end

  # GEP-41 rollout item 6 — peer-review audits render inline in the
  # chain view so directors see the full review lifecycle without
  # navigating to the audit log.
  describe "peer-review events section (GEP-41)" do
    setup %{base: base} do
      File.write!(
        Path.join([base, "companies/acme/projects/foo/tasks/foo-77.md"]),
        """
        ---
        kind: task/v1
        id: foo-77
        title: review-tracked task
        status: pending-approval
        assigned_to: engineer
        severity: major
        peer_review_required: true
        ---
        body
        """
      )

      :ok
    end

    test "renders nothing when no peer_review audits recorded", %{conn: conn, base: _base} do
      # No audit seed → section is absent.
      {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-77/chain")
      refute html =~ "peer review · "
      refute html =~ "review requested"
    end

    test "renders peer_review.requested with reviewer + severity detail", %{
      conn: conn,
      base: base
    } do
      audit_dir = Path.join([base, "companies/acme/audit"])
      File.mkdir_p!(audit_dir)
      month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
      path = Path.join(audit_dir, "#{month}.jsonl")

      entry =
        Jason.encode!(%{
          "ts" => "2026-04-24T14:00:00Z",
          "action" => "peer_review.requested",
          "actor" => "system",
          "target" => "projects/foo/tasks/foo-77.md",
          "detail" => %{
            "reviewer" => "critiqueops",
            "severity" => "major"
          }
        })

      File.write!(path, entry <> "\n")

      {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-77/chain")

      assert html =~ "peer review · 1 event"
      assert html =~ "review requested"
      assert html =~ "reviewer critiqueops"
      assert html =~ "severity major"
    end

    test "renders task.peer_review.approve with verdict note", %{conn: conn, base: base} do
      audit_dir = Path.join([base, "companies/acme/audit"])
      File.mkdir_p!(audit_dir)
      month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
      path = Path.join(audit_dir, "#{month}.jsonl")

      entry =
        Jason.encode!(%{
          "ts" => "2026-04-24T14:30:00Z",
          "action" => "task.peer_review.approve",
          "actor" => "critiqueops",
          "target" => "projects/foo/tasks/foo-77.md",
          "verdict" => "approve",
          "detail" => %{
            "note" => "verified citations live 2026-04-24"
          }
        })

      File.write!(path, entry <> "\n")

      {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-77/chain")

      assert html =~ "peer review · 1 event"
      assert html =~ "verdict: approve"
      assert html =~ "verified citations live 2026-04-24"
      assert html =~ "by critiqueops"
    end

    test "combines requested + verdict + other chain audits coherently", %{
      conn: conn,
      base: base
    } do
      audit_dir = Path.join([base, "companies/acme/audit"])
      File.mkdir_p!(audit_dir)
      month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
      path = Path.join(audit_dir, "#{month}.jsonl")

      entries =
        [
          %{
            "ts" => "2026-04-24T14:00:00Z",
            "action" => "task.reassign",
            "target" => "projects/foo/tasks/foo-77.md",
            "actor" => "director",
            "detail" => %{"from" => "director", "to" => "engineer"}
          },
          %{
            "ts" => "2026-04-24T14:15:00Z",
            "action" => "peer_review.requested",
            "actor" => "system",
            "target" => "projects/foo/tasks/foo-77.md",
            "detail" => %{"reviewer" => "critiqueops", "severity" => "major"}
          },
          %{
            "ts" => "2026-04-24T14:45:00Z",
            "action" => "task.peer_review.revise",
            "actor" => "critiqueops",
            "target" => "projects/foo/tasks/foo-77.md",
            "verdict" => "revise",
            "detail" => %{"note" => "citation 3 returned 404"}
          }
        ]
        |> Enum.map_join("\n", &Jason.encode!/1)

      File.write!(path, entries <> "\n")

      {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-77/chain")

      # The peer-review section is a separate <details> block, so both
      # peer-review entries appear there while the reassign stays in
      # the audit cross-reference section above.
      assert html =~ "peer review · 2 events"
      assert html =~ "review requested"
      assert html =~ "verdict: revise"
      assert html =~ "citation 3 returned 404"
      assert html =~ "audit cross-reference"
    end
  end
end
