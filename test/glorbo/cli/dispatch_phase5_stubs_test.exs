defmodule Glorbo.CLI.DispatchPhase5StubsTest do
  @moduledoc """
  Phase-5 dispatch routing contract. Plan 05-03 + 05-04 made
  migrate/backup/restore/console live — their dispatch rows now assert
  tuple shape only (no "not implemented in Wave 0" substring).

  This suite proves the dispatch switch stays wired regardless of which
  verb modules are stubs vs live. After Plans 05-03 + 05-04 merge, every
  Phase-5 verb is live.
  """
  use ExUnit.Case, async: true

  # All Phase-5 verbs — Plans 03 + 04 brought the final 4 live. Each
  # argv is picked to exercise routing without triggering side effects:
  # --help returns a pure tuple with no filesystem/daemon interaction.
  @live_verbs [
    {["up", "--help"], :up},
    {["down", "--help"], :down},
    {["status", "--help"], :status},
    {["serve", "--help"], :serve},
    {["run", "--help"], :run},
    {["logs", "--help"], :logs},
    {["migrate", "--help"], :migrate},
    {["backup", "--help"], :backup},
    {["restore", "--help"], :restore},
    {["console", "--help"], :console}
  ]

  for {argv, expected_verb} <- @live_verbs do
    test "dispatch #{inspect(argv)} routes to :#{expected_verb} (live)" do
      assert {unquote(expected_verb), code, out} = Glorbo.CLI.dispatch(unquote(argv))
      assert is_integer(code)
      assert is_binary(out)

      refute out =~ "not implemented in Wave 0",
             "#{unquote(expected_verb)} still contains Wave-0 stub marker"
    end
  end

  test "dispatch new company returns :new_company" do
    assert {:new_company, _, _} = Glorbo.CLI.dispatch(["new", "company", "acme"])
  end

  test "dispatch new agent returns :new_agent" do
    assert {:new_agent, _, _} = Glorbo.CLI.dispatch(["new", "agent", "acme/ceo"])
  end

  test "dispatch new project returns :new_project" do
    assert {:new_project, _, _} = Glorbo.CLI.dispatch(["new", "project", "acme/website"])
  end

  test "dispatch new widget (unknown sub) returns :unknown exit 1" do
    assert {:unknown, 1, out} = Glorbo.CLI.dispatch(["new", "widget"])
    assert out =~ "Unknown subcommand: new widget"
  end

  test "dispatch new (no sub) returns :unknown exit 1 with usage" do
    assert {:unknown, 1, out} = Glorbo.CLI.dispatch(["new"])
    assert out =~ "Usage: glorbo new"
  end

  test "dispatch help up returns verb-specific help" do
    assert {:help, 0, out} = Glorbo.CLI.dispatch(["help", "up"])
    assert String.length(out) > 0
    assert out =~ "glorbo up"
  end

  test "dispatch help backup returns backup-specific help" do
    assert {:help, 0, out} = Glorbo.CLI.dispatch(["help", "backup"])
    assert out =~ "glorbo backup"
    assert out =~ "--output"
  end

  test "dispatch help unknownverb falls back to global help" do
    assert {:help, 0, out} = Glorbo.CLI.dispatch(["help", "xyzzy"])
    assert out =~ "USAGE"
  end

  test "help_text lists every DESIGN.md §10 verb" do
    text = Glorbo.CLI.help_text()

    for verb <- ~w(init up down status serve run new logs migrate backup restore doctor console) do
      assert text =~ verb, "help_text missing #{verb}"
    end
  end

  test "catch-all for truly unknown verbs still returns :unknown exit 1" do
    assert {:unknown, 1, out} = Glorbo.CLI.dispatch(["definitely-not-a-verb"])
    assert out =~ "Unknown command: definitely-not-a-verb"
  end
end
