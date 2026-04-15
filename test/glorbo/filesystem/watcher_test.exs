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

    test_pid = self()

    default_reindex_fun =
      fn co, path -> send(test_pid, {:marked, co, path}) end

    opts =
      Keyword.merge(
        [
          company: company,
          base: base,
          name: :"watcher_#{System.unique_integer([:positive])}",
          reindex_fun: default_reindex_fun
        ],
        overrides
      )

    {:ok, pid} = Watcher.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, company, company_dir, base}
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

  describe "Company.Supervisor boot (Test 10, B5)" do
    test "Test 10: Company.Supervisor starts cleanly with exactly AuditLog + Watcher" do
      base = TmpGlorboHome.setup()
      company = "sup_#{System.unique_integer([:positive])}"
      File.mkdir_p!(Path.join([base, "companies", company]))

      sup_name = :"company_sup_#{System.unique_integer([:positive])}"

      {:ok, sup_pid} =
        Glorbo.Company.Supervisor.start_link(name: sup_name, company: company, base: base)

      on_exit(fn -> if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid) end)

      children = Supervisor.which_children(sup_pid)
      assert length(children) == 2

      modules =
        children
        |> Enum.map(fn {_id, _pid, _type, [mod]} -> mod end)
        |> MapSet.new()

      assert MapSet.member?(modules, Glorbo.Company.AuditLog)
      assert MapSet.member?(modules, Glorbo.Filesystem.Watcher)

      refute MapSet.member?(modules, Glorbo.Company.Router)
      refute MapSet.member?(modules, Glorbo.Company.Scheduler)
      refute MapSet.member?(modules, Glorbo.Company.BudgetTracker)
    end
  end
end
