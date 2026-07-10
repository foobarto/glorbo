defmodule Glorbo.Actions.TasksTest do
  @moduledoc """
  Unit tests for `Glorbo.Actions.Tasks` (GEP-36 Round D + E).
  Each test isolates a tmp `~/.glorbo/`-shaped tree and a fake
  `AuditLog` sink so filesystem effect + audit emission are
  asserted independently of the LiveView stack.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Actions.Tasks
  alias Glorbo.Test.TmpGlorboHome

  defmodule FakeAudit do
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
    def calls(pid), do: GenServer.call(pid, :calls)

    @impl true
    def init(_opts), do: {:ok, []}

    @impl true
    def handle_call({:append, entry}, _from, state),
      do: {:reply, :ok, [entry | state]}

    def handle_call(:calls, _from, state),
      do: {:reply, Enum.reverse(state), state}
  end

  setup do
    base = TmpGlorboHome.setup()
    tasks_dir = Path.join([base, "companies", "acme", "projects", "demo", "tasks"])
    File.mkdir_p!(tasks_dir)
    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit, tasks_dir: tasks_dir}
  end

  describe "update/4" do
    setup %{tasks_dir: tasks_dir} do
      path = Path.join(tasks_dir, "demo-20.md")

      File.write!(path, """
      ---
      kind: task/v1
      id: demo-20
      title: Original title
      status: approved
      assigned_to: director
      priority: high
      severity: major
      requires_approval: director
      done_when: Original definition
      ---
      Original body
      """)

      {:ok, path: path, rel: "projects/demo/tasks/demo-20.md"}
    end

    test "atomically updates body and clears explicit blank fields", %{
      base: base,
      audit: audit,
      path: path,
      rel: rel
    } do
      params = %{
        "title" => "  Updated title  ",
        "status" => "approved",
        "assigned_to" => "",
        "priority" => "",
        "severity" => "",
        "requires_approval" => "",
        "done_when" => "",
        "body" => "  Updated body  "
      }

      assert {:ok, %{task_id: "demo-20", assigned_to: ""}} =
               Tasks.update("acme", rel, params,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      {:ok, task} = Glorbo.TaskDefinition.parse_file(path, base: base, company: "acme")
      assert task.title == "Updated title"
      assert task.assigned_to == nil
      assert task.priority == nil
      assert task.severity == nil
      assert task.requires_approval == nil
      assert task.done_when == nil
      assert String.trim(task.prompt_body) == "Updated body"

      [event] = FakeAudit.calls(audit)
      assert event.action == "task.edit"
      assert event.target == rel
      assert event.changed == Enum.sort(Map.keys(params))
    end

    test "omitted fields and body are preserved", %{
      base: base,
      audit: audit,
      path: path,
      rel: rel
    } do
      assert {:ok, %{changed: ["title"]}} =
               Tasks.update("acme", rel, %{"title" => "Only title changed"},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      {:ok, task} = Glorbo.TaskDefinition.parse_file(path, base: base, company: "acme")
      assert task.title == "Only title changed"
      assert task.priority == :high
      assert task.severity == :major
      assert task.requires_approval == :director
      assert task.prompt_body == "Original body\n"
    end

    test "approval status transitions must use the approval action", %{
      base: base,
      audit: audit,
      path: path,
      rel: rel
    } do
      File.write!(path, String.replace(File.read!(path), "status: approved", "status: pending"))
      before = File.read!(path)

      assert {:error, :approval_status_requires_gate} =
               Tasks.update("acme", rel, %{"status" => "approved"},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.read!(path) == before
      assert FakeAudit.calls(audit) == []
    end

    test "cannot clear a pending approval requirement", %{
      base: base,
      audit: audit,
      path: path,
      rel: rel
    } do
      File.write!(path, String.replace(File.read!(path), "status: approved", "status: pending"))

      assert {:error, :clears_required_approval} =
               Tasks.update("acme", rel, %{"requires_approval" => ""},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects phantom assignees before writing", %{
      base: base,
      audit: audit,
      path: path,
      rel: rel
    } do
      before = File.read!(path)

      assert {:error, :agent_not_found} =
               Tasks.update("acme", rel, %{"assigned_to" => "ghost_agent"},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.read!(path) == before
    end

    test "rejects keys outside the editor contract", %{base: base, audit: audit, rel: rel} do
      assert {:error, {:unsupported_editor_keys, ["peer_review_verdict"]}} =
               Tasks.update("acme", rel, %{"peer_review_verdict" => "approve"},
                 actor: "director",
                 base: base,
                 audit: audit
               )
    end
  end

  # ---------------------------------------------------------------------------
  # trash/3 (Round E)
  # ---------------------------------------------------------------------------

  describe "trash/3" do
    test "moves task into projects/<p>/history/deleted/ and emits task.trash audit",
         %{base: base, audit: audit, tasks_dir: tasks_dir} do
      src = Path.join(tasks_dir, "demo-01.md")
      File.write!(src, "---\nkind: task/v1\ntitle: t\nstatus: todo\n---\nbody\n")

      assert {:ok, %{dest_rel_path: dest_rel}} =
               Tasks.trash("acme", "projects/demo/tasks/demo-01.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      refute File.exists?(src)
      assert dest_rel =~ ~r|\Aprojects/demo/history/deleted/[^/]+-demo-01\.md\z|

      abs_dest = Path.join([base, "companies", "acme", dest_rel])
      assert File.exists?(abs_dest)

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "task.trash"
      assert event[:actor] == "director"
      assert event[:target] == "projects/demo/tasks/demo-01.md"
      assert event[:dest] == dest_rel
      assert event[:company] == "acme"
    end

    test "rejects invalid task_rel_path outside projects/<p>/tasks/",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_task_rel_path, _}} =
               Tasks.trash("acme", "channels/general.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects invalid company slug", %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :company, "../etc"}} =
               Tasks.trash("../etc", "projects/demo/tasks/demo-01.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "surfaces enoent for missing source file", %{base: base, audit: audit} do
      assert {:error, :enoent} =
               Tasks.trash("acme", "projects/demo/tasks/ghost-01.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "refuses to follow a symlinked source (M18-style defense)",
         %{base: base, audit: audit, tasks_dir: tasks_dir} do
      other = Path.join(tasks_dir, "real.md")
      File.write!(other, "real\n")
      link = Path.join(tasks_dir, "demo-02.md")
      File.ln_s!(other, link)

      assert {:error, {:not_regular_file, :symlink}} =
               Tasks.trash("acme", "projects/demo/tasks/demo-02.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.exists?(link)
      assert FakeAudit.calls(audit) == []
    end
  end

  # ---------------------------------------------------------------------------
  # reassign/4 (Round G — GEP-40)
  # ---------------------------------------------------------------------------

  describe "reassign/4" do
    setup %{tasks_dir: tasks_dir} do
      src = Path.join(tasks_dir, "demo-01.md")

      File.write!(src, """
      ---
      kind: task/v1
      id: demo-01
      title: initial task
      status: todo
      assigned_to: engineer
      priority: high
      ---
      body
      """)

      {:ok, src: src}
    end

    test "flips assigned_to and appends a handoff_chain entry", %{
      base: base,
      audit: audit,
      src: src
    } do
      assert {:ok,
              %{
                from: "engineer",
                to: "researcher",
                handoff_chain_len: 1
              }} =
               Tasks.reassign("acme", "projects/demo/tasks/demo-01.md", "researcher",
                 actor: "engineer",
                 reason: "need a literature review",
                 base: base,
                 audit: audit
               )

      content = File.read!(src)
      assert content =~ ~r/^assigned_to: researcher$/m
      assert content =~ ~r/^handoff_chain:\n/m
      assert content =~ ~r/^  - from: engineer$/m
      assert content =~ ~r/^    to: researcher$/m

      assert content =~ ~r/^    reason: "need a literature review"$/m

      # title + priority survive the rewrite (title re-emitted
      # via yaml_scalar so the space forces quotes).
      assert content =~ ~s(title: "initial task")
      assert content =~ "priority: high"

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "task.reassign"
      assert event[:actor] == "engineer"
      assert event[:from] == "engineer"
      assert event[:to] == "researcher"
      assert event[:target] == "projects/demo/tasks/demo-01.md"
    end

    test "subsequent reassigns append rather than replace chain", %{
      base: base,
      audit: audit
    } do
      {:ok, _} =
        Tasks.reassign("acme", "projects/demo/tasks/demo-01.md", "researcher",
          actor: "engineer",
          reason: "plan first",
          base: base,
          audit: audit
        )

      {:ok, %{handoff_chain_len: 2}} =
        Tasks.reassign("acme", "projects/demo/tasks/demo-01.md", "engineer",
          actor: "researcher",
          reason: "plan done, implement",
          base: base,
          audit: audit
        )

      {:ok, task} =
        Glorbo.TaskDefinition.parse_file(
          Path.join([base, "companies", "acme", "projects", "demo", "tasks", "demo-01.md"]),
          base: base,
          company: "acme"
        )

      assert length(task.handoff_chain) == 2
      assert Enum.at(task.handoff_chain, 0)[:to] == "researcher"
      assert Enum.at(task.handoff_chain, 1)[:to] == "engineer"
      assert task.assigned_to == "engineer"
    end

    test "rejects a no-op reassignment to the same assignee", %{base: base, audit: audit} do
      assert {:error, :noop} =
               Tasks.reassign("acme", "projects/demo/tasks/demo-01.md", "engineer",
                 actor: "engineer",
                 reason: "whatever",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects invalid to_agent slug", %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :agent, "../evil"}} =
               Tasks.reassign("acme", "projects/demo/tasks/demo-01.md", "../evil",
                 actor: "engineer",
                 reason: "x",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects empty reason", %{base: base, audit: audit} do
      assert {:error, :invalid_reason} =
               Tasks.reassign("acme", "projects/demo/tasks/demo-01.md", "researcher",
                 actor: "engineer",
                 reason: "",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  # ---------------------------------------------------------------------------
  # record_peer_review_verdict/4 (Round I — GEP-41)
  # ---------------------------------------------------------------------------

  describe "record_peer_review_verdict/4" do
    setup %{tasks_dir: tasks_dir} do
      src = Path.join(tasks_dir, "demo-99.md")

      File.write!(src, """
      ---
      kind: task/v1
      id: demo-99
      title: needs review
      status: pending-approval
      assigned_to: engineer
      severity: major
      peer_review_required: true
      reviewer: critiqueops
      ---
      body
      """)

      {:ok, src: src}
    end

    test "approve verdict: writes verdict fields and leaves status at pending-approval",
         %{base: base, audit: audit, src: src} do
      assert {:ok, %{verdict: :approve, next_status: "pending-approval"}} =
               Tasks.record_peer_review_verdict(
                 "acme",
                 "projects/demo/tasks/demo-99.md",
                 :approve,
                 actor: "critiqueops",
                 note: "looks good; ship it",
                 base: base,
                 audit: audit
               )

      content = File.read!(src)
      assert content =~ ~r/^peer_review_verdict: approve$/m
      assert content =~ ~r/^peer_review_verdict_by: critiqueops$/m
      assert content =~ ~r/^peer_review_verdict_at:/m
      assert content =~ ~s(peer_review_verdict_note: "looks good; ship it")
      assert content =~ ~r/^status: pending-approval$/m

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "task.peer_review.approve"
      assert event[:actor] == "critiqueops"
    end

    test "revise verdict flips status to in-progress",
         %{base: base, audit: audit, src: src} do
      assert {:ok, %{verdict: :revise, next_status: "in-progress"}} =
               Tasks.record_peer_review_verdict(
                 "acme",
                 "projects/demo/tasks/demo-99.md",
                 :revise,
                 actor: "critiqueops",
                 note: "the error path mishandles nil",
                 base: base,
                 audit: audit
               )

      content = File.read!(src)
      assert content =~ ~r/^status: in-progress$/m
      assert content =~ ~r/^peer_review_verdict: revise$/m
    end

    test "block verdict flips status to denied", %{base: base, audit: audit} do
      assert {:ok, %{verdict: :block, next_status: "denied"}} =
               Tasks.record_peer_review_verdict(
                 "acme",
                 "projects/demo/tasks/demo-99.md",
                 :block,
                 actor: "critiqueops",
                 note: "ships a SQL injection in the search filter",
                 base: base,
                 audit: audit
               )
    end

    # GEP-41 failure-mode: a block/revise verdict MUST carry a reason
    # (the reviewer prompt declares NOTE "required for revise / block").
    for verdict <- [:block, :revise] do
      test "#{verdict} verdict without a reason is rejected", %{base: base, audit: audit} do
        assert {:error, :reason_required} =
                 Tasks.record_peer_review_verdict(
                   "acme",
                   "projects/demo/tasks/demo-99.md",
                   unquote(verdict),
                   actor: "critiqueops",
                   base: base,
                   audit: audit
                 )

        # No audit row, no status flip — the verdict never landed.
        assert FakeAudit.calls(audit) == []
      end
    end

    test "rejects when peer_review_required is false", %{base: base, audit: audit, src: src} do
      File.write!(src, """
      ---
      kind: task/v1
      id: demo-99
      title: no review needed
      status: done
      ---
      body
      """)

      assert {:error, :not_required} =
               Tasks.record_peer_review_verdict(
                 "acme",
                 "projects/demo/tasks/demo-99.md",
                 :approve,
                 actor: "critiqueops",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects when a verdict was already recorded (append-only)",
         %{base: base, audit: audit} do
      # First verdict lands.
      {:ok, _} =
        Tasks.record_peer_review_verdict(
          "acme",
          "projects/demo/tasks/demo-99.md",
          :revise,
          actor: "critiqueops",
          note: "needs a regression test before this clears",
          base: base,
          audit: audit
        )

      # Second attempt is rejected.
      assert {:error, :already_decided} =
               Tasks.record_peer_review_verdict(
                 "acme",
                 "projects/demo/tasks/demo-99.md",
                 :approve,
                 actor: "critiqueops",
                 base: base,
                 audit: audit
               )

      # Only the first verdict emitted an audit event.
      assert length(FakeAudit.calls(audit)) == 1
    end

    test "rejects oversized note", %{base: base, audit: audit} do
      assert {:error, :invalid_note} =
               Tasks.record_peer_review_verdict(
                 "acme",
                 "projects/demo/tasks/demo-99.md",
                 :approve,
                 actor: "critiqueops",
                 note: String.duplicate("x", 501),
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    # Codex P1 (v0.8.0 pre-release): only the task's configured
    # reviewer may land a verdict. Pre-fix, any agent with
    # `tasks:update` could self-clear peer review by writing
    # `ACTIONS: verdict: approve` in their reply.
    test "rejects a verdict from a non-reviewer actor",
         %{base: base, audit: audit} do
      assert {:error, :wrong_reviewer} =
               Tasks.record_peer_review_verdict(
                 "acme",
                 "projects/demo/tasks/demo-99.md",
                 :approve,
                 actor: "engineer",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "default reviewer falls back to `critiqueops` when task.reviewer is unset",
         %{base: base, audit: audit, src: src} do
      # Rewrite the fixture without the `reviewer:` line.
      File.write!(src, """
      ---
      kind: task/v1
      id: demo-99
      title: needs review
      status: pending-approval
      assigned_to: engineer
      severity: major
      peer_review_required: true
      ---
      body
      """)

      # Wrong actor still rejected.
      assert {:error, :wrong_reviewer} =
               Tasks.record_peer_review_verdict(
                 "acme",
                 "projects/demo/tasks/demo-99.md",
                 :approve,
                 actor: "engineer",
                 base: base,
                 audit: audit
               )

      # Default reviewer (`critiqueops`) is accepted.
      assert {:ok, _} =
               Tasks.record_peer_review_verdict(
                 "acme",
                 "projects/demo/tasks/demo-99.md",
                 :approve,
                 actor: "critiqueops",
                 base: base,
                 audit: audit
               )
    end
  end

  # ---------------------------------------------------------------------------
  # create/4 severity auto-flip (GEP-41 D1, Round N)
  # ---------------------------------------------------------------------------

  describe "create/4 severity auto-flip" do
    test "severity: critical + no explicit peer_review_required → flipped to true",
         %{base: base, audit: audit} do
      assert {:ok, %{rel_path: rel}} =
               Tasks.create(
                 "acme",
                 "demo",
                 %{"title" => "ship it", "severity" => "critical"},
                 actor: "director",
                 base: base,
                 audit: audit,
                 task_id: "demo-auto-1"
               )

      abs = Path.join([base, "companies", "acme", rel])
      content = File.read!(abs)
      assert content =~ "peer_review_required: true"
    end

    test "severity: major + no explicit peer_review_required → flipped to true",
         %{base: base, audit: audit} do
      assert {:ok, %{rel_path: rel}} =
               Tasks.create(
                 "acme",
                 "demo",
                 %{"title" => "ship it", "severity" => "major"},
                 actor: "director",
                 base: base,
                 audit: audit,
                 task_id: "demo-auto-2"
               )

      content = File.read!(Path.join([base, "companies", "acme", rel]))
      assert content =~ "peer_review_required: true"
    end

    test "severity: minor does NOT auto-flip",
         %{base: base, audit: audit} do
      assert {:ok, %{rel_path: rel}} =
               Tasks.create(
                 "acme",
                 "demo",
                 %{"title" => "ship it", "severity" => "minor"},
                 actor: "director",
                 base: base,
                 audit: audit,
                 task_id: "demo-auto-3"
               )

      content = File.read!(Path.join([base, "companies", "acme", rel]))
      refute content =~ "peer_review_required"
    end

    test "explicit peer_review_required: false wins even with severity: critical",
         %{base: base, audit: audit} do
      assert {:ok, %{rel_path: rel}} =
               Tasks.create(
                 "acme",
                 "demo",
                 %{
                   "title" => "ship it",
                   "severity" => "critical",
                   "peer_review_required" => false
                 },
                 actor: "director",
                 base: base,
                 audit: audit,
                 task_id: "demo-auto-4"
               )

      content = File.read!(Path.join([base, "companies", "acme", rel]))
      # Written as the falsy path: kind: task/v1 + title + status: todo
      # only — build_frontmatter skips false-valued scalars.
      refute content =~ "peer_review_required"
    end

    test "explicit peer_review_required: true is preserved (no double-flip regression)",
         %{base: base, audit: audit} do
      assert {:ok, %{rel_path: rel}} =
               Tasks.create(
                 "acme",
                 "demo",
                 %{
                   "title" => "ship it",
                   "severity" => "critical",
                   "peer_review_required" => true
                 },
                 actor: "director",
                 base: base,
                 audit: audit,
                 task_id: "demo-auto-5"
               )

      content = File.read!(Path.join([base, "companies", "acme", rel]))
      assert content =~ "peer_review_required: true"
    end

    # C-062: a STRING "true" must not defeat the auto-flip. Pre-fix it
    # was treated as an explicit value, round-tripped through YAML as a
    # quoted `"true"`, and coerced back to `false` — silently bypassing
    # the gate on a critical task. The written value must parse as
    # boolean `true` and the parsed TaskDefinition must report
    # `peer_review_required: true`.
    test "string \"true\" peer_review_required does NOT bypass auto-flip on critical",
         %{base: base, audit: audit} do
      assert {:ok, %{rel_path: rel}} =
               Tasks.create(
                 "acme",
                 "demo",
                 %{
                   "title" => "ship it",
                   "severity" => "critical",
                   "peer_review_required" => "true"
                 },
                 actor: "director",
                 base: base,
                 audit: audit,
                 task_id: "demo-auto-6"
               )

      abs = Path.join([base, "companies", "acme", rel])
      content = File.read!(abs)
      # Must be an unquoted boolean, not the quoted string "true".
      assert content =~ ~r/^peer_review_required: true$/m
      refute content =~ ~s(peer_review_required: "true")

      {:ok, td} = Glorbo.TaskDefinition.parse_file(abs, base: base, company: "acme")
      assert td.peer_review_required == true
    end

    test "string \"false\" peer_review_required is honoured as the opt-out",
         %{base: base, audit: audit} do
      assert {:ok, %{rel_path: rel}} =
               Tasks.create(
                 "acme",
                 "demo",
                 %{
                   "title" => "ship it",
                   "severity" => "critical",
                   "peer_review_required" => "false"
                 },
                 actor: "director",
                 base: base,
                 audit: audit,
                 task_id: "demo-auto-7"
               )

      abs = Path.join([base, "companies", "acme", rel])
      {:ok, td} = Glorbo.TaskDefinition.parse_file(abs, base: base, company: "acme")
      assert td.peer_review_required == false
    end
  end

  # ---------------------------------------------------------------------------
  # archive_to_history/3 (Round M-5b)
  # ---------------------------------------------------------------------------

  describe "archive_to_history/3" do
    test "moves task into projects/<p>/history/tasks/ and emits task.delete",
         %{base: base, audit: audit, tasks_dir: tasks_dir} do
      src = Path.join(tasks_dir, "demo-05.md")
      File.write!(src, "---\nkind: task/v1\ntitle: t\nstatus: done\n---\n")

      assert {:ok, %{dest_rel_path: dest_rel, attachments_moved: false}} =
               Tasks.archive_to_history("acme", "projects/demo/tasks/demo-05.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert dest_rel == "projects/demo/history/tasks/demo-05.md"
      refute File.exists?(src)

      abs_dest = Path.join([base, "companies", "acme", dest_rel])
      assert File.exists?(abs_dest)

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "task.delete"
      assert event[:actor] == "director"
      assert event[:target] == "projects/demo/tasks/demo-05.md"
      assert event[:dest] == dest_rel
      assert event[:attachments_moved] == "false"
    end

    test "also moves the attachments directory when one exists",
         %{base: base, audit: audit, tasks_dir: tasks_dir} do
      src = Path.join(tasks_dir, "demo-06.md")
      File.write!(src, "---\nkind: task/v1\ntitle: t\nstatus: done\n---\n")

      attach_dir =
        Path.join([base, "companies", "acme", "projects", "demo", "attachments", "demo-06"])

      File.mkdir_p!(attach_dir)
      File.write!(Path.join(attach_dir, "notes.pdf"), "pdf-bytes")

      assert {:ok, %{attachments_moved: true}} =
               Tasks.archive_to_history("acme", "projects/demo/tasks/demo-06.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      dest_attach =
        Path.join([
          base,
          "companies",
          "acme",
          "projects",
          "demo",
          "history",
          "attachments",
          "demo-06"
        ])

      assert File.exists?(Path.join(dest_attach, "notes.pdf"))
      refute File.exists?(attach_dir)

      [event] = FakeAudit.calls(audit)
      assert event[:attachments_moved] == "true"
    end

    test "refuses to proceed when any ancestor of history/ is a symlink",
         %{base: base, audit: audit, tasks_dir: tasks_dir} do
      src = Path.join(tasks_dir, "demo-07.md")
      File.write!(src, "---\nkind: task/v1\ntitle: t\nstatus: done\n---\n")

      history_parent =
        Path.join([base, "companies", "acme", "projects", "demo", "history"])

      decoy =
        Path.join([base, "companies", "acme", "projects", "demo", "decoy"])

      File.mkdir_p!(decoy)
      File.ln_s!(decoy, history_parent)

      assert {:error, :symlink_in_path} =
               Tasks.archive_to_history("acme", "projects/demo/tasks/demo-07.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.exists?(src)
      assert FakeAudit.calls(audit) == []
    end

    test "rejects invalid task_rel_path",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_task_rel_path, _}} =
               Tasks.archive_to_history("acme", "channels/general.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "returns :enoent-style error when source task is missing",
         %{base: base, audit: audit} do
      assert {:error, _} =
               Tasks.archive_to_history("acme", "projects/demo/tasks/ghost.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "GEP-33 Phase 2c: home-history wiring on create/4" do
    alias Glorbo.HomeHistory
    alias Glorbo.HomeHistory.Tx

    setup %{base: base} do
      File.write!(Path.join(base, "config.md"), "secret_key_base: x\n")
      {:ok, %{initial_commit: initial_sha}} = HomeHistory.init(base: base)

      {:ok, _tx_pid} =
        Tx.start_link(
          name: Glorbo.HomeHistory.Tx,
          base: base,
          debounce_ms: 30,
          hard_cap_ms: 200
        )

      {:ok, initial_sha: initial_sha}
    end

    test "task.create commit lands with author + trailers + Glorbo-Paths",
         %{base: base, audit: audit} do
      assert {:ok, %{task_id: task_id}} =
               Tasks.create(
                 "acme",
                 "demo",
                 %{"title" => "Wire history layer", "assigned_to" => "ceo"},
                 actor: "agent:ceo",
                 base: base,
                 audit: audit
               )

      # debounce_ms 30 + hard_cap_ms 200; aarch64 CI runners need
      # the larger window per v0.11.3's channels_test fix pattern
      # (CI flaked at 150ms, stable at 1000ms across both archs).
      Process.sleep(1000)

      {:ok, [head | _]} = HomeHistory.log(base: base, limit: 5)
      assert head.subject =~ ~r/^task\.create:/
      assert head.author_name == "Agent ceo"

      {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
      assert body =~ "Glorbo-Actor: agent:ceo"
      assert body =~ "Glorbo-Action: task.create"
      assert body =~ "Glorbo-Paths: companies/acme/projects/demo/tasks/#{task_id}.md"
    end

    test "validation failure does NOT produce a history commit",
         %{base: base, audit: audit, initial_sha: initial_sha} do
      assert {:error, _} =
               Tasks.create(
                 "acme",
                 "demo",
                 %{"title" => ""},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      # debounce_ms 30 + hard_cap_ms 200; aarch64 CI runners need
      # the larger window per v0.11.3's channels_test fix pattern
      # (CI flaked at 150ms, stable at 1000ms across both archs).
      Process.sleep(1000)

      {:ok, [head]} = HomeHistory.log(base: base, limit: 5)
      assert head.sha == initial_sha
    end
  end

  # ---------------------------------------------------------------------------
  # move/4 (GEP-36 single write path for status flips)
  # ---------------------------------------------------------------------------

  describe "move/4" do
    setup %{tasks_dir: tasks_dir} do
      File.write!(Path.join(tasks_dir, "demo-01.md"), """
      ---
      kind: task/v1
      id: demo-01
      title: a task
      status: todo
      ---
      body
      """)

      :ok
    end

    test "flips status and emits task.move", %{base: base, audit: audit, tasks_dir: tasks_dir} do
      assert {:ok, %{from: "todo", to: "in-progress"}} =
               Tasks.move("acme", "projects/demo/tasks/demo-01.md", "in-progress",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.read!(Path.join(tasks_dir, "demo-01.md")) =~ ~r/^status: in-progress$/m

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "task.move"
      assert event[:target] == "projects/demo/tasks/demo-01.md"
      assert event[:changed] == ["status"]
      assert event[:detail] == %{new_status: "in-progress"}
    end

    test "rejects an unknown status", %{base: base, audit: audit} do
      assert {:error, {:invalid_status, "bogus"}} =
               Tasks.move("acme", "projects/demo/tasks/demo-01.md", "bogus",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    # Approval-lifecycle statuses go through Glorbo.Actions.set_approval/4
    # (which writes the Director-decision marker the Gate checks); move/4 must
    # refuse them so a shell/MCP caller can't approve/deny via a bare status flip
    # (the Gate would otherwise revert it as :agent_bypass).
    for status <- ["approved", "denied", "pending-approval"] do
      test "rejects moving to the approval-lifecycle status #{status}",
           %{base: base, audit: audit} do
        assert {:error, {:invalid_status, unquote(status)}} =
                 Tasks.move("acme", "projects/demo/tasks/demo-01.md", unquote(status),
                   actor: "director",
                   base: base,
                   audit: audit
                 )

        assert FakeAudit.calls(audit) == []
      end
    end

    test "rejects a path outside projects/<p>/tasks/", %{base: base, audit: audit} do
      assert {:error, {:invalid_task_rel_path, _}} =
               Tasks.move("acme", "channels/general.md", "done",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "refuses an approval-gate bypass (director-approval task → done)",
         %{base: base, audit: audit, tasks_dir: tasks_dir} do
      File.write!(Path.join(tasks_dir, "demo-01.md"), """
      ---
      kind: task/v1
      id: demo-01
      title: needs director
      status: pending
      requires_approval: director
      ---
      body
      """)

      assert {:error, :approval_gate_bypass} =
               Tasks.move("acme", "projects/demo/tasks/demo-01.md", "done",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      # Status untouched, no audit row.
      assert File.read!(Path.join(tasks_dir, "demo-01.md")) =~ ~r/^status: pending$/m
      assert FakeAudit.calls(audit) == []
    end

    test "allows an approved director-approval task to move to done",
         %{base: base, audit: audit, tasks_dir: tasks_dir} do
      File.write!(Path.join(tasks_dir, "demo-01.md"), """
      ---
      kind: task/v1
      id: demo-01
      title: approved
      status: approved
      requires_approval: director
      ---
      body
      """)

      assert {:ok, %{to: "done"}} =
               Tasks.move("acme", "projects/demo/tasks/demo-01.md", "done",
                 actor: "director",
                 base: base,
                 audit: audit
               )
    end
  end
end
