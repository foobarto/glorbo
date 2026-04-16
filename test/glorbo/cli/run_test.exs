defmodule Glorbo.CLI.RunTest do
  @moduledoc """
  Plan 05-02 Task 1 — `Glorbo.CLI.Lifecycle.Run`.

  Argv validation tests run unit-scoped; full dispatch flow (starts
  supervision tree + reads agent.md + invokes Dispatch.execute/3) is
  tagged `:integration` since it requires the full tree.
  """
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Lifecycle.Run

  describe "run — argv validation" do
    test "missing task file returns exit 1 with usage" do
      assert {:run, 1, out} = Run.run(["acme/ceo"])
      assert out =~ "Usage: glorbo run"
    end

    test "missing company/agent separator returns exit 1" do
      assert {:run, 1, out} = Run.run(["acme", "task.md"])
      assert out =~ "Usage: glorbo run"
    end

    test "no args returns exit 1 with usage" do
      assert {:run, 1, out} = Run.run([])
      assert out =~ "Usage: glorbo run"
    end

    test "--help returns help text" do
      assert {:run, 0, out} = Run.run(["--help"])
      assert out =~ "glorbo run"
      assert out =~ "<company>/<agent>"
    end
  end
end
