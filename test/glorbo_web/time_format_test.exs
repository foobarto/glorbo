defmodule GlorboWeb.TimeFormatTest do
  use ExUnit.Case, async: true

  alias GlorboWeb.TimeFormat

  @now ~U[2026-04-17 10:30:00Z]

  describe "relative/2" do
    test "just now for <10s diff" do
      assert TimeFormat.relative(~U[2026-04-17 10:29:58Z], @now) == "just now"
    end

    test "seconds for <1 min" do
      assert TimeFormat.relative(~U[2026-04-17 10:29:20Z], @now) == "40s ago"
    end

    test "minutes for <1 hour" do
      assert TimeFormat.relative(~U[2026-04-17 10:00:00Z], @now) == "30 min ago"
    end

    test "hours for <1 day" do
      assert TimeFormat.relative(~U[2026-04-17 05:30:00Z], @now) == "5 h ago"
    end

    test "days for <1 week" do
      assert TimeFormat.relative(~U[2026-04-14 10:30:00Z], @now) == "3 d ago"
    end

    test "absolute date for older than a week" do
      assert TimeFormat.relative(~U[2026-04-01 10:30:00Z], @now) == "2026-04-01"
    end

    test "future timestamp" do
      assert TimeFormat.relative(~U[2026-04-17 10:35:00Z], @now) == "in the future"
    end

    test "accepts ISO 8601 strings" do
      assert TimeFormat.relative("2026-04-17T10:00:00Z", @now) == "30 min ago"
    end

    test "returns empty string for garbage input" do
      assert TimeFormat.relative("not a timestamp", @now) == ""
      assert TimeFormat.relative(nil, @now) == ""
      assert TimeFormat.relative(42, @now) == ""
    end

    test "accepts NaiveDateTime" do
      {:ok, ndt} = NaiveDateTime.from_iso8601("2026-04-17T10:00:00")
      assert TimeFormat.relative(ndt, @now) == "30 min ago"
    end
  end

  describe "iso/1" do
    test "DateTime → ISO8601" do
      assert TimeFormat.iso(~U[2026-04-17 10:30:00Z]) == "2026-04-17T10:30:00Z"
    end

    test "string passes through" do
      assert TimeFormat.iso("2026-04-17T10:30:00Z") == "2026-04-17T10:30:00Z"
    end

    test "garbage → empty" do
      assert TimeFormat.iso(nil) == ""
      assert TimeFormat.iso(42) == ""
    end
  end
end
