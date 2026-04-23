defmodule Glorbo.Approvals.GateTest do
  use Glorbo.DataCase, async: false

  alias Glorbo.Approvals.Gate
  alias Glorbo.Repo
  alias Glorbo.TaskDefinition
  alias Glorbo.TasksApprovalState
  alias Glorbo.Test.{GateHelpers, TmpGlorboHome}

  @company "acme"

  setup do
    base = TmpGlorboHome.setup()
    company_dir = Path.join([base, "companies", @company])
    File.mkdir_p!(Path.join(company_dir, "projects/foo/tasks"))
    File.mkdir_p!(Path.join(company_dir, "agents/engineer/state"))
    File.mkdir_p!(Path.join(company_dir, "history/tasks"))
    File.mkdir_p!(Path.join(company_dir, "audit"))

    audit_coll = self()

    audit_fun = fn _server, entry ->
      send(audit_coll, {:audit, entry})
      :ok
    end

    wake_coll = self()

    wake_fun = fn agent, trigger, task ->
      send(wake_coll, {:wake, agent, trigger, task})
      :ok
    end

    {:ok, base: base, company_dir: company_dir, audit_fun: audit_fun, wake_fun: wake_fun}
  end

  defp write_task(ctx, id, attrs) do
    # GEP-25 R26.2b — every task frontmatter must carry `kind: task/v1`.
    attrs = Keyword.put_new(attrs, :kind, "task/v1")

    fm_lines =
      attrs
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

    content = "---\n" <> fm_lines <> "\n---\n# #{id}\n\nBody.\n"
    path = Path.join([ctx.company_dir, "projects/foo/tasks", "#{id}.md"])
    File.write!(path, content)
    path
  end

  defp start_gate(ctx, opts \\ []) do
    defaults = [
      company: @company,
      base: ctx.base,
      audit_fun: ctx.audit_fun,
      agent_wake_fun: ctx.wake_fun,
      subscribe?: Keyword.get(opts, :subscribe?, false),
      repo: Repo
    ]

    full_opts = Keyword.merge(defaults, opts)

    {:ok, pid} = Gate.start_link(full_opts)
    %{pid: pid}
  end

  defp td_for(ctx, id, attrs) do
    path = write_task(ctx, id, attrs)
    {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: @company)
    {path, td}
  end

  # G1 — start_link returns a live pid
  test "G1: start_link returns an alive pid", ctx do
    %{pid: pid} = start_gate(ctx)
    assert Process.alive?(pid)
  end

  # G2 — request_approval writes sentinel + upserts DB + emits audit
  test "G2: request_approval writes sentinel + upserts DB + emits audit", ctx do
    %{pid: pid} = start_gate(ctx)

    {_path, td} =
      td_for(ctx, "t-01",
        title: "Dangerous",
        status: "pending-approval",
        requires_approval: "director"
      )

    assert :ok ==
             Gate.request_approval(pid, %{
               agent: "engineer",
               task_definition: td,
               requesting_trigger: :inbox
             })

    sentinel_path =
      Path.join([
        ctx.company_dir,
        "agents/engineer/state",
        "awaiting-approval-t-01.md"
      ])

    assert File.exists?(sentinel_path)
    sentinel_content = File.read!(sentinel_path)
    assert sentinel_content =~ "agent: engineer"
    assert sentinel_content =~ "task_id: t-01"
    assert sentinel_content =~ "projects/foo/tasks/t-01.md"
    assert sentinel_content =~ "requesting_trigger: inbox"

    row = Repo.get_by(TasksApprovalState, task_path: "projects/foo/tasks/t-01.md")
    assert row != nil
    assert row.status == "awaiting"
    assert row.agent_slug == "engineer"

    assert_receive {:audit, %{action: "approval.requested"} = entry}
    assert entry.agent == "engineer" or entry[:agent] == "engineer"
  end

  # G2b — request_approval rewrites assigned_to: director so the UI
  # reflects the Director as the current owner of the decision.
  test "G2b: request_approval reassigns task to director", ctx do
    %{pid: pid} = start_gate(ctx)

    {path, td} =
      td_for(ctx, "t-01b",
        title: "Dangerous",
        status: "pending-approval",
        assigned_to: "engineer",
        requires_approval: "director"
      )

    :ok =
      Gate.request_approval(pid, %{
        agent: "engineer",
        task_definition: td,
        requesting_trigger: :inbox
      })

    content = File.read!(path)
    assert content =~ "assigned_to: director"
    refute content =~ "assigned_to: engineer"
  end

  # G3 — request_approval is idempotent
  test "G3: duplicate request_approval is idempotent", ctx do
    %{pid: pid} = start_gate(ctx)

    {_path, td} =
      td_for(ctx, "t-03",
        title: "Dup",
        status: "pending-approval",
        requires_approval: "director"
      )

    req = %{agent: "engineer", task_definition: td, requesting_trigger: :inbox}
    assert :ok == Gate.request_approval(pid, req)
    assert :ok == Gate.request_approval(pid, req)

    sentinel_path =
      Path.join([ctx.company_dir, "agents/engineer/state", "awaiting-approval-t-03.md"])

    assert File.exists?(sentinel_path)

    # Only ONE DB row for this task_path
    rows = Repo.all(TasksApprovalState)
    matching = Enum.filter(rows, &(&1.task_path == "projects/foo/tasks/t-03.md"))
    assert length(matching) == 1

    # Collect all audit events emitted for this task
    events = collect_audit(200)

    requested =
      Enum.filter(events, fn e ->
        (e.action || e[:action]) == "approval.requested"
      end)

    # Exactly one approval.requested event (second call short-circuits
    # before auditing).
    assert length(requested) == 1
  end

  # G4 — approved flip via PubSub resolves approval
  test "G4: modified event with status: approved resolves approval + wakes agent", ctx do
    %{pid: pid} = start_gate(ctx)

    # Set up sentinel + DB state first
    {path, td} =
      td_for(ctx, "t-04",
        title: "ok",
        status: "pending-approval",
        requires_approval: "director"
      )

    :ok =
      Gate.request_approval(pid, %{
        agent: "engineer",
        task_definition: td,
        requesting_trigger: :inbox
      })

    # Flush the request audit
    _ = collect_audit(100)

    # Director "approves" by editing status
    File.write!(path, """
    ---
    kind: task/v1
    title: ok
    status: approved
    requires_approval: director
    ---
    # t-04

    Body.
    """)

    :ok = Gate.mark_director_decision(pid, "projects/foo/tasks/t-04.md")
    send(pid, {:file_event, "projects/foo/tasks/t-04.md", [:modified]})

    assert_receive {:wake, "engineer", :director_approval, task_map}, 500
    assert task_map.task_id == "t-04"
    assert task_map.trigger == :director_approval

    # Flush the Gate's mailbox — handle_info may still be finishing
    # File.rm after sending the wake message.
    _ = :sys.get_state(pid)

    # Sentinel removed
    sentinel_path =
      Path.join([ctx.company_dir, "agents/engineer/state", "awaiting-approval-t-04.md"])

    refute File.exists?(sentinel_path)

    # DB updated to approved
    row = Repo.get_by(TasksApprovalState, task_path: "projects/foo/tasks/t-04.md")
    assert row.status == "approved"

    # approval.granted audit
    assert_audit_within(:action, "approval.granted", 1_500)
  end

  # G5 — denied flip moves task to history/tasks/ + upserts denied state
  test "G5: modified event with status: denied moves task to history + emits denial", ctx do
    %{pid: pid} = start_gate(ctx)

    {path, td} =
      td_for(ctx, "t-05",
        title: "risky",
        status: "pending-approval",
        requires_approval: "director"
      )

    :ok =
      Gate.request_approval(pid, %{
        agent: "engineer",
        task_definition: td,
        requesting_trigger: :inbox
      })

    _ = collect_audit(100)

    File.write!(path, """
    ---
    kind: task/v1
    title: risky
    status: denied
    requires_approval: director
    denial_reason: too risky
    ---
    # t-05
    """)

    :ok = Gate.mark_director_decision(pid, "projects/foo/tasks/t-05.md")
    send(pid, {:file_event, "projects/foo/tasks/t-05.md", [:modified]})

    # Wait for resolution
    wait_until(fn ->
      row = Repo.get_by(TasksApprovalState, task_path: "projects/foo/tasks/t-05.md")
      row && row.status == "denied"
    end)

    row = Repo.get_by(TasksApprovalState, task_path: "projects/foo/tasks/t-05.md")
    assert row.status == "denied"
    assert row.reason == "too risky"

    # Task file moved to history/tasks/
    refute File.exists?(path)
    moved = Path.join([ctx.company_dir, "history/tasks", "t-05.md"])
    assert File.exists?(moved)

    # Sentinel removed
    sentinel_path =
      Path.join([ctx.company_dir, "agents/engineer/state", "awaiting-approval-t-05.md"])

    refute File.exists?(sentinel_path)

    assert_audit_within(:action, "approval.denied", 1_500)

    # No wake emitted on denial
    refute_received {:wake, _, _, _}
  end

  # G6 — approved flip where no sentinel exists → approval.spurious
  test "G6: approved without sentinel emits approval.spurious and no wake", ctx do
    %{pid: pid} = start_gate(ctx)

    {_path, _td} =
      td_for(ctx, "t-06",
        title: "pre-approved",
        status: "approved",
        requires_approval: "director"
      )

    send(pid, {:file_event, "projects/foo/tasks/t-06.md", [:modified]})

    assert_audit_within(:action, "approval.spurious", 1_500)
    refute_received {:wake, _, _, _}

    # No DB row created
    assert Repo.get_by(TasksApprovalState, task_path: "projects/foo/tasks/t-06.md") == nil
  end

  # G7 — non-approval status is ignored
  test "G7: status: in-progress event is ignored silently", ctx do
    %{pid: pid} = start_gate(ctx)

    {_path, _td} =
      td_for(ctx, "t-07",
        title: "wip",
        status: "in-progress",
        requires_approval: "director"
      )

    send(pid, {:file_event, "projects/foo/tasks/t-07.md", [:modified]})
    # Give the GenServer time to process
    _ = :sys.get_state(pid)

    refute_received {:audit, _}
    refute_received {:wake, _, _, _}
  end

  # G8 — non-projects paths are ignored
  test "G8: non-project path events are ignored", ctx do
    %{pid: pid} = start_gate(ctx)

    # Sentinel-file path (must NOT trigger feedback loop)
    send(
      pid,
      {:file_event, "agents/engineer/state/awaiting-approval-x.md", [:modified]}
    )

    # goals path
    send(pid, {:file_event, "projects/foo/goals/q2.md", [:modified]})

    _ = :sys.get_state(pid)
    refute_received {:audit, _}
    refute_received {:wake, _, _, _}
  end

  # G9 — unparseable task.md emits approval.parse_error, does not crash
  test "G9: corrupt task.md emits approval.parse_error and Gate stays alive", ctx do
    %{pid: pid} = start_gate(ctx)

    # Write truly corrupt YAML
    bad = Path.join([ctx.company_dir, "projects/foo/tasks/bad.md"])
    File.write!(bad, "---\ntitle: [unclosed\nstatus: approved\n---\nbody\n")

    send(pid, {:file_event, "projects/foo/tasks/bad.md", [:modified]})

    assert_audit_within(:action, "approval.parse_error", 1_500)
    assert Process.alive?(pid)
  end

  # G10 — agent_wake_fun :noproc tolerated
  test "G10: crashed agent wake returns :noproc but Gate completes approval", ctx do
    wake_fun = fn _a, _t, _tm -> :noproc end

    %{pid: pid} =
      start_gate(ctx, agent_wake_fun: wake_fun)

    {path, td} =
      td_for(ctx, "t-10",
        title: "ok",
        status: "pending-approval",
        requires_approval: "director"
      )

    :ok =
      Gate.request_approval(pid, %{
        agent: "engineer",
        task_definition: td,
        requesting_trigger: :inbox
      })

    _ = collect_audit(100)

    File.write!(path, """
    ---
    kind: task/v1
    title: ok
    status: approved
    requires_approval: director
    ---
    body
    """)

    :ok = Gate.mark_director_decision(pid, "projects/foo/tasks/t-10.md")
    send(pid, {:file_event, "projects/foo/tasks/t-10.md", [:modified]})

    assert_audit_within(:action, "approval.granted", 1_500)

    # Flush: handle_info may still be completing File.rm + upsert.
    _ = :sys.get_state(pid)

    # Sentinel still removed, DB still updated — the approval is
    # persisted even when the agent can't be woken.
    sentinel_path =
      Path.join([ctx.company_dir, "agents/engineer/state", "awaiting-approval-t-10.md"])

    refute File.exists?(sentinel_path)

    row = Repo.get_by(TasksApprovalState, task_path: "projects/foo/tasks/t-10.md")
    assert row.status == "approved"
  end

  # G11 — resolve_approval test shortcut (synthetic event)
  test "G11: resolve_approval shortcut resolves as if PubSub had delivered", ctx do
    %{pid: pid} = start_gate(ctx)

    {path, td} =
      td_for(ctx, "t-11",
        title: "ok",
        status: "pending-approval",
        requires_approval: "director"
      )

    :ok =
      Gate.request_approval(pid, %{
        agent: "engineer",
        task_definition: td,
        requesting_trigger: :inbox
      })

    _ = collect_audit(100)

    File.write!(path, """
    ---
    kind: task/v1
    title: ok
    status: approved
    requires_approval: director
    ---
    body
    """)

    assert :ok == GateHelpers.resolve_approval(pid, "projects/foo/tasks/t-11.md", "approved")

    assert_receive {:wake, "engineer", :director_approval, _}, 500
    assert_audit_within(:action, "approval.granted", 1_500)
  end

  # G12 — Gate crash + restart is stateless
  test "G12: Gate state is empty after crash + restart; subsequent event resolves correctly",
       ctx do
    %{pid: pid1} = start_gate(ctx)
    Process.unlink(pid1)
    Process.exit(pid1, :kill)

    # Wait until down
    ref = Process.monitor(pid1)
    assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 500

    # Start fresh Gate
    %{pid: pid2} = start_gate(ctx)
    assert Process.alive?(pid2)

    {path, td} =
      td_for(ctx, "t-12",
        title: "ok",
        status: "pending-approval",
        requires_approval: "director"
      )

    :ok =
      Gate.request_approval(pid2, %{
        agent: "engineer",
        task_definition: td,
        requesting_trigger: :inbox
      })

    _ = collect_audit(100)

    File.write!(path, """
    ---
    kind: task/v1
    title: ok
    status: approved
    requires_approval: director
    ---
    body
    """)

    :ok = Gate.mark_director_decision(pid2, "projects/foo/tasks/t-12.md")
    send(pid2, {:file_event, "projects/foo/tasks/t-12.md", [:modified]})
    assert_audit_within(:action, "approval.granted", 1_500)
  end

  # G13 — concurrent request_approval for different agents/tasks → 2 sentinels + 2 rows
  test "G13: independent request_approval calls produce isolated sentinels + DB rows", ctx do
    File.mkdir_p!(Path.join(ctx.company_dir, "agents/writer/state"))

    %{pid: pid} = start_gate(ctx)

    {_p1, td1} =
      td_for(ctx, "t-13a",
        title: "a",
        status: "pending-approval",
        requires_approval: "director"
      )

    {_p2, td2} =
      td_for(ctx, "t-13b",
        title: "b",
        status: "pending-approval",
        requires_approval: "director"
      )

    assert :ok ==
             Gate.request_approval(pid, %{
               agent: "engineer",
               task_definition: td1,
               requesting_trigger: :inbox
             })

    assert :ok ==
             Gate.request_approval(pid, %{
               agent: "writer",
               task_definition: td2,
               requesting_trigger: :inbox
             })

    assert File.exists?(
             Path.join([
               ctx.company_dir,
               "agents/engineer/state",
               "awaiting-approval-t-13a.md"
             ])
           )

    assert File.exists?(
             Path.join([
               ctx.company_dir,
               "agents/writer/state",
               "awaiting-approval-t-13b.md"
             ])
           )

    r1 = Repo.get_by(TasksApprovalState, task_path: "projects/foo/tasks/t-13a.md")
    r2 = Repo.get_by(TasksApprovalState, task_path: "projects/foo/tasks/t-13b.md")
    assert r1.agent_slug == "engineer"
    assert r2.agent_slug == "writer"
    assert r1.status == "awaiting"
    assert r2.status == "awaiting"
  end

  # G14 — concurrent request + resolve on the SAME task keeps single DB row consistent
  test "G14: concurrent request + resolve preserves single consistent DB row", ctx do
    %{pid: pid} = start_gate(ctx)

    {path, td} =
      td_for(ctx, "t-14",
        title: "ok",
        status: "pending-approval",
        requires_approval: "director"
      )

    :ok =
      Gate.request_approval(pid, %{
        agent: "engineer",
        task_definition: td,
        requesting_trigger: :inbox
      })

    File.write!(path, """
    ---
    kind: task/v1
    title: ok
    status: approved
    requires_approval: director
    ---
    body
    """)

    :ok = Gate.mark_director_decision(pid, "projects/foo/tasks/t-14.md")
    send(pid, {:file_event, "projects/foo/tasks/t-14.md", [:modified]})
    _ = :sys.get_state(pid)

    rows =
      Repo.all(TasksApprovalState)
      |> Enum.filter(&(&1.task_path == "projects/foo/tasks/t-14.md"))

    # Exactly one row — either awaiting or approved depending on order,
    # never duplicate.
    assert length(rows) == 1
    assert hd(rows).status in ["awaiting", "approved"]
  end

  # G15 — Gate subscribes on start (subscribe?: true default path)
  test "G15: Gate with subscribe?: true receives broadcast PubSub messages", ctx do
    %{pid: pid} =
      start_gate(ctx, subscribe?: true)

    {path, td} =
      td_for(ctx, "t-15",
        title: "ok",
        status: "pending-approval",
        requires_approval: "director"
      )

    :ok =
      Gate.request_approval(pid, %{
        agent: "engineer",
        task_definition: td,
        requesting_trigger: :inbox
      })

    _ = collect_audit(100)

    File.write!(path, """
    ---
    kind: task/v1
    title: ok
    status: approved
    requires_approval: director
    ---
    body
    """)

    :ok = Gate.mark_director_decision(pid, "projects/foo/tasks/t-15.md")

    :ok =
      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:projects",
        {:file_event, "projects/foo/tasks/t-15.md", [:modified]}
      )

    assert_audit_within(:action, "approval.granted", 1_500)
  end

  # G16 — threatmodel H4 regression: agent file-write without a Director mark
  # is treated as a self-approval attempt. Gate reverts status to "awaiting"
  # and emits approval.self_approval_rejected. No agent wake.
  test "G16: agent self-approval flip is reverted + audited", ctx do
    %{pid: pid} = start_gate(ctx)

    {path, td} =
      td_for(ctx, "t-16",
        title: "ok",
        status: "pending-approval",
        requires_approval: "director"
      )

    :ok =
      Gate.request_approval(pid, %{
        agent: "engineer",
        task_definition: td,
        requesting_trigger: :inbox
      })

    _ = collect_audit(100)

    # Agent writes status: approved directly (bypass).
    File.write!(path, """
    ---
    kind: task/v1
    title: ok
    status: approved
    requires_approval: director
    ---
    body
    """)

    # No `Gate.mark_director_decision` call — this simulates an agent
    # bypass, not a Director action.
    send(pid, {:file_event, "projects/foo/tasks/t-16.md", [:modified]})

    # Should NOT wake the agent.
    refute_receive {:wake, _, _, _}, 200

    assert_audit_within(:action, "approval.self_approval_rejected", 1_500)

    # File must have been reverted back to awaiting.
    {:ok, reverted} = Glorbo.TaskDefinition.parse_file(path, base: ctx.base, company: "acme")
    assert reverted.status == "awaiting"

    # DB row stays in "awaiting".
    row = Repo.get_by(TasksApprovalState, task_path: "projects/foo/tasks/t-16.md")
    assert row.status == "awaiting"
  end

  # ---- helpers ---------------------------------------------------------

  defp collect_audit(timeout_ms) do
    collect_audit([], timeout_ms)
  end

  defp collect_audit(acc, timeout_ms) do
    receive do
      {:audit, entry} -> collect_audit([entry | acc], timeout_ms)
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end

  defp assert_audit_within(_key, expected_action, timeout_ms) do
    assert_receive {:audit, %{action: ^expected_action}}, timeout_ms
  end

  defp wait_until(fun, remaining \\ 50) do
    cond do
      fun.() ->
        :ok

      remaining == 0 ->
        :timeout

      true ->
        Process.sleep(10)
        wait_until(fun, remaining - 1)
    end
  end
end
