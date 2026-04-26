defmodule Glorbo.Shell.Views.Audit.DataTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Audit.Data
  alias Glorbo.Test.TmpGlorboHome

  defp write!(base, rel, body) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
    full
  end

  defp current_ym do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.to_string()
    |> String.slice(0, 7)
  end

  defp seed_audit(base, co, lines) do
    ym = current_ym()
    write!(base, "companies/#{co}/audit/#{ym}.jsonl", lines)
  end

  test "missing audit file → empty list" do
    base = TmpGlorboHome.setup()
    assert Data.load_tail(base, "acme") == []
  end

  test "single JSONL line decodes into one row" do
    base = TmpGlorboHome.setup()

    seed_audit(
      base,
      "acme",
      ~s|{"ts":"2026-04-26T10:00:00Z","actor":"ceo","action":"task.create","target":"projects/x/tasks/t-01.md"}\n|
    )

    [row] = Data.load_tail(base, "acme")
    assert row.ts == "2026-04-26T10:00:00Z"
    assert row.actor == "ceo"
    assert row.action == "task.create"
    assert row.target == "projects/x/tasks/t-01.md"
  end

  test "missing ts/actor/action/target fall back to defaults" do
    base = TmpGlorboHome.setup()
    seed_audit(base, "acme", ~s|{}\n|)

    [row] = Data.load_tail(base, "acme")
    assert row.ts == ""
    assert row.actor == "?"
    assert row.action == "?"
    assert row.target == ""
  end

  test "blank lines + malformed JSON are skipped" do
    base = TmpGlorboHome.setup()

    seed_audit(base, "acme", """
    {"ts":"2026-04-26T01:00:00Z","actor":"ceo","action":"a","target":"x"}

    not-json
    {"missing":"required-fields"}
    {"ts":"2026-04-26T02:00:00Z","actor":"ceo","action":"b","target":"y"}
    """)

    rows = Data.load_tail(base, "acme")
    # The "missing required" line decodes successfully (just no expected
    # keys), so it surfaces with default values. "not-json" is dropped.
    actions = Enum.map(rows, & &1.action)
    assert "a" in actions
    assert "b" in actions
    assert "?" in actions
    refute Enum.any?(rows, &(&1.action == "not-json"))
  end

  test "tail respects N parameter — last N lines only" do
    base = TmpGlorboHome.setup()

    lines =
      for i <- 1..10 do
        ~s|{"ts":"2026-04-26T10:00:#{String.pad_leading(to_string(i), 2, "0")}Z","actor":"ceo","action":"a#{i}","target":"x"}|
      end
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    seed_audit(base, "acme", lines)

    rows = Data.load_tail(base, "acme", 3)
    assert length(rows) == 3
    # Last 3 lines (a8, a9, a10) — appended-order preserved.
    assert Enum.map(rows, & &1.action) == ["a8", "a9", "a10"]
  end

  test "preserves append order (oldest-first within the tail window)" do
    base = TmpGlorboHome.setup()

    seed_audit(
      base,
      "acme",
      ~s|{"ts":"2026-04-26T01:00:00Z","actor":"ceo","action":"first","target":"x"}\n| <>
        ~s|{"ts":"2026-04-26T02:00:00Z","actor":"ceo","action":"second","target":"y"}\n| <>
        ~s|{"ts":"2026-04-26T03:00:00Z","actor":"ceo","action":"third","target":"z"}\n|
    )

    rows = Data.load_tail(base, "acme")
    assert Enum.map(rows, & &1.action) == ["first", "second", "third"]
  end

  test "default N is 100" do
    base = TmpGlorboHome.setup()

    lines =
      for i <- 1..150 do
        ~s|{"ts":"2026-04-26T10:00:00Z","actor":"ceo","action":"a#{i}","target":"x"}|
      end
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    seed_audit(base, "acme", lines)

    rows = Data.load_tail(base, "acme")
    assert length(rows) == 100
    # Last 100 — actions a51..a150.
    assert hd(rows).action == "a51"
    assert List.last(rows).action == "a150"
  end
end
