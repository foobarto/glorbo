defmodule Glorbo.CLI.DispatchPhase5StubsTest do
  @moduledoc """
  Plan 05-01 Task 2 contract: every Phase-5 verb must be reachable via
  `Glorbo.CLI.dispatch/1` and must return a tuple with the expected
  verb atom + Wave-0 stub output. Plans 02 and 03 can edit individual
  verb modules without touching `dispatch/1`; this suite proves the
  switch stays wired.
  """
  use ExUnit.Case, async: true

  @stub_verbs [
    {"up", :up},
    {"down", :down},
    {"status", :status},
    {"serve", :serve},
    {"run", :run},
    {"logs", :logs},
    {"migrate", :migrate},
    {"backup", :backup},
    {"restore", :restore},
    {"console", :console}
  ]

  for {argv, expected_verb} <- @stub_verbs do
    test "dispatch #{argv} returns Wave-0 stub tuple" do
      assert {unquote(expected_verb), code, out} = Glorbo.CLI.dispatch([unquote(argv)])
      assert is_integer(code)

      assert String.contains?(out, "not implemented in Wave 0") or
               String.contains?(out, unquote(argv))
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
