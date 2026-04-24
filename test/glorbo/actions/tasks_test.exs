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
                 base: base,
                 audit: audit
               )
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
  end
end
