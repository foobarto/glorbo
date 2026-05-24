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

    # Gemini deep-dive F1 (CRITICAL): the original `Path.basename/1`
    # check could be bypassed with trailing `/.` because
    # `Path.basename("workspace/../AGENT.md/.")` returns `"."` while
    # `Path.expand/1` resolves to the real `AGENT.md` and the write
    # would proceed against `agent_root/AGENT.md`. Pin the canonical-
    # form check shut.
    test "refuses contract files even via Path.basename bypass forms",
         %{base: base, audit: audit} do
      for sneaky <- [
            "AGENT.md/.",
            "workspace/../AGENT.md/.",
            "stdout.log/.",
            "./AGENT.md/.",
            "./AGENT.md"
          ] do
        assert {:error, :contract_file} =
                 Agents.create_workspace_file("acme", "ceo", sneaky,
                   actor: "director",
                   base: base,
                   audit: audit
                 ),
               "expected #{inspect(sneaky)} to be refused as contract_file"
      end

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

    # PR #37 (codex round-5 F6 + pre-push P0 fix):
    # `create_workspace_file/4` allowed paths under dedicated-
    # subtree roots (`state/`, `inbox/`, `outbox/`, `history/`)
    # that have their own dedicated action functions with
    # stricter validation + audit shape. Authenticated dashboard
    # could plant a wake trigger or forged inbox message via
    # the file-manager UI, bypassing wake_agent / post_message
    # validation. The initial fix used `Path.split(Path.expand(rel))`
    # which always produces a leading `"/"` for relative input —
    # the first-segment check never matched and the guard was a
    # no-op. Normalisation via `Path.expand("/")` |>
    # `Path.relative_to("/")` makes it work AND collapses `..`
    # so smuggle attempts like `workspace/../state/wake.md` also
    # refuse.
    test "refuses dedicated-subtree paths (state / inbox / outbox / history)",
         %{base: base, audit: audit} do
      for forbidden <- [
            "state/wake-request-attack.md",
            "inbox/forged-message.md",
            "outbox/memory/exfil.md",
            "history/spoofed-entry.md",
            # Smuggle via `..` — the Path.expand("/")-based
            # normalisation in refuse_dedicated_subtree must
            # collapse `workspace/../state/` to `state/`.
            "workspace/../state/wake-via-traversal.md",
            "workspace/.././inbox/sneaky.md"
          ] do
        assert {:error, {:dedicated_subtree, _root}} =
                 Agents.create_workspace_file("acme", "ceo", forbidden,
                   actor: "director",
                   base: base,
                   audit: audit
                 ),
               "expected refusal for #{inspect(forbidden)}"
      end

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

    # C-055: the atomic write must not loosen an existing 0600 workspace
    # file to the process-umask default (0644). It preserves the original
    # inode's mode.
    test "preserves an existing 0600 file's mode on overwrite",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      path = Path.join(ag_dir, "workspace/doc.md")
      File.chmod!(path, 0o600)

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

      perms = Bitwise.band(File.lstat!(path).mode, 0o777)
      assert perms == 0o600, "expected 0600 preserved, got 0#{Integer.to_string(perms, 8)}"
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

    # C-099: retire is a decommission action — it MUST stop the running
    # AgentSupervisor child and unregister the heartbeat, not just rename
    # the dir. Before the fix, retire only renamed: the Agent.Server +
    # scheduler kept running with the old spec. Assert both the stop and
    # the unregister fire (company-scoped, with the right slug), and that
    # they happen BEFORE the directory is gone.
    test "C-099: stops the running agent + unregisters heartbeat on retire",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      parent = self()

      stop_fun = fn company, slug ->
        # The dir must still exist when the stop fires (stop-before-move).
        send(parent, {:stopped, company, slug, File.dir?(ag_dir)})
        :ok
      end

      unregister_fun = fn company, slug ->
        send(parent, {:unregistered, company, slug})
        :ok
      end

      assert {:ok, _} =
               Agents.retire("acme", "ceo",
                 actor: "director",
                 base: base,
                 audit: audit,
                 stop_agent_fun: stop_fun,
                 unregister_fun: unregister_fun
               )

      assert_received {:stopped, "acme", "ceo", true}
      assert_received {:unregistered, "acme", "ceo"}
      refute File.dir?(ag_dir)
    end

    # C-099: the decommission steps are best-effort — a not-running agent
    # (stop/unregister raising or exiting) must NOT fail the retire.
    test "C-099: retire still succeeds when the agent isn't running",
         %{base: base, audit: audit} do
      stop_fun = fn _c, _s -> exit(:noproc) end
      unregister_fun = fn _c, _s -> raise "boom" end

      assert {:ok, _} =
               Agents.retire("acme", "ceo",
                 actor: "director",
                 base: base,
                 audit: audit,
                 stop_agent_fun: stop_fun,
                 unregister_fun: unregister_fun
               )
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

    # C-040 / C-058: an agent can plant `workspace/loop -> .` (cycle)
    # or `workspace/root -> /` (huge tree) in its RW workspace before
    # retire. The pre-rename file-snapshot walk must NOT follow those
    # symlinks — otherwise it recurses unboundedly / walks the host.
    # Retire must still complete in bounded time without following them.
    test "does not follow a symlink loop planted in workspace",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      ws = Path.join(ag_dir, "workspace")
      File.mkdir_p!(ws)
      # Self-referential cycle: workspace/loop -> workspace
      File.ln_s!(ws, Path.join(ws, "loop"))
      # And a symlink to the filesystem root.
      File.ln_s!("/", Path.join(ws, "root"))

      # A genuine tracked-scope file so the walk has real work to do.
      File.write!(Path.join(ag_dir, "AGENT.md"), "---\nkind: agent/v1\n---\n")

      task =
        Task.async(fn ->
          Agents.retire("acme", "ceo", actor: "director", base: base, audit: audit)
        end)

      # If the walk followed `loop`/`root`, this would hang / OOM. The
      # lstat guard makes it return promptly.
      assert {:ok, %{archive_rel_path: _}} = Task.await(task, 5_000)
      refute File.dir?(ag_dir)
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

      # Poll for the Tx debounce to fire the auto-commit. The previous
      # `Process.sleep(1000)` flaked on aarch64 GHA runners (b48c5aa,
      # 6390127 bumped it twice with diminishing returns). Polling halts
      # the moment the new commit lands and only waits the full 5s on a
      # genuinely stuck Tx — deterministic on fast runners, robust on
      # slow ones.
      head = wait_for_new_commit!(base, initial_sha, 5_000)

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

      # debounce_ms 30 + hard_cap_ms 200; 1000ms wait per
      # v0.11.3's channels_test fix pattern (aarch64 CI flake at
      # 150ms, stable at 1000ms across both archs).
      Process.sleep(1000)

      {:ok, [head]} = HomeHistory.log(base: base, limit: 5)
      assert head.sha == initial_sha
    end

    # Poll-with-deadline replacement for `Process.sleep(N)` + log-read.
    # Returns the new head commit (sha != `initial_sha`) the moment it
    # lands; raises with a diagnostic if `timeout_ms` elapses without a
    # new commit. Used by the positive-path retire roundtrip that
    # previously flaked on aarch64 GHA at 1s sleeps.
    defp wait_for_new_commit!(base, initial_sha, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      poll_for_new_commit(base, initial_sha, deadline)
    end

    defp poll_for_new_commit(base, initial_sha, deadline) do
      case HomeHistory.log(base: base, limit: 1) do
        {:ok, [%{sha: sha} = head | _]} when sha != initial_sha ->
          head

        other ->
          if System.monotonic_time(:millisecond) >= deadline do
            flunk(
              "Tx auto-commit never fired within deadline. " <>
                "initial_sha=#{inspect(initial_sha)} " <>
                "log_result=#{inspect(other)}"
            )
          else
            Process.sleep(25)
            poll_for_new_commit(base, initial_sha, deadline)
          end
      end
    end
  end
end
