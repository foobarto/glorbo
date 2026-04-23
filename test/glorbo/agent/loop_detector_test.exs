defmodule Glorbo.Agent.LoopDetectorTest do
  @moduledoc """
  Unit tests for the pure `detect_loop/2` function + the full
  `check/3` pipeline with stubbed filesystem + audit.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Agent.LoopDetector

  defp complete_entry(
         agent,
         task,
         exit_status,
         reply_preview \\ nil,
         ts \\ "2026-04-21T10:00:00Z"
       ) do
    %{
      "action" => "agent.complete",
      "actor" => agent,
      "target" => task,
      "agent" => agent,
      "ts" => ts,
      "detail" => %{
        "exit_status" => exit_status,
        "reply_preview" => reply_preview
      }
    }
  end

  describe "detect_loop/2 — pure logic" do
    test "empty → :no_loop" do
      assert LoopDetector.detect_loop([], 3) == :no_loop
    end

    test "single failure under threshold → :no_loop" do
      entries = [complete_entry("ceo", "t.md", "1")]
      assert LoopDetector.detect_loop(entries, 3) == :no_loop
    end

    test "three consecutive exit-nonzero failures on same task → :loop" do
      entries = [
        complete_entry("ceo", "t.md", "1"),
        complete_entry("ceo", "t.md", "1"),
        complete_entry("ceo", "t.md", "1")
      ]

      assert {:loop, "t.md", chain} = LoopDetector.detect_loop(entries, 3)
      assert length(chain) == 3
    end

    test "exit-0-with-empty-reply counts as failure" do
      entries = [
        complete_entry("ceo", "t.md", "0", ""),
        complete_entry("ceo", "t.md", "0", nil),
        complete_entry("ceo", "t.md", "0", "   ")
      ]

      assert {:loop, "t.md", _} = LoopDetector.detect_loop(entries, 3)
    end

    test "successful completion in chain resets the count" do
      entries = [
        # Newest first: 2 failures, 1 success, 2 failures
        complete_entry("ceo", "t.md", "1"),
        complete_entry("ceo", "t.md", "1"),
        complete_entry("ceo", "t.md", "0", "done!"),
        complete_entry("ceo", "t.md", "1"),
        complete_entry("ceo", "t.md", "1")
      ]

      # Only the 2 most recent failures — under threshold
      assert LoopDetector.detect_loop(entries, 3) == :no_loop
    end

    test "different task in the chain ends the walk" do
      entries = [
        complete_entry("ceo", "t.md", "1"),
        complete_entry("ceo", "t.md", "1"),
        complete_entry("ceo", "other.md", "1")
      ]

      # Only 2 failures on t.md before the task changes
      assert LoopDetector.detect_loop(entries, 3) == :no_loop
    end

    test "threshold=1 triggers on first failure" do
      entries = [complete_entry("ceo", "t.md", "2")]
      assert {:loop, "t.md", _} = LoopDetector.detect_loop(entries, 1)
    end
  end

  describe "check/3 — full pipeline with stubs" do
    setup do
      base = Path.join(System.tmp_dir!(), "loopdet-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([base, "companies/acme/agents/ceo/state"]))
      on_exit(fn -> File.rm_rf(base) end)
      {:ok, base: base}
    end

    test "writes sentinel + emits audit when loop detected", %{base: base} do
      me = self()

      audit_fun = fn company, entry ->
        send(me, {:audit, company, entry})
      end

      entries = [
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1"),
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1"),
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1")
      ]

      result =
        LoopDetector.check("acme", "ceo",
          base: base,
          threshold: 3,
          audit_reader: fn _b, _c -> entries end,
          audit_fun: audit_fun
        )

      assert {:stuck, "projects/blog/tasks/b-1.md", 3} = result

      sentinel = Path.join([base, "companies/acme/agents/ceo/state/stuck-on-b-1.md"])
      assert File.exists?(sentinel)
      content = File.read!(sentinel)
      assert content =~ "kind: sentinel-stuck/v1"
      assert content =~ "task_id: b-1"
      assert content =~ "failure_count: 3"
      assert content =~ "resolved-retry-b-1.md"

      assert_receive {:audit, "acme", %{action: "agent.loop_detected", agent: "ceo"}}
    end

    test "idempotent — existing sentinel not overwritten", %{base: base} do
      me = self()
      audit_fun = fn _c, e -> send(me, {:audit, e}) end

      sentinel = Path.join([base, "companies/acme/agents/ceo/state/stuck-on-b-1.md"])
      File.write!(sentinel, "preexisting content\n")

      entries = [
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1"),
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1"),
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1")
      ]

      result =
        LoopDetector.check("acme", "ceo",
          base: base,
          threshold: 3,
          audit_reader: fn _b, _c -> entries end,
          audit_fun: audit_fun
        )

      assert result == :ok
      assert File.read!(sentinel) == "preexisting content\n"
      refute_receive {:audit, _}, 50
    end

    test "under threshold → no sentinel written", %{base: base} do
      entries = [
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1"),
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1")
      ]

      result =
        LoopDetector.check("acme", "ceo",
          base: base,
          threshold: 3,
          audit_reader: fn _b, _c -> entries end,
          audit_fun: fn _c, _e -> :ok end
        )

      assert result == :ok

      sentinel = Path.join([base, "companies/acme/agents/ceo/state/stuck-on-b-1.md"])
      refute File.exists?(sentinel)
    end

    test "filters to this agent's completes only", %{base: base} do
      # Noise from other agents + other action types shouldn't trigger.
      entries = [
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1"),
        complete_entry("researcher", "projects/blog/tasks/b-1.md", "1"),
        complete_entry("researcher", "projects/blog/tasks/b-1.md", "1"),
        complete_entry("researcher", "projects/blog/tasks/b-1.md", "1"),
        %{"action" => "task.create", "target" => "x"},
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1"),
        complete_entry("ceo", "projects/blog/tasks/b-1.md", "1")
      ]

      # ceo has only 3 failures total but interleaved — detection
      # counts only consecutive-newest-first, so {ceo, ceo, ceo}
      # at top of newest-first view.
      result =
        LoopDetector.check("acme", "ceo",
          base: base,
          threshold: 3,
          audit_reader: fn _b, _c -> entries end,
          audit_fun: fn _c, _e -> :ok end
        )

      assert {:stuck, _, 3} = result
    end
  end

  # R21 — resolution API: one code path for button-driven and
  # file-drop resolutions. Tests cover retry/skip/stop decisions,
  # task mutation, sentinel cleanup, audit emission, and the
  # file-drop discovery loop.
  describe "resolve/5 — apply resolution + audit" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "glorbo-loop-resolve-#{System.unique_integer([:positive])}")

      company = "acme"
      agent = "ceo"

      task_dir = Path.join([base, "companies", company, "projects/blog/tasks"])
      state_dir = Path.join([base, "companies", company, "agents", agent, "state"])
      File.mkdir_p!(task_dir)
      File.mkdir_p!(state_dir)

      task_id = "t-stuck-#{System.unique_integer([:positive])}"
      rel_task_path = "projects/blog/tasks/#{task_id}.md"
      abs_task = Path.join(task_dir, "#{task_id}.md")

      File.write!(abs_task, """
      ---
      kind: task/v1
      id: #{task_id}
      title: Stuck task
      status: in-progress
      assigned_to: #{agent}
      ---

      body
      """)

      sentinel = Path.join(state_dir, "stuck-on-#{task_id}.md")

      File.write!(sentinel, """
      ---
      kind: sentinel-stuck/v1
      agent: #{agent}
      task_id: #{task_id}
      task_path: #{rel_task_path}
      failure_count: 3
      ---

      body
      """)

      on_exit(fn -> File.rm_rf!(base) end)

      {:ok,
       base: base,
       company: company,
       agent: agent,
       task_id: task_id,
       abs_task: abs_task,
       sentinel: sentinel,
       state_dir: state_dir}
    end

    test ":retry deletes sentinel, leaves task untouched", ctx do
      me = self()
      audit_fun = fn co, entry -> send(me, {:audit, co, entry}) end

      assert :ok =
               Glorbo.Agent.LoopDetector.resolve(
                 ctx.sentinel,
                 :retry,
                 ctx.base,
                 ctx.company,
                 actor: "director",
                 audit_fun: audit_fun
               )

      refute File.exists?(ctx.sentinel)

      # Task unchanged.
      {:ok, fm, _body} =
        Glorbo.Filesystem.Frontmatter.parse(File.read!(ctx.abs_task))

      assert fm["status"] == "in-progress"
      assert fm["assigned_to"] == ctx.agent

      assert_receive {:audit, "acme", entry}
      assert entry.action == "agent.loop_resolved"
      assert entry.actor == "director"
      assert entry.decision == "retry"
      assert entry.agent == ctx.agent
      assert entry.task_id == ctx.task_id
    end

    test ":skip reassigns task to director + deletes sentinel", ctx do
      me = self()
      audit_fun = fn co, entry -> send(me, {:audit, co, entry}) end

      assert :ok =
               Glorbo.Agent.LoopDetector.resolve(
                 ctx.sentinel,
                 :skip,
                 ctx.base,
                 ctx.company,
                 actor: "director",
                 audit_fun: audit_fun
               )

      refute File.exists?(ctx.sentinel)

      {:ok, fm, _body} =
        Glorbo.Filesystem.Frontmatter.parse(File.read!(ctx.abs_task))

      assert fm["assigned_to"] == "director"

      assert_receive {:audit, _co, %{decision: "skip"}}
    end

    test ":stop marks task denied + deletes sentinel", ctx do
      me = self()
      audit_fun = fn co, entry -> send(me, {:audit, co, entry}) end

      assert :ok =
               Glorbo.Agent.LoopDetector.resolve(
                 ctx.sentinel,
                 :stop,
                 ctx.base,
                 ctx.company,
                 actor: "director",
                 audit_fun: audit_fun
               )

      refute File.exists?(ctx.sentinel)

      {:ok, fm, _body} =
        Glorbo.Filesystem.Frontmatter.parse(File.read!(ctx.abs_task))

      assert fm["status"] == "denied"

      assert_receive {:audit, _co, %{decision: "stop"}}
    end

    test "missing sentinel returns :enoent without side effects", ctx do
      assert {:error, :enoent} =
               Glorbo.Agent.LoopDetector.resolve(
                 Path.join(ctx.state_dir, "stuck-on-nonexistent.md"),
                 :retry,
                 ctx.base,
                 ctx.company
               )
    end

    test "explicit nil audit_fun falls back to default (R23 regression)", ctx do
      # apply_one_resolution forwards Keyword.get(opts, :audit_fun),
      # which returns nil when the key is absent upstream. resolve/5
      # must coerce nil to the default rather than trying to call it
      # as a function. Default routes to Glorbo.Company.AuditLog via
      # the per-company Registry; with no company supervisor running,
      # the call exits, but `emit_resolved_audit` catches that.
      # Assertion: resolve returns :ok (no propagating crash) and
      # the sentinel gets deleted.

      assert :ok =
               Glorbo.Agent.LoopDetector.resolve(
                 ctx.sentinel,
                 :retry,
                 ctx.base,
                 ctx.company,
                 actor: "director",
                 audit_fun: nil
               )

      refute File.exists?(ctx.sentinel)
    end

    test "custom actor propagates to audit", ctx do
      me = self()
      audit_fun = fn co, entry -> send(me, {:audit, co, entry}) end

      assert :ok =
               Glorbo.Agent.LoopDetector.resolve(
                 ctx.sentinel,
                 :retry,
                 ctx.base,
                 ctx.company,
                 actor: "agent:ceo",
                 audit_fun: audit_fun
               )

      assert_receive {:audit, _co, %{actor: "agent:ceo"}}
    end
  end

  describe "apply_resolution_files/3 — file-drop protocol" do
    setup do
      base = Path.join(System.tmp_dir!(), "glorbo-loop-res-#{System.unique_integer([:positive])}")
      company = "acme"
      agent = "ceo"

      task_dir = Path.join([base, "companies", company, "projects/blog/tasks"])
      state_dir = Path.join([base, "companies", company, "agents", agent, "state"])
      File.mkdir_p!(task_dir)
      File.mkdir_p!(state_dir)

      task_id = "t-res-#{System.unique_integer([:positive])}"
      rel_task_path = "projects/blog/tasks/#{task_id}.md"
      abs_task = Path.join(task_dir, "#{task_id}.md")

      File.write!(abs_task, """
      ---
      kind: task/v1
      id: #{task_id}
      title: File-drop task
      status: in-progress
      assigned_to: #{agent}
      ---

      body
      """)

      sentinel = Path.join(state_dir, "stuck-on-#{task_id}.md")

      File.write!(sentinel, """
      ---
      kind: sentinel-stuck/v1
      agent: #{agent}
      task_id: #{task_id}
      task_path: #{rel_task_path}
      failure_count: 3
      ---

      body
      """)

      on_exit(fn -> File.rm_rf!(base) end)

      {:ok,
       base: base,
       company: company,
       agent: agent,
       task_id: task_id,
       abs_task: abs_task,
       sentinel: sentinel,
       state_dir: state_dir}
    end

    test "resolved-skip file applies + deletes both files + audits",
         ctx do
      me = self()
      audit_fun = fn co, entry -> send(me, {:audit, co, entry}) end

      res_file = Path.join(ctx.state_dir, "resolved-skip-#{ctx.task_id}.md")
      File.write!(res_file, "")

      results =
        Glorbo.Agent.LoopDetector.apply_resolution_files(
          ctx.base,
          ctx.company,
          audit_fun: audit_fun
        )

      assert [{:skip, _task_id, :ok}] = results

      refute File.exists?(res_file)
      refute File.exists?(ctx.sentinel)

      {:ok, fm, _body} =
        Glorbo.Filesystem.Frontmatter.parse(File.read!(ctx.abs_task))

      assert fm["assigned_to"] == "director"

      # Actor defaults to agent:<slug> when file-drop path triggers.
      assert_receive {:audit, _co, %{actor: "agent:ceo", decision: "skip"}}
    end

    test "orphan resolution file (no sentinel) is cleaned up silently",
         ctx do
      File.rm!(ctx.sentinel)
      orphan = Path.join(ctx.state_dir, "resolved-stop-#{ctx.task_id}.md")
      File.write!(orphan, "")

      results = Glorbo.Agent.LoopDetector.apply_resolution_files(ctx.base, ctx.company)

      assert results == []
      refute File.exists?(orphan)
    end

    test "malformed filename ignored", ctx do
      # Subtle: wildcard matches `resolved-*-*.md`. A file named
      # `resolved-foobar-x.md` satisfies the glob but the regex
      # check filters it out. Loader removes anything matching the
      # glob that doesn't have a matching sentinel.
      weird = Path.join(ctx.state_dir, "resolved-nonsense-oops.md")
      File.write!(weird, "")

      _results = Glorbo.Agent.LoopDetector.apply_resolution_files(ctx.base, ctx.company)

      # Orphan cleanup: the sentinel for task_id still exists, but
      # "oops" has no matching stuck-on-oops sentinel, so it's
      # cleaned up.
      refute File.exists?(weird)
      # Real sentinel still present (decision="nonsense" wouldn't match regex anyway).
      assert File.exists?(ctx.sentinel)
    end

    test "multiple resolution files apply in one pass", ctx do
      # Two agents each with their own stuck sentinel on different
      # tasks; file-drops for both land in one pass.
      agent2 = "researcher"
      task_id_2 = "t-res-2-#{System.unique_integer([:positive])}"
      rel_path_2 = "projects/blog/tasks/#{task_id_2}.md"
      abs_task_2 = Path.join([ctx.base, "companies", ctx.company, rel_path_2])

      File.write!(abs_task_2, """
      ---
      kind: task/v1
      id: #{task_id_2}
      title: Task two
      status: in-progress
      assigned_to: #{agent2}
      ---
      """)

      state_dir_2 = Path.join([ctx.base, "companies", ctx.company, "agents", agent2, "state"])
      File.mkdir_p!(state_dir_2)

      sentinel_2 = Path.join(state_dir_2, "stuck-on-#{task_id_2}.md")

      File.write!(sentinel_2, """
      ---
      kind: sentinel-stuck/v1
      agent: #{agent2}
      task_id: #{task_id_2}
      task_path: #{rel_path_2}
      failure_count: 3
      ---
      """)

      File.write!(Path.join(ctx.state_dir, "resolved-retry-#{ctx.task_id}.md"), "")
      File.write!(Path.join(state_dir_2, "resolved-stop-#{task_id_2}.md"), "")

      results = Glorbo.Agent.LoopDetector.apply_resolution_files(ctx.base, ctx.company)

      decisions = results |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert decisions == [:retry, :stop]

      refute File.exists?(ctx.sentinel)
      refute File.exists?(sentinel_2)

      {:ok, fm_2, _} =
        Glorbo.Filesystem.Frontmatter.parse(File.read!(abs_task_2))

      assert fm_2["status"] == "denied"
    end
  end
end
