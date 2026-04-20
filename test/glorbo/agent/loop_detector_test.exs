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
      assert content =~ "kind: loop_detected"
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
end
