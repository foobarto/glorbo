defmodule Glorbo.ScheduleNL do
  @moduledoc """
  Tiny English-to-cron parser for the `schedule:` frontmatter
  field (#233 / #280).

  Glorbo's #237 display layer already accepts phrases like `"every
  morning at 9am"` and shows them verbatim on kanban cards. The
  scheduler (#268) previously only accepted 5-field cron
  expressions + a closed alias table (`hourly` / `daily` / ...);
  NL phrases fell through to the parser error path and never
  fired.

  This module bridges the gap. Given an NL phrase, return either
  `{:ok, cron_string}` (which the scheduler parses normally) or
  `:error` (scheduler falls back to its own parser, so a 5-field
  cron is unaffected).

  **Scope:** deliberately small. The grammar handles the
  phrasings directors actually type; anything outside the
  grammar falls through. Extend with demand, not speculation.

  ## Supported phrasings

      "every morning"         → "0 9 * * *"   (9 AM default)
      "every morning at 9am"  → "0 9 * * *"
      "every morning at 10:30" → "30 10 * * *"
      "every evening"         → "0 18 * * *"  (6 PM default)
      "every night"           → "0 22 * * *"  (10 PM default)
      "every weekday"         → "0 9 * * 1-5"
      "every weekday at 9am"  → "0 9 * * 1-5"
      "every weekend"         → "0 10 * * 0,6"
      "every Monday"          → "0 9 * * 1"
      "every Monday at 6pm"   → "0 18 * * 1"
      "every hour"            → "0 * * * *"
      "every 5 minutes"       → "*/5 * * * *"
      "every 2 hours"         → "0 */2 * * *"

  ## Case-insensitive, whitespace-lenient

  Phrases are normalised (trim, lowercase, collapse whitespace)
  before matching.

  ## Non-goals

  - **Timezones.** All times interpret as UTC (matches GEP-24
    D7). Directors wanting local time should write the cron
    directly.
  - **Date ranges / holidays / complex intervals.** Out of
    scope. `"every other Tuesday"`, `"business days except
    holidays"` → `:error`.
  - **Second-level granularity.** Cron minimum is 1 minute.
  """

  @day_of_week %{
    "sunday" => "0",
    "monday" => "1",
    "tuesday" => "2",
    "wednesday" => "3",
    "thursday" => "4",
    "friday" => "5",
    "saturday" => "6"
  }

  @time_of_day %{
    "morning" => 9,
    "evening" => 18,
    "night" => 22,
    "noon" => 12,
    "midnight" => 0
  }

  @doc """
  Try to convert `phrase` to a 5-field cron string. Returns
  `{:ok, cron}` or `:error`.
  """
  @spec parse(String.t()) :: {:ok, String.t()} | :error
  def parse(phrase) when is_binary(phrase) do
    phrase
    |> normalize()
    |> dispatch()
  end

  def parse(_), do: :error

  defp normalize(phrase) do
    phrase
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  # "every N minutes" / "every minute"
  defp dispatch("every minute"), do: {:ok, "* * * * *"}

  defp dispatch("every " <> rest) do
    cond do
      match = Regex.run(~r/^(\d+) minutes?$/, rest) ->
        [_, n] = match
        {:ok, "*/#{n} * * * *"}

      match = Regex.run(~r/^(\d+) hours?$/, rest) ->
        [_, n] = match
        {:ok, "0 */#{n} * * *"}

      rest == "hour" ->
        {:ok, "0 * * * *"}

      rest == "day" ->
        {:ok, "0 9 * * *"}

      rest == "week" ->
        {:ok, "0 9 * * 1"}

      match = parse_weekday(rest) ->
        match

      match = parse_time_of_day(rest) ->
        match

      match = parse_weekday_bucket(rest, "weekday", "1-5", 9) ->
        match

      match = parse_weekday_bucket(rest, "weekend", "0,6", 10) ->
        match

      true ->
        :error
    end
  end

  defp dispatch(_), do: :error

  # `every weekday` / `every weekend` with an optional `at <time>` suffix.
  # Default hour: 9 for weekday, 10 for weekend.
  defp parse_weekday_bucket(rest, label, dow, default_hour) do
    cond do
      rest == label ->
        {:ok, "0 #{default_hour} * * #{dow}"}

      String.starts_with?(rest, label <> " at ") ->
        case parse_time(String.replace_prefix(rest, label <> " at ", "")) do
          {h, m} -> {:ok, "#{m} #{h} * * #{dow}"}
          _ -> nil
        end

      true ->
        nil
    end
  end

  # "monday" or "monday at 9am" or "monday at 18:30"
  defp parse_weekday(rest) do
    {weekday, remainder} = split_at_at(rest)

    case Map.get(@day_of_week, weekday) do
      nil ->
        nil

      dow ->
        case parse_time(remainder) do
          {h, m} -> {:ok, "#{m} #{h} * * #{dow}"}
          nil when remainder == "" -> {:ok, "0 9 * * #{dow}"}
          _ -> nil
        end
    end
  end

  # "morning" / "morning at 10:30"
  defp parse_time_of_day(rest) do
    {word, remainder} = split_at_at(rest)

    case Map.get(@time_of_day, word) do
      nil ->
        nil

      default_hour ->
        case parse_time(remainder) do
          {h, m} -> {:ok, "#{m} #{h} * * *"}
          nil when remainder == "" -> {:ok, "0 #{default_hour} * * *"}
          _ -> nil
        end
    end
  end

  # Split "monday at 9am" → {"monday", "9am"}, "monday" → {"monday", ""}
  defp split_at_at(str) do
    case String.split(str, " at ", parts: 2) do
      [word, rest] -> {word, rest}
      [word] -> {word, ""}
    end
  end

  # Parse "9am" / "9 am" / "9:30am" / "9:30" / "18:30" / "noon" → {hour, minute} or nil.
  defp parse_time(""), do: nil

  defp parse_time(str) do
    str = String.replace(str, " ", "")

    cond do
      # 24-hour "18:30"
      match = Regex.run(~r/^(\d{1,2}):(\d{2})$/, str) ->
        [_, h, m] = match
        {h, m}

      # "9:30am" / "9:30pm"
      match = Regex.run(~r/^(\d{1,2}):(\d{2})(am|pm)$/, str) ->
        [_, h, m, meridiem] = match
        {to_24h(h, meridiem), m}

      # "9am" / "9pm"
      match = Regex.run(~r/^(\d{1,2})(am|pm)$/, str) ->
        [_, h, meridiem] = match
        {to_24h(h, meridiem), "0"}

      # "noon" / "midnight"
      str == "noon" ->
        {"12", "0"}

      str == "midnight" ->
        {"0", "0"}

      true ->
        nil
    end
  end

  defp to_24h(h, "am") do
    case String.to_integer(h) do
      12 -> "0"
      n -> Integer.to_string(n)
    end
  end

  defp to_24h(h, "pm") do
    case String.to_integer(h) do
      12 -> "12"
      n -> Integer.to_string(n + 12)
    end
  end
end
