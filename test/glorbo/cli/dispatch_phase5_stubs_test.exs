defmodule Glorbo.CLI.DispatchPhase5StubsTest do
  @moduledoc """
  Phase-5 dispatch routing contract: every Phase-5 verb must be reachable
  via `Glorbo.CLI.dispatch/1` and must return a tuple with the expected
  verb atom. Plan 05-02 filled the lifecycle + logs verbs (output no
  longer contains "not implemented in Wave 0" for those); Plan 05-03 will
  fill migrate/backup/restore/console and update those rows.

  This suite proves the dispatch switch stays wired regardless of which
  verb modules are stubs vs live.
  """
  use ExUnit.Case, async: true

  @dispatch_verbs [
    # Live after Plan 05-02 (lifecycle + observability) — asserts
    # routing only; verb-specific behaviour is covered by the per-verb
    # *_test.exs files.
    {"migrate", :migrate, :stub},
    {"backup", :backup, :stub},
    {"restore", :restore, :stub},
    {"console", :console, :stub}
  ]

  for {argv, expected_verb, stub_or_live} <- @dispatch_verbs do
    test "dispatch #{argv} routes to :#{expected_verb} (#{stub_or_live})" do
      assert {unquote(expected_verb), code, out} = Glorbo.CLI.dispatch([unquote(argv)])
      assert is_integer(code)
      assert is_binary(out)

      # Plan 05-03 stubs still contain the canonical Wave-0 marker.
      if unquote(stub_or_live) == :stub do
        assert String.contains?(out, "not implemented in Wave 0") or
                 String.contains?(out, unquote(argv))
      end
    end
  end

  # Plan 05-02 lifecycle / logs verbs — dispatched but have live (non-stub)
  # implementations. Only assert the dispatch routing.
  @live_verbs [
    {["up"], :up},
    {["down"], :down},
    {["status"], :status},
    {["serve", "--help"], :serve},
    {["run"], :run},
    {["logs"], :logs}
  ]

  for {argv, expected_verb} <- @live_verbs do
    test "dispatch #{inspect(argv)} routes to :#{expected_verb} (live)" do
      assert {unquote(expected_verb), code, out} = Glorbo.CLI.dispatch(unquote(argv))
      assert is_integer(code)
      assert is_binary(out)
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
