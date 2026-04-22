defmodule Glorbo.Filesystem.WatcherTest do
  use ExUnit.Case, async: false

  alias Glorbo.Filesystem.Watcher
  alias Glorbo.Test.TmpGlorboHome

  # `file_system` depends on inotify-tools on Linux. On hosts without it
  # (common on minimal dev boxes), the entire suite is excluded via the
  # `:inotify` tag — `test_helper.exs` flips this tag into the exclude
  # list when `inotifywait` is not on PATH. Production + CI MUST install
  # `inotify-tools` (Director's responsibility). A future Doctor check
  # will flag the missing dep explicitly.
  @moduletag :inotify

  # Start a watcher rooted at a fresh tmp dir. Returns {pid, company_dir, base}.
  defp start_watcher(overrides \\ []) do
    base = TmpGlorboHome.setup()
    company = "co_#{System.unique_integer([:positive])}"
    company_dir = Path.join([base, "companies", company])
    File.mkdir_p!(company_dir)
    # Pre-create every subdir the tests touch. Without these, the
    # intermediate `File.mkdir_p!` calls in `write!` emit inotify :create
    # events on bare directories that classify as :other and fire a
    # bogus reindex into the test mailbox. audit/ specifically is
    # required by wait_until_armed!'s arm probe (events under audit/
    # classify as :audit — no reindex, no PubSub).
    for sub <- ~w(
          audit channels projects
          agents/ceo/inbox agents/ceo/outbox agents/ceo/state
          agents/engineer/inbox agents/engineer/outbox agents/engineer/state
        ) do
      File.mkdir_p!(Path.join(company_dir, sub))
    end

    test_pid = self()

    default_reindex_fun =
      fn co, path -> send(test_pid, {:marked, co, path}) end

    opts =
      Keyword.merge(
        [
          company: company,
          base: base,
          name: Glorbo.Test.UniqueName.gen("watcher"),
          reindex_fun: default_reindex_fun
        ],
        overrides
      )

    {:ok, pid} = Watcher.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    wait_until_armed!(pid, company_dir)
    {pid, company, company_dir, base}
  end

  # inotifywait's watch is armed asynchronously after FileSystem.start_link/1
  # returns. Writes that land before the first inotify event is delivered
  # are dropped (the watch simply wasn't attached yet). On Fedora + brew
  # inotify-tools 4.x this window is ~hundreds of ms and flakes every
  # watcher test.
  #
  # Fix: run a disposable Task that subscribes to the Watcher's raw fs_pid
  # and touches a sentinel under `audit/` until it sees the event echoed
  # back. `audit/` is classified as :audit by the Watcher — no
  # reindex_fun + no PubSub broadcast — so the probe never leaks into the
  # test process's mailbox. When the Task exits, its FileSystem
  # subscription is cleaned up via the subscriber-DOWN monitor.
  defp wait_until_armed!(watcher_pid, company_dir) do
    %{fs_pid: fs_pid} = :sys.get_state(watcher_pid)

    sentinel =
      Path.join([company_dir, "audit", ".arm_probe_#{System.unique_integer([:positive])}"])

    parent = self()
    ref = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        :ok = FileSystem.subscribe(fs_pid)
        deadline = System.monotonic_time(:millisecond) + 5_000
        send(parent, {ref, arm_loop(fs_pid, sentinel, deadline)})
      end)

    try do
      receive do
        {^ref, :ok} ->
          :ok

        {^ref, :timeout} ->
          flunk("FileSystem watch never armed after 5s — inotify init wedged")

        {:DOWN, ^mon, :process, ^pid, reason} when reason != :normal ->
          flunk("arm probe crashed: #{inspect(reason)}")
      after
        6_000 ->
          Process.exit(pid, :kill)
          flunk("FileSystem watch never armed after 6s — arm probe stuck")
      end
    after
      File.rm(sentinel)
      Process.demonitor(mon, [:flush])
    end
  end

  defp arm_loop(fs_pid, sentinel, deadline) do
    File.write!(sentinel, "probe")

    receive do
      {:file_event, ^fs_pid, {_path, _events}} -> :ok
    after
      100 ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          arm_loop(fs_pid, sentinel, deadline)
        end
    end
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "start_link/1 (Test 1)" do
    test "starts and subscribes to FileSystem" do
      {pid, _co, _dir, _base} = start_watcher()
      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      assert is_map(state)
      assert Process.alive?(state.fs_pid)
    end
  end

  describe "reindex routing (Tests 2, 3)" do
    test "Test 2: creating company.md triggers mark_dirty within 1s" do
      {_pid, co, dir, _base} = start_watcher()
      path = Path.join(dir, "company.md")
      write!(path, "---\nname: #{co}\n---\n")

      assert_receive {:marked, ^co, ^path}, 1_000
    end

    test "Test 3: burst of 20 modifications coalesces to ONE mark_dirty" do
      {_pid, co, dir, _base} = start_watcher()
      path = Path.join(dir, "company.md")
      write!(path, "---\nname: #{co}\n---\n")
      # Drain the initial create event.
      assert_receive {:marked, ^co, ^path}, 1_000

      # Now rapidly modify the same file 20 times within ~50ms.
      for i <- 1..20 do
        File.write!(path, "---\nname: #{co}\nversion: #{i}\n---\n")
      end

      # Exactly one mark_dirty should fire after the 100ms debounce.
      assert_receive {:marked, ^co, ^path}, 1_000
      refute_receive {:marked, ^co, ^path}, 250
    end
  end

  describe "path-prefix routing (Tests 4, 5, 6, D-33)" do
    test "Test 4: inbox event does NOT call reindex" do
      {_pid, co, dir, _base} = start_watcher()
      inbox = Path.join([dir, "agents", "ceo", "inbox", "task.md"])
      write!(inbox, "---\nid: task1\n---\nSay pong\n")

      # No mark_dirty — inbox is Phase-3 router's target, not reindex's.
      refute_receive {:marked, ^co, _path}, 400
    end

    test "Test 5: audit/ event does NOT call reindex" do
      {_pid, co, dir, _base} = start_watcher()
      audit_path = Path.join([dir, "audit", "2026-04.jsonl"])
      write!(audit_path, ~s({"ts":"2026-04-16T00:00:00Z"}\n))

      refute_receive {:marked, ^co, _path}, 400
    end

    test "Test 6: channels/ event does NOT call reindex" do
      {_pid, co, dir, _base} = start_watcher()
      chan = Path.join([dir, "channels", "general.md"])
      write!(chan, "# general\n")

      refute_receive {:marked, ^co, _path}, 400
    end

    test "workspace/ events do NOT call reindex (cache noise)" do
      {_pid, co, dir, _base} = start_watcher()

      # claude-code's jsonl cache dumps land here. Reindex is a markdown
      # indexer for projects/agents/company metadata; workspace bytes are
      # not mirrored to SQLite.
      cache =
        Path.join([
          dir,
          "agents",
          "ceo",
          "workspace",
          ".cache",
          "claude-cli-nodejs",
          "mcp.jsonl"
        ])

      write!(cache, ~s({"tool":"foo"}\n))

      refute_receive {:marked, ^co, _path}, 400
    end
  end

  describe "lifecycle (Tests 7, 8)" do
    test "Test 7: :stop message terminates watcher with :normal" do
      {pid, _co, _dir, _base} = start_watcher()
      ref = Process.monitor(pid)
      # Simulate FileSystem emitting the :stop signal the upstream lib uses.
      send(pid, {:file_event, self(), :stop})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "Test 8: watcher can be stopped cleanly via GenServer.stop/1" do
      {pid, _co, _dir, _base} = start_watcher()
      assert :ok = GenServer.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "sub-second latency proof (Test 9, FS-06, Success Criterion #4)" do
    test "Test 9: from File.touch! to mark_dirty callback < 1000ms" do
      {_pid, co, dir, _base} = start_watcher()
      path = Path.join(dir, "latency.md")
      File.write!(path, "seed\n")
      # Drain create.
      assert_receive {:marked, ^co, ^path}, 1_000

      t0 = System.monotonic_time(:millisecond)
      File.write!(path, "changed\n")
      assert_receive {:marked, ^co, ^path}, 1_000
      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed < 1_000,
             "FS-06 latency contract: expected <1000ms, got #{elapsed}ms"
    end
  end

  describe "Company.Supervisor boot (Test 10; extended by Plan 03-05 + GAP-4/5 + AgentBoot + TaskScheduler)" do
    test "Test 10: Company.Supervisor starts 9 children by default (incl. TaskScheduler)" do
      base = TmpGlorboHome.setup()
      company = "sup_#{System.unique_integer([:positive])}"
      File.mkdir_p!(Path.join([base, "companies", company]))

      sup_name = Glorbo.Test.UniqueName.gen("company_sup")

      # Glorbo.Agent.Registry lives in the Application supervision tree
      # (see lib/glorbo/application.ex). Previously this test did
      # `Registry.start_link(..., name: Glorbo.Agent.Registry)` which
      # returned {:error, {:already_started, pid}} when the app was up
      # (harmless) but LINKED a stand-in process to the test pid when
      # the app hadn't finished booting. That link-killed the shared
      # registry on test-exit, cascading every later test with
      # "unknown registry" errors. Fix (#145): wait for the app's
      # registered registry instead of racing it.
      Application.ensure_all_started(:glorbo)

      {:ok, sup_pid} =
        Glorbo.Company.Supervisor.start_link(name: sup_name, company: company, base: base)

      on_exit(fn ->
        if Process.alive?(sup_pid) do
          try do
            Supervisor.stop(sup_pid, :shutdown)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      children = Supervisor.which_children(sup_pid)
      assert length(children) == 11

      modules =
        children
        |> Enum.map(fn {_id, _pid, _type, [mod]} -> mod end)
        |> MapSet.new()

      assert MapSet.member?(modules, Glorbo.Company.AuditLog)
      assert MapSet.member?(modules, Glorbo.Filesystem.Watcher)
      assert MapSet.member?(modules, Glorbo.Company.Router)
      assert MapSet.member?(modules, Glorbo.Company.Scheduler)
      assert MapSet.member?(modules, Glorbo.Company.BudgetTracker)
      assert MapSet.member?(modules, Glorbo.Company.AgentSupervisor)
      assert MapSet.member?(modules, Glorbo.Approvals.Gate)
      assert MapSet.member?(modules, Glorbo.PathRequestGate)
      assert MapSet.member?(modules, Glorbo.Company.ProposalsSink)
      assert MapSet.member?(modules, Glorbo.Company.AgentBoot)
      # GAP-4: no api-only agent on disk → Network.Proxy NOT started
      refute MapSet.member?(modules, Glorbo.Network.Proxy)
    end
  end

  describe "Plan 03-05 PubSub broadcast (W1-W6)" do
    test "W1: inbox file event broadcasts on company:<co>:inbox" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:inbox")

      inbox_file = Path.join([dir, "agents", "engineer", "inbox", "task1.md"])
      write!(inbox_file, "---\nid: 1\n---\n")

      assert_receive {:file_event, rel, events}, 2_000
      assert String.starts_with?(rel, "agents/engineer/inbox/")
      assert :created in events or :modified in events
    end

    test "W2: outbox file event broadcasts on company:<co>:outbox" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:outbox")

      outbox_file = Path.join([dir, "agents", "engineer", "outbox", "reply1.md"])
      write!(outbox_file, "---\nto: agent:ceo\n---\n")

      assert_receive {:file_event, rel, _events}, 2_000
      assert String.starts_with?(rel, "agents/engineer/outbox/")
    end

    test "W3: projects file event broadcasts on company:<co>:projects" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:projects")

      project_file = Path.join([dir, "projects", "foo", "tasks", "t-01.md"])
      write!(project_file, "---\nstatus: pending-approval\n---\n")

      assert_receive {:file_event, rel, _events}, 2_000
      assert String.starts_with?(rel, "projects/")
    end

    test "W4: audit file event does NOT broadcast (feedback-loop suppression)" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:audit")

      audit_file = Path.join([dir, "audit", "2026-04.jsonl"])
      write!(audit_file, ~s({"ts":"2026-04-16T00:00:00Z"}\n))

      # Explicit refute — no broadcast on audit/ per Plan 03-05 locked decision.
      refute_receive {:file_event, _, _}, 400
    end

    test "W6 (GEP-28): proposals file event broadcasts on company:<co>:proposals" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:proposals")

      File.mkdir_p!(Path.join(dir, "proposals"))
      proposal_file = Path.join([dir, "proposals", "hire-writer-2026-04-22.md"])
      write!(proposal_file, "---\nkind: proposal/v1\nstatus: pending-approval\n---\n")

      assert_receive {:file_event, rel, _events}, 2_000
      assert String.starts_with?(rel, "proposals/")
      assert String.ends_with?(rel, ".md")
    end

    test "W6b (GEP-28): nested proposals/<dir>/*.md does NOT broadcast on proposals topic" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:proposals")

      File.mkdir_p!(Path.join([dir, "proposals", "archive"]))
      nested = Path.join([dir, "proposals", "archive", "old.md"])
      write!(nested, "# archived\n")

      # FileSpec.ProposalMd only matches /proposals/<id>.md direct children
      # (regex `/proposals/[^/]+\.md\z`). Nested paths must not masquerade as
      # proposal traffic.
      refute_receive {:file_event, _, _}, 400
    end

    test "W5: channels file event broadcasts on company:<co>:channels" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:channels")

      chan_file = Path.join([dir, "channels", "general.md"])
      write!(chan_file, "# general\n")

      assert_receive {:file_event, rel, _events}, 2_000
      assert String.starts_with?(rel, "channels/")
    end
  end

  describe "Plan 04-01 PubSub extensions (P4-W0-1..P4-W0-5)" do
    test "P4-W0-1: stdout.log write broadcasts on agents:<slug>:stdout" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:ceo:stdout")

      stdout_path = Path.join([dir, "agents", "ceo", "stdout.log"])
      write!(stdout_path, "hello\n")

      assert_receive {:file_event, "agents/ceo/stdout.log", events}, 2_000
      assert :created in events or :modified in events
    end

    test "P4-W0-2: state/wake-request.md broadcasts on agents:<slug>:wake" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:ceo:wake")

      wake_path = Path.join([dir, "agents", "ceo", "state", "wake-request.md"])
      write!(wake_path, "---\nrequested_at: \"2026-04-16T00:00:00Z\"\n---\n")

      assert_receive {:file_event, rel, _events}, 2_000
      assert rel == "agents/ceo/state/wake-request.md"
    end

    test "P4-W0-3: channels/<slug>.md broadcasts on channels:<slug> (per-slug topic)" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:channels:general")

      chan_file = Path.join([dir, "channels", "general.md"])
      write!(chan_file, "# general\n")

      assert_receive {:file_event, rel, _events}, 2_000
      assert rel == "channels/general.md"
    end

    test "P4-W0-4: dual-broadcast — channels/* event fires BOTH per-slug and rollup topics" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:channels")
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:channels:general")

      chan_file = Path.join([dir, "channels", "general.md"])
      write!(chan_file, "# general\n")

      # Both subscribers receive the same event (this process subscribed
      # to both topics, so we should get 2 messages).
      assert_receive {:file_event, "channels/general.md", _}, 2_000
      assert_receive {:file_event, "channels/general.md", _}, 2_000
    end

    test "P4-W0-5: stdout path does NOT fire on the rollup inbox/outbox topics" do
      {_pid, co, dir, _base} = start_watcher()
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:inbox")
      :ok = Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:outbox")

      stdout_path = Path.join([dir, "agents", "ceo", "stdout.log"])
      write!(stdout_path, "bootstrap\n")

      refute_receive {:file_event, _, _}, 400
    end
  end
end
