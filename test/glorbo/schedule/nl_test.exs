defmodule Glorbo.Schedule.NLTest do
  use ExUnit.Case, async: true

  alias Glorbo.Schedule.NL

  describe "pass-through" do
    test "literal cron expression with 5 fields untouched" do
      assert {:ok, "0 9 * * *"} = NL.compile("0 9 * * *")
      assert {:ok, "*/15 * * * *"} = NL.compile("*/15 * * * *")
      assert {:ok, "30 14 * * 1-5"} = NL.compile("30 14 * * 1-5")
    end

    test "blank input returns :error" do
      assert :error = NL.compile("")
      assert :error = NL.compile("   ")
    end

    test "non-string returns :error" do
      assert :error = NL.compile(nil)
      assert :error = NL.compile(42)
    end
  end

  describe "times of day" do
    test "every morning → 9am" do
      assert {:ok, "0 9 * * *"} = NL.compile("every morning")
    end

    test "every afternoon → 2pm" do
      assert {:ok, "0 14 * * *"} = NL.compile("every afternoon")
    end

    test "every evening → 6pm" do
      assert {:ok, "0 18 * * *"} = NL.compile("every evening")
    end

    test "every night → 10pm" do
      assert {:ok, "0 22 * * *"} = NL.compile("every night")
    end

    test "daily morning normalises like every morning" do
      assert {:ok, "0 9 * * *"} = NL.compile("daily morning")
    end

    test "case-insensitive + whitespace tolerant" do
      assert {:ok, "0 9 * * *"} = NL.compile("  Every   Morning  ")
    end
  end

  describe "clock times" do
    test "every 9am → 0 9" do
      assert {:ok, "0 9 * * *"} = NL.compile("every 9am")
    end

    test "every 9:30am → 30 9" do
      assert {:ok, "30 9 * * *"} = NL.compile("every 9:30am")
    end

    test "every 2:30pm → 30 14" do
      assert {:ok, "30 14 * * *"} = NL.compile("every 2:30pm")
    end

    test "every 14:00 (24h) → 0 14" do
      assert {:ok, "0 14 * * *"} = NL.compile("every 14:00")
    end

    test "12am → 0h (midnight)" do
      assert {:ok, "0 0 * * *"} = NL.compile("every 12am")
    end

    test "12pm → 12h (noon)" do
      assert {:ok, "0 12 * * *"} = NL.compile("every 12pm")
    end

    test "invalid hour rejected" do
      assert :error = NL.compile("every 25:00")
      assert :error = NL.compile("every 13pm")
    end

    test "invalid minute rejected" do
      assert :error = NL.compile("every 9:99")
    end

    test "daily at … variant" do
      assert {:ok, "0 9 * * *"} = NL.compile("daily at 9am")
      assert {:ok, "30 14 * * *"} = NL.compile("daily at 2:30pm")
    end
  end

  describe "weekdays" do
    test "every monday at 9am → 0 9 * * 1" do
      assert {:ok, "0 9 * * 1"} = NL.compile("every monday at 9am")
    end

    test "every sunday at 10pm → 0 22 * * 0" do
      assert {:ok, "0 22 * * 0"} = NL.compile("every sunday at 10pm")
    end

    test "every friday at 5pm → 0 17 * * 5" do
      assert {:ok, "0 17 * * 5"} = NL.compile("every friday at 5pm")
    end
  end

  describe "hourly + every N minutes" do
    test "every hour" do
      assert {:ok, "0 * * * *"} = NL.compile("every hour")
      assert {:ok, "0 * * * *"} = NL.compile("hourly")
    end

    test "every 15 minutes" do
      assert {:ok, "*/15 * * * *"} = NL.compile("every 15 minutes")
    end

    test "every 5 minutes" do
      assert {:ok, "*/5 * * * *"} = NL.compile("every 5 minutes")
    end

    test "every 60 minutes normalises to every hour" do
      assert {:ok, "0 * * * *"} = NL.compile("every 60 minutes")
    end

    test "unsupported N rejected" do
      assert :error = NL.compile("every 7 minutes")
      assert :error = NL.compile("every 23 minutes")
    end
  end

  describe "unparseable phrases" do
    test "free-form English returns :error" do
      assert :error = NL.compile("whenever I feel like it")
      assert :error = NL.compile("when the clock strikes twelve")
    end

    test "garbled patterns" do
      assert :error = NL.compile("every")
      assert :error = NL.compile("every minute")
    end

    test "`every 9` treated as `every 9:00` (24h)" do
      # A bare hour is legal enough to accept — if the user meant 9am
      # they can say so; if they meant 21:00 they can write 21:00.
      assert {:ok, "0 9 * * *"} = NL.compile("every 9")
    end
  end
end
