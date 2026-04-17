defmodule GlorboWeb.TimeFormat do
  @moduledoc """
  Timestamp formatting helpers for the dashboard.

  TODO.md P1 called out raw ISO 8601 strings (`2026-04-17T10:30:00Z`)
  rendered to Directors across ChannelLive and ApprovalQueueLive. The
  dashboard uses relative labels now ("2 min ago", "3 hours ago",
  "yesterday at 10:30") for recent events and falls back to a terse
  absolute date for anything older than a week.

  The raw ISO string is preserved in the `datetime` attribute on the
  `<time>` element for machine readers and tooltips.
  """

  @doc """
  Convert a timestamp (ISO 8601 string, `DateTime`, or `NaiveDateTime`)
  into a relative/absolute human label. Returns `""` for anything
  unparseable — the caller decides whether to render the row at all.

  The optional `now` parameter is injectable for deterministic tests.
  """
  @spec relative(term(), DateTime.t()) :: String.t()
  def relative(value, now \\ DateTime.utc_now())

  def relative(%DateTime{} = dt, %DateTime{} = now), do: do_relative(dt, now)

  def relative(%NaiveDateTime{} = ndt, %DateTime{} = now) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> do_relative(dt, now)
      _ -> ""
    end
  end

  def relative(iso, %DateTime{} = now) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> do_relative(dt, now)
      _ -> ""
    end
  end

  def relative(_, _), do: ""

  @doc """
  Return the raw ISO string form (or `""`) for use in `<time datetime=>`.
  Accepts the same input shapes as `relative/2`.
  """
  @spec iso(term()) :: String.t()
  def iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def iso(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"
  def iso(iso) when is_binary(iso), do: iso
  def iso(_), do: ""

  # ---------------------------------------------------------------------------
  # Relative-label rendering
  # ---------------------------------------------------------------------------

  defp do_relative(%DateTime{} = dt, %DateTime{} = now) do
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < -60 -> "in the future"
      diff < 10 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 60 * 60 -> "#{div(diff, 60)} min ago"
      diff < 60 * 60 * 24 -> "#{div(diff, 60 * 60)} h ago"
      diff < 60 * 60 * 24 * 7 -> "#{div(diff, 60 * 60 * 24)} d ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end
end
