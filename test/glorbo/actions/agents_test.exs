defmodule Glorbo.Actions.AgentsTest do
  @moduledoc """
  Unit tests for `Glorbo.Actions.Agents` (GEP-36 Round M-6).
  """
  use ExUnit.Case, async: false

  alias Glorbo.Actions.Agents
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
    ag_dir = Path.join([base, "companies", "acme", "agents", "ceo"])
    File.mkdir_p!(Path.join(ag_dir, "workspace"))
    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit, ag_dir: ag_dir}
  end

  describe "create_workspace_file/4" do
    test "writes empty file + emits agent.file_create audit",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      assert {:ok, %{abs_path: abs}} =
               Agents.create_workspace_file("acme", "ceo", "workspace/notes.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert abs == Path.join(ag_dir, "workspace/notes.md")
      assert File.read!(abs) == ""

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.file_create"
      assert event[:target] == "agents/ceo/workspace/notes.md"
      assert event[:company] == "acme"
      assert event[:agent] == "ceo"
    end

    test "refuses to overwrite existing file",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      path = Path.join(ag_dir, "workspace/existing.md")
      File.write!(path, "content")

      assert {:error, :already_exists} =
               Agents.create_workspace_file("acme", "ceo", "workspace/existing.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.read!(path) == "content"
      assert FakeAudit.calls(audit) == []
    end

    test "refuses contract files (threatmodel H9)",
         %{base: base, audit: audit} do
      assert {:error, :contract_file} =
               Agents.create_workspace_file("acme", "ceo", "AGENT.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert {:error, :contract_file} =
               Agents.create_workspace_file("acme", "ceo", "stdout.log",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "refuses path traversal",
         %{base: base, audit: audit} do
      assert {:error, :invalid_path} =
               Agents.create_workspace_file("acme", "ceo", "../../etc/passwd",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "refuses symlink on path (threatmodel H10)",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      decoy = Path.join(ag_dir, "decoy-dir")
      File.mkdir_p!(decoy)
      swapped = Path.join(ag_dir, "workspace_symlink")
      File.ln_s!(decoy, swapped)

      assert {:error, :symlink_in_path} =
               Agents.create_workspace_file(
                 "acme",
                 "ceo",
                 "workspace_symlink/under-symlink.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "write_workspace_file/5" do
    setup %{ag_dir: ag_dir} do
      File.write!(Path.join(ag_dir, "workspace/doc.md"), "old body\n")
      :ok
    end

    test "overwrites file + emits agent.file_write audit",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      assert {:ok, _} =
               Agents.write_workspace_file(
                 "acme",
                 "ceo",
                 "workspace/doc.md",
                 "new body\n",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.read!(Path.join(ag_dir, "workspace/doc.md")) == "new body\n"

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.file_write"
      assert event[:target] == "agents/ceo/workspace/doc.md"
    end

    test "refuses contract-file overwrite (H9)",
         %{base: base, audit: audit} do
      assert {:error, :contract_file} =
               Agents.write_workspace_file(
                 "acme",
                 "ceo",
                 "AGENT.md",
                 "pwned",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "trash_workspace_file/4" do
    setup %{ag_dir: ag_dir} do
      File.write!(Path.join(ag_dir, "workspace/doomed.md"), "goodbye\n")
      :ok
    end

    test "moves file into history/deleted/<ts>-<basename> + emits audit",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      assert {:ok, %{dest_rel_path: dest_rel}} =
               Agents.trash_workspace_file("acme", "ceo", "workspace/doomed.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert dest_rel =~ ~r|\Ahistory/deleted/\d+-doomed\.md\z|
      refute File.exists?(Path.join(ag_dir, "workspace/doomed.md"))
      assert File.exists?(Path.join(ag_dir, dest_rel))

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.file_trash"
      assert event[:target] == "agents/ceo/workspace/doomed.md"
      assert event[:dest] == Path.join(["agents", "ceo", dest_rel])
    end

    test "returns :not_found on missing file",
         %{base: base, audit: audit} do
      assert {:error, :not_found} =
               Agents.trash_workspace_file("acme", "ceo", "workspace/ghost.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    # Codex P2 (v0.8.0 pre-release): trash must refuse contract files
    # the same way create_workspace_file/write_workspace_file do. Pre-
    # fix, a non-LiveView caller could `trash_workspace_file/4` an
    # `AGENT.md` or `stdout.log` into `history/deleted/` — the UI
    # enforced H9 but the core action didn't.
    test "refuses contract files (threatmodel H9)",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      File.write!(Path.join(ag_dir, "AGENT.md"), "permission doc\n")

      assert {:error, :contract_file} =
               Agents.trash_workspace_file("acme", "ceo", "AGENT.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      # Original contract file still in place.
      assert File.exists?(Path.join(ag_dir, "AGENT.md"))
      assert FakeAudit.calls(audit) == []
    end
  end

  describe "retire/3" do
    test "moves agent dir to .archive/<slug>-<ts>/ + emits agent.retire audit",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      assert {:ok, %{archive_rel_path: archive_rel}} =
               Agents.retire("acme", "ceo",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert archive_rel =~ ~r|\Aagents/\.archive/ceo-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}|
      refute File.dir?(ag_dir)
      assert File.dir?(Path.join([base, "companies", "acme", archive_rel]))

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.retire"
      assert event[:target] == "agents/ceo"
      assert event[:dest] == archive_rel
    end

    test "returns :not_found on missing agent dir",
         %{base: base, audit: audit} do
      assert {:error, :not_found} =
               Agents.retire("acme", "ghost",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects invalid slug",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :agent, "../evil"}} =
               Agents.retire("acme", "../evil",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "GEP-33 Phase 2c: history wiring on retire/3" do
    # End-to-end roundtrip: scaffold a writer-style agent with a
    # tracked-scope subtree (AGENT.md + memory/), wire HomeHistory.Tx
    # so the dispatch captures into a real history repo, retire,
    # then verify:
    #   * working-tree shape (src gone, dest lives in .archive/)
    #   * audit event landed
    #   * git history captured the deletion of every tracked-scope
    #     file under the agent's old dir (archive subtree is
    #     excluded scope, so it does NOT show up as additions)
    #   * commit subject + actor identity match GEP-33 §4.2

    alias Glorbo.HomeHistory
    alias Glorbo.HomeHistory.Tx

    setup %{base: base, ag_dir: ag_dir} do
      # Seed tracked-scope content the retire should capture as
      # deletions. The outer setup only creates `workspace/`
      # (excluded scope), so add the canonical durable files
      # explicitly.
      File.write!(Path.join(ag_dir, "AGENT.md"), "---\nkind: agent/v1\nname: ceo\n---\n")
      File.write!(Path.join(ag_dir, "SOUL.md"), "soul body\n")
      File.write!(Path.join(ag_dir, "HEARTBEAT.md"), "heartbeat body\n")
      File.mkdir_p!(Path.join(ag_dir, "memory"))
      File.write!(Path.join(ag_dir, "memory/notes.md"), "memory body\n")

      # Stage a config.md so HomeHistory.init/1 stays away from it
      # (excluded scope per GEP-33 §3.2).
      File.write!(Path.join(base, "config.md"), "secret_key_base: x\n")

      {:ok, %{initial_commit: initial_sha}} = HomeHistory.init(base: base)

      # Per-test Tx server pinned to the tmp base + tight timers.
      {:ok, _tx_pid} =
        Tx.start_link(
          name: Glorbo.HomeHistory.Tx,
          base: base,
          debounce_ms: 30,
          hard_cap_ms: 200
        )

      {:ok, initial_sha: initial_sha}
    end

    test "retire roundtrip captures deletions as a history.agent.retire commit",
         %{base: base, audit: audit, initial_sha: initial_sha} do
      assert {:ok, %{archive_rel_path: archive_rel}} =
               Agents.retire("acme", "ceo",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      # Working-tree shape is correct.
      refute File.exists?(Path.join([base, "companies/acme/agents/ceo"]))
      assert File.exists?(Path.join([base, "companies/acme", archive_rel, "AGENT.md"]))
      assert File.exists?(Path.join([base, "companies/acme", archive_rel, "memory/notes.md"]))

      # Audit landed.
      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.retire"
      assert event[:target] == "agents/ceo"

      # Wait for the Tx debounce to fire the auto-commit. 1s gives
      # plenty of margin over the 200ms hard_cap on slow CI runners
      # (Agents.retire's Tx.with_tx finishes ≤ 100ms locally but can
      # take longer under aarch64 GHA load).
      Process.sleep(1000)

      {:ok, log} = HomeHistory.log(base: base, limit: 5)
      [head | _] = log
      refute head.sha == initial_sha
      assert head.subject =~ "agent.retire: companies/acme/agents/ceo"
      assert head.author_name == "Director"

      # Inspect commit body via git directly.
      {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
      assert body =~ "Glorbo-Actor: director"
      assert body =~ "Glorbo-Action: agent.retire"

      # The Glorbo-Paths trailer should reference the deleted source
      # files (AGENT.md, SOUL.md, HEARTBEAT.md, memory/notes.md).
      assert body =~ "agents/ceo/AGENT.md"
      assert body =~ "agents/ceo/SOUL.md"
      assert body =~ "agents/ceo/memory/notes.md"

      # Verify the commit's diff actually staged DELETIONS — every
      # named-status line for our tracked source files should be `D`.
      {name_status, 0} =
        System.cmd("git", ["log", "-1", "--name-status", "--pretty=%H"], cd: base)

      # Each tracked-scope file under the old agent dir lands as `D`.
      assert name_status =~ ~r/^D\s+companies\/acme\/agents\/ceo\/AGENT\.md/m
      assert name_status =~ ~r/^D\s+companies\/acme\/agents\/ceo\/SOUL\.md/m
      assert name_status =~ ~r/^D\s+companies\/acme\/agents\/ceo\/HEARTBEAT\.md/m
      assert name_status =~ ~r/^D\s+companies\/acme\/agents\/ceo\/memory\/notes\.md/m

      # And NO additions under .archive/ — that subtree is excluded
      # per GEP-33 §3.2 / Phase 2c-3 follow-up.
      refute name_status =~ ~r/^A\s+.*\.archive\//m
    end

    test "retire with non-existent agent does not produce a history commit",
         %{base: base, audit: audit, initial_sha: initial_sha} do
      assert {:error, :not_found} =
               Agents.retire("acme", "ghost",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      Process.sleep(150)

      {:ok, [head]} = HomeHistory.log(base: base, limit: 5)
      assert head.sha == initial_sha
    end
  end
end
