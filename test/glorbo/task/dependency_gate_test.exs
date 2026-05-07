defmodule Glorbo.Task.DependencyGateTest do
  @moduledoc """
  Pure unit tests for `Glorbo.Task.DependencyGate` — covers every
  cell of the GEP-47 D3 terminal-state classification table plus
  the cycle-detection cases listed in §Test strategy.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Task.DependencyGate

  describe "ready?/2 — empty deps" do
    test "no deps → :ok" do
      assert DependencyGate.ready?([], %{}) == :ok
    end
  end

  describe "ready?/2 — done-terminal classification (D3 row 1)" do
    test "status: done with no peer-review → :ok" do
      snap = %{"a" => %{status: "done"}}
      assert DependencyGate.ready?(["a"], snap) == :ok
    end

    test "status: done + peer_review_required + verdict approve → :ok" do
      snap = %{
        "a" => %{
          status: "done",
          peer_review_required: true,
          peer_review_verdict: "approve"
        }
      }

      assert DependencyGate.ready?(["a"], snap) == :ok
    end
  end

  describe "ready?/2 — failure-terminal classification (D3 row 2)" do
    test "denied → :propagate_failure" do
      snap = %{"a" => %{status: "denied"}}

      assert {:propagate_failure, "a", reason} =
               DependencyGate.ready?(["a"], snap)

      assert reason =~ "denied"
    end

    test "cancelled → :propagate_failure" do
      snap = %{"a" => %{status: "cancelled"}}

      assert {:propagate_failure, "a", reason} =
               DependencyGate.ready?(["a"], snap)

      assert reason =~ "cancelled"
    end

    test "peer-review verdict block → :propagate_failure" do
      snap = %{
        "a" => %{
          status: "done",
          peer_review_required: true,
          peer_review_verdict: "block"
        }
      }

      assert {:propagate_failure, "a", reason} =
               DependencyGate.ready?(["a"], snap)

      assert reason =~ "peer-review blocked"
    end

    test "missing target → :propagate_failure with `not found`" do
      assert {:propagate_failure, "ghost", reason} =
               DependencyGate.ready?(["ghost"], %{})

      assert reason =~ "not found"
    end
  end

  describe "ready?/2 — non-terminal classification (D3 row 3)" do
    for status <- ["todo", "in-progress", "pending", "pending-approval", "approved"] do
      test "status: #{status} → blocked", %{} do
        status = unquote(status)
        snap = %{"a" => %{status: status}}
        assert DependencyGate.ready?(["a"], snap) == {:blocked, ["a"]}
      end
    end

    test "status: done with peer_review_required and verdict pending → blocked" do
      snap = %{
        "a" => %{
          status: "done",
          peer_review_required: true,
          peer_review_verdict: nil
        }
      }

      assert DependencyGate.ready?(["a"], snap) == {:blocked, ["a"]}
    end

    test "status: done with peer_review verdict revise → blocked" do
      snap = %{
        "a" => %{
          status: "done",
          peer_review_required: true,
          peer_review_verdict: "revise"
        }
      }

      assert DependencyGate.ready?(["a"], snap) == {:blocked, ["a"]}
    end
  end

  describe "ready?/2 — multi-dep aggregation" do
    test "all done → :ok" do
      snap = %{
        "a" => %{status: "done"},
        "b" => %{status: "done"},
        "c" => %{status: "done"}
      }

      assert DependencyGate.ready?(["a", "b", "c"], snap) == :ok
    end

    test "one blocked, rest done → :blocked names the unmet only" do
      snap = %{
        "a" => %{status: "done"},
        "b" => %{status: "in-progress"},
        "c" => %{status: "done"}
      }

      assert DependencyGate.ready?(["a", "b", "c"], snap) == {:blocked, ["b"]}
    end

    test "multiple blocked → :blocked preserves order" do
      snap = %{
        "a" => %{status: "todo"},
        "b" => %{status: "done"},
        "c" => %{status: "in-progress"}
      }

      assert DependencyGate.ready?(["a", "b", "c"], snap) == {:blocked, ["a", "c"]}
    end

    test "mixed blocked + failure → failure short-circuits" do
      snap = %{
        "a" => %{status: "in-progress"},
        "b" => %{status: "denied"},
        "c" => %{status: "done"}
      }

      assert {:propagate_failure, "b", _} =
               DependencyGate.ready?(["a", "b", "c"], snap)
    end
  end

  describe "cycle_detect/1" do
    test "acyclic graph returns []" do
      snap = %{
        "a" => %{depends_on: []},
        "b" => %{depends_on: ["a"]},
        "c" => %{depends_on: ["a", "b"]}
      }

      assert DependencyGate.cycle_detect(snap) == []
    end

    test "self-loop A → A" do
      snap = %{"a" => %{depends_on: ["a"]}}
      cycles = DependencyGate.cycle_detect(snap)
      assert length(cycles) == 1
      assert ["a", "a"] = hd(cycles)
    end

    test "two-node cycle A → B → A" do
      snap = %{
        "a" => %{depends_on: ["b"]},
        "b" => %{depends_on: ["a"]}
      }

      cycles = DependencyGate.cycle_detect(snap)
      assert length(cycles) >= 1
      # Cycle path includes both nodes.
      [first | _] = cycles
      assert "a" in first and "b" in first
    end

    test "longer cycle A → B → C → D → A" do
      snap = %{
        "a" => %{depends_on: ["b"]},
        "b" => %{depends_on: ["c"]},
        "c" => %{depends_on: ["d"]},
        "d" => %{depends_on: ["a"]}
      }

      cycles = DependencyGate.cycle_detect(snap)
      assert length(cycles) >= 1
      [first | _] = cycles
      for n <- ["a", "b", "c", "d"], do: assert(n in first)
    end

    test "missing dep target is treated as terminal — no false cycle" do
      snap = %{"a" => %{depends_on: ["ghost"]}}
      assert DependencyGate.cycle_detect(snap) == []
    end
  end
end
