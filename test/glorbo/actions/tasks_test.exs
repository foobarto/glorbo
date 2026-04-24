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
end
