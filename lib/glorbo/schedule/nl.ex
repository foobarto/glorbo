defmodule Glorbo.Schedule.NL do
  @moduledoc """
  Natural-language → cron expression compiler (#233 T3-A).

  Intent: let directors write `heartbeat: "every morning at 9am"`
  in `AGENT.md` instead of remembering that `0 9 * * *` means "9:00
  UTC daily." We still store and execute cron — this is a thin
  pre-processor that runs at spec-validation time.

  Scope is deliberately small. We support the phrasings real users
  actually type. Anything we can't confidently translate returns
  `:error` and the caller falls back to treating the value as a
  literal cron expression (existing behaviour). That means:

    * Literal cron expressions (`"0 9 * * *"`) pass through untouched
      — we never "improve" a valid cron string.
    * Recognised NL → valid cron.
    * Anything else → `:error` so Parser can surface the original
      string to Crontab.Parser (which will reject it cleanly).

  Supported patterns (case-insensitive, whitespace tolerant):

    * `"every morning"` / `"daily morning"` → `0 9 * * *`
    * `"every afternoon"` → `0 14 * * *`
    * `"every evening"` → `0 18 * * *`
    * `"every night"` → `0 22 * * *`
    * `"every <time>"` where `<time>` is `9am`, `9:30am`, `14:00`,
      `2:30pm` → minute/hour cron, days wildcard.
    * `"daily at <time>"` → same as `every <time>`.
    * `"every monday at 9am"` (any weekday name) → weekday cron.
    * `"every hour"` → `0 * * * *`.
    * `"every <N> minutes"` (5 / 10 / 15 / 20 / 30 / 60) →
      `*/N * * * *`.

  Everything else returns `:error`.
  """

  @type result :: {:ok, String.t()} | :error

  @morning_map %{
    "morning" => {0, 9},
    "afternoon" => {0, 14},
    "evening" => {0, 18},
    "night" => {0, 22}
  }

  @weekdays %{
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sunday" => 0
  }

  @doc """
  Compile `input` to a 5-field cron expression, or return `:error`
  if the input doesn't match a supported pattern.

  Cron expressions pass through untouched when they already parse —
  no NL detection is attempted on them.
  """
  @spec compile(String.t()) :: result()
  def compile(input) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      trimmed == "" ->
        :error

      cron_like?(trimmed) ->
        {:ok, trimmed}

      true ->
        try_patterns(String.downcase(trimmed))
    end
  end

  def compile(_), do: :error

  # A string is cron-like if it has exactly 5 whitespace-separated
  # tokens AND every token uses only characters valid in cron
  # (digits, `*`, `/`, `-`, `,`, `?`, `L`). "whenever I feel like it"
  # is 5 tokens but contains English letters — we want NL patterns
  # like that to fall through to try_patterns, not be pass-through'd.
  defp cron_like?(s) do
    parts = String.split(s, ~r/\s+/)

    length(parts) == 5 and
      Enum.all?(parts, &Regex.match?(~r/\A[0-9*\/,\-?LW#]+\z/, &1))
  end

  # Master dispatcher — try each pattern in declaration order.
  defp try_patterns(s) do
    patterns = [
      &match_every_time_of_day/1,
      &match_every_clock_time/1,
      &match_daily_at_time/1,
      &match_every_weekday_at_time/1,
      &match_every_hour/1,
      &match_every_n_minutes/1
    ]

    Enum.reduce_while(patterns, :error, fn pat, _acc ->
      case pat.(s) do
        {:ok, cron} -> {:halt, {:ok, cron}}
        :error -> {:cont, :error}
      end
    end)
  end

  # "every morning" / "daily morning"
  defp match_every_time_of_day(s) do
    case Regex.run(~r/^(?:every|daily)\s+(morning|afternoon|evening|night)$/, s) do
      [_, period] ->
        {m, h} = Map.fetch!(@morning_map, period)
        {:ok, "#{m} #{h} * * *"}

      _ ->
        :error
    end
  end

  # "every 9am" / "every 14:30" / "every 2:30pm"
  defp match_every_clock_time(s) do
    case Regex.run(~r/^every\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/, s) do
      [_, hh | rest] ->
        {mm, suffix} = split_rest(rest)
        build_clock_cron(hh, mm, suffix, "* * *")

      _ ->
        :error
    end
  end

  # "daily at 9am" / "daily at 14:30"
  defp match_daily_at_time(s) do
    case Regex.run(~r/^daily\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/, s) do
      [_, hh | rest] ->
        {mm, suffix} = split_rest(rest)
        build_clock_cron(hh, mm, suffix, "* * *")

      _ ->
        :error
    end
  end

  # "every monday at 9am"
  defp match_every_weekday_at_time(s) do
    case Regex.run(
           ~r/^every\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/,
           s
         ) do
      [_, day, hh | rest] ->
        {mm, suffix} = split_rest(rest)
        dow = Map.fetch!(@weekdays, day)
        build_clock_cron(hh, mm, suffix, "* * #{dow}")

      _ ->
        :error
    end
  end

  # Regex.run drops trailing nil captures, so the tail can be 0, 1, or 2
  # elements. Normalise to `{mm, suffix}` where either can be "".
  defp split_rest([]), do: {"", ""}
  defp split_rest([mm]), do: {mm, ""}
  defp split_rest([mm, suffix]), do: {mm, suffix}

  # "every hour"
  defp match_every_hour(s) do
    case s do
      "every hour" -> {:ok, "0 * * * *"}
      "hourly" -> {:ok, "0 * * * *"}
      _ -> :error
    end
  end

  # "every 15 minutes" / "every 5 minutes"
  defp match_every_n_minutes(s) do
    case Regex.run(~r/^every\s+(\d+)\s+minutes?$/, s) do
      [_, n] ->
        n_int = String.to_integer(n)

        if n_int in [1, 2, 5, 10, 15, 20, 30, 60] do
          if n_int == 60, do: {:ok, "0 * * * *"}, else: {:ok, "*/#{n_int} * * * *"}
        else
          :error
        end

      _ ->
        :error
    end
  end

  # Common helper: (hh, mm, suffix, tail) → cron string.
  defp build_clock_cron(hh, mm, suffix, tail) do
    hh_int = String.to_integer(hh)
    mm_int = if mm == "", do: 0, else: String.to_integer(mm)

    with {:ok, hour24} <- to_24h(hh_int, suffix),
         true <- mm_int in 0..59 and hour24 in 0..23 do
      {:ok, "#{mm_int} #{hour24} #{tail}"}
    else
      _ -> :error
    end
  end

  defp to_24h(h, "am") when h in 1..12, do: {:ok, rem(h, 12)}
  defp to_24h(h, "pm") when h in 1..12, do: {:ok, rem(h, 12) + 12}
  defp to_24h(h, "") when h in 0..23, do: {:ok, h}
  defp to_24h(h, nil) when h in 0..23, do: {:ok, h}
  defp to_24h(_, _), do: :error
end
