defmodule Glorbo.ScheduleNLTest do
  @moduledoc """
  Unit tests for `Glorbo.ScheduleNL.parse/1` (#280).

  Round 16 — the NL-to-cron bridge. Display layer (#237) has
  shown these phrases on kanban cards since v0.0.3; now they
  actually fire.
  """
  use ExUnit.Case, async: true

  alias Glorbo.ScheduleNL

  describe "time-of-day with defaults" do
    test ~s("every morning" → 9 AM),
      do: assert(ScheduleNL.parse("every morning") == {:ok, "0 9 * * *"})

    test ~s("every evening" → 6 PM),
      do: assert(ScheduleNL.parse("every evening") == {:ok, "0 18 * * *"})

    test ~s("every night" → 10 PM),
      do: assert(ScheduleNL.parse("every night") == {:ok, "0 22 * * *"})

    test ~s("every noon" → 12:00),
      do: assert(ScheduleNL.parse("every noon") == {:ok, "0 12 * * *"})

    test ~s("every midnight" → 00:00),
      do: assert(ScheduleNL.parse("every midnight") == {:ok, "0 0 * * *"})
  end

  describe "time-of-day with explicit `at`" do
    test ~s("every morning at 9am" → 9 AM),
      do: assert(ScheduleNL.parse("every morning at 9am") == {:ok, "0 9 * * *"})

    test ~s("every morning at 10:30" → 10:30 UTC),
      do: assert(ScheduleNL.parse("every morning at 10:30") == {:ok, "30 10 * * *"})

    test ~s("every evening at 6pm" → 18:00),
      do: assert(ScheduleNL.parse("every evening at 6pm") == {:ok, "0 18 * * *"})

    test ~s("every night at 11:45pm" → 23:45),
      do: assert(ScheduleNL.parse("every night at 11:45pm") == {:ok, "45 23 * * *"})
  end

  describe "weekdays" do
    test ~s("every monday" → 9 AM Monday),
      do: assert(ScheduleNL.parse("every monday") == {:ok, "0 9 * * 1"})

    test ~s("every friday at 6pm" → 18:00 Friday),
      do: assert(ScheduleNL.parse("every friday at 6pm") == {:ok, "0 18 * * 5"})

    test ~s("every sunday" → 9 AM Sunday),
      do: assert(ScheduleNL.parse("every sunday") == {:ok, "0 9 * * 0"})
  end

  describe "compound weekday buckets" do
    test ~s("every weekday" → Mon-Fri 9 AM),
      do: assert(ScheduleNL.parse("every weekday") == {:ok, "0 9 * * 1-5"})

    test ~s("every weekend" → Sat+Sun 10 AM),
      do: assert(ScheduleNL.parse("every weekend") == {:ok, "0 10 * * 0,6"})
  end

  describe "intervals" do
    test ~s("every minute"),
      do: assert(ScheduleNL.parse("every minute") == {:ok, "* * * * *"})

    test ~s("every 5 minutes"),
      do: assert(ScheduleNL.parse("every 5 minutes") == {:ok, "*/5 * * * *"})

    test ~s("every 15 minutes"),
      do: assert(ScheduleNL.parse("every 15 minutes") == {:ok, "*/15 * * * *"})

    test ~s("every hour"),
      do: assert(ScheduleNL.parse("every hour") == {:ok, "0 * * * *"})

    test ~s("every 2 hours"),
      do: assert(ScheduleNL.parse("every 2 hours") == {:ok, "0 */2 * * *"})

    test ~s("every day" → 9 AM default),
      do: assert(ScheduleNL.parse("every day") == {:ok, "0 9 * * *"})
  end

  describe "normalisation" do
    test "uppercase accepted",
      do: assert(ScheduleNL.parse("EVERY MORNING") == {:ok, "0 9 * * *"})

    test "extra whitespace collapsed",
      do: assert(ScheduleNL.parse("  every   morning   at  9am  ") == {:ok, "0 9 * * *"})

    test "mixed case weekday",
      do: assert(ScheduleNL.parse("every Monday") == {:ok, "0 9 * * 1"})
  end

  describe "falls through to :error" do
    test "5-field cron not this module's job",
      do: assert(ScheduleNL.parse("0 9 * * 1-5") == :error)

    test "unsupported phrase",
      do: assert(ScheduleNL.parse("every blue moon") == :error)

    test "missing subject",
      do: assert(ScheduleNL.parse("every") == :error)

    test "non-string input",
      do: assert(ScheduleNL.parse(nil) == :error)

    test "empty string",
      do: assert(ScheduleNL.parse("") == :error)

    test ~s("every other Tuesday" — alternating schedules out of scope),
      do: assert(ScheduleNL.parse("every other tuesday") == :error)

    test "garbage at time",
      do: assert(ScheduleNL.parse("every morning at hogwash") == :error)
  end
end
