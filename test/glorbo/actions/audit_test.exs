defmodule Glorbo.Actions.AuditTest do
  @moduledoc """
  Unit tests for `Glorbo.Actions.Audit.scaffold_from_entry/3`
  (GEP-36 Round M-3).
  """
  use ExUnit.Case, async: false

  alias Glorbo.Actions.Audit
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
    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit}
  end

  defp sample_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "ts" => "2026-04-24T12:34:56Z",
        "actor" => "director",
        "action" => "task.reassign",
        "target" => "projects/demo/tasks/demo-01.md",
        "from" => "engineer",
        "to" => "researcher"
      },
      overrides
    )
  end

  describe "scaffold_from_entry/3 happy path" do
    test "writes a scaffolded task with canonical task-id shape, emits task.create audit",
         %{base: base, audit: audit} do
      entry = sample_entry()

      assert {:ok, %{task_id: tid, rel_path: rel, abs_path: abs}} =
               Audit.scaffold_from_entry("acme", entry,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert tid =~ ~r/\At-audit-20260424-task-reassign\z/
      assert rel == "projects/inbox/tasks/#{tid}.md"
      assert abs =~ ~r|companies/acme/projects/inbox/tasks/|

      content = File.read!(abs)
      assert content =~ "source: audit"
      assert content =~ "audit_ts: 2026-04-24T12:34:56Z"
      assert content =~ "**Actor**: director"
      assert content =~ "**Action**: task.reassign"
      assert content =~ ~s("action": "task.reassign")

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "task.create"
      assert event[:actor] == "director"
      assert event[:target] == rel
      assert event[:company] == "acme"
      assert event[:project] == "inbox"
      assert event["source"] == "audit"
      assert event["origin_action"] == "task.reassign"
      assert event["origin_ts"] == "2026-04-24T12:34:56Z"
    end

    test "quotes yaml-unsafe title characters",
         %{base: base, audit: audit} do
      entry = sample_entry(%{"action" => "foo: bar # baz"})

      assert {:ok, %{abs_path: abs}} =
               Audit.scaffold_from_entry("acme", entry,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.read!(abs) =~ ~s(title: "Follow up on audit event: director · foo: bar # baz")
    end

    test "de-duplicates id when the same action lands on the same date twice",
         %{base: base, audit: audit} do
      entry = sample_entry()

      assert {:ok, %{task_id: tid1}} =
               Audit.scaffold_from_entry("acme", entry,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert {:ok, %{task_id: tid2}} =
               Audit.scaffold_from_entry("acme", entry,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      refute tid1 == tid2
      assert tid2 == "#{tid1}-1"
    end
  end

  describe "scaffold_from_entry/3 threatmodel H6" do
    test "refuses when the .tmp sibling is a pre-planted dangling symlink",
         %{base: base, audit: audit} do
      tasks_dir =
        Path.join([base, "companies", "acme", "projects", "inbox", "tasks"])

      File.mkdir_p!(tasks_dir)

      # Dangling symlink at the .tmp path. File.exists? follows and
      # reports false → uniqify happily accepts the base task id →
      # refuse_if_symlink's lstat catches the link and errors out.
      entry = sample_entry()
      expected_id = "t-audit-20260424-task-reassign"
      tmp_path = Path.join(tasks_dir, "#{expected_id}.md.tmp")
      File.ln_s!("/nonexistent-target-for-threatmodel-h6", tmp_path)

      assert {:error, :not_a_regular_file} =
               Audit.scaffold_from_entry("acme", entry,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "scaffold_from_entry/3 validation" do
    test "rejects invalid company slug",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :company, "../etc"}} =
               Audit.scaffold_from_entry("../etc", sample_entry(),
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "fills safe defaults for missing entry fields",
         %{base: base, audit: audit} do
      assert {:ok, %{abs_path: abs}} =
               Audit.scaffold_from_entry("acme", %{},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      content = File.read!(abs)
      assert content =~ "**Actor**: system"
      assert content =~ "**Action**: unknown"
      assert content =~ "**Target**: "
    end
  end
end
