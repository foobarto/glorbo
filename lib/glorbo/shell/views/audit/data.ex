defmodule Glorbo.Shell.Views.Audit.Data do
  @moduledoc """
  GEP-37 Phase 3e + 3e-revisit — read path for the Audit view.

  Streams a month-bucketed JSONL audit log
  (`companies/<co>/audit/<YYYY-MM>.jsonl`) line-by-line and
  returns the most-recent N decoded entries. Mirrors the
  bounded-memory tail strategy from
  `GlorboWeb.AuditLive.load_tail/2` — JSONL files can grow
  large, so we read once but accumulate only the last N
  lines as we go.

  Phase 3e shipped a hard-coded current-month window; Phase
  3e-revisit (this version) adds cross-month older-page
  support via the `:year_month` opt + the
  `list_year_months/2` enumerator.

  Each row carries:

    * `:ts` — `ts:` from the JSONL line, parsed to an
      ISO 8601 string for display (or the raw string if
      unparseable).
    * `:actor` — `actor:` from the line, or `"?"`.
    * `:action` — `action:` from the line, or `"?"`.
    * `:target` — `target:` from the line, or empty string.
  """

  @typedoc "Slim row used by the TUI Audit view."
  @type entry_row :: %{
          ts: String.t(),
          actor: String.t(),
          action: String.t(),
          target: String.t()
        }

  @default_tail 100

  @doc """
  Load up to N most-recent entries from the named month
  bucket. Opts:

    * `:year_month` — `"YYYY-MM"` bucket to read. Defaults
      to the current UTC month.
    * `:n` — tail size. Defaults to 100.

  Returns `[]` when the file is missing or unreadable. The
  function is `rescue`-wrapped so the view layer always gets
  a renderable list.
  """
  @spec load_tail(Path.t(), String.t(), keyword()) :: [entry_row()]
  def load_tail(base, company, opts \\ []) do
    n = Keyword.get(opts, :n, @default_tail)
    ym = Keyword.get(opts, :year_month, current_year_month())
    path = audit_path(base, company, ym)

    if File.regular?(path) do
      path
      |> File.stream!(:line, [])
      |> Enum.reduce([], fn line, acc ->
        line = String.trim_trailing(line, "\n")

        if line == "" do
          acc
        else
          [line | Enum.take(acc, n - 1)]
        end
      end)
      |> Enum.reverse()
      |> Enum.flat_map(&decode_line/1)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  List the `YYYY-MM` buckets the company has on disk, sorted
  newest-first. The current month is always first in the
  returned list — even when no JSONL file exists yet for it
  — so the view's older-page navigation can always seed
  cursor=0 on "the latest month."
  """
  @spec list_year_months(Path.t(), String.t()) :: [String.t()]
  def list_year_months(base, company) do
    audit_dir = Path.join([base, "companies", company, "audit"])
    current = current_year_month()

    on_disk =
      case File.ls(audit_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.map(&Path.rootname(&1, ".jsonl"))
          |> Enum.filter(&valid_year_month?/1)

        _ ->
          []
      end

    [current | on_disk]
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  defp valid_year_month?(s) when is_binary(s) do
    case Regex.run(~r/^(\d{4})-(\d{2})$/, s) do
      [_, _yr, mm] ->
        case Integer.parse(mm) do
          {month, ""} when month >= 1 and month <= 12 -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_year_month?(_), do: false

  defp audit_path(base, company, year_month) do
    Path.join([base, "companies", company, "audit", "#{year_month}.jsonl"])
  end

  defp current_year_month do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.to_string()
    |> String.slice(0, 7)
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = entry} ->
        [
          %{
            ts: stringify(Map.get(entry, "ts"), ""),
            actor: stringify(Map.get(entry, "actor"), "?"),
            action: stringify(Map.get(entry, "action"), "?"),
            target: stringify(Map.get(entry, "target"), "")
          }
        ]

      _ ->
        []
    end
  end

  defp stringify(nil, default), do: default
  defp stringify(v, _) when is_binary(v), do: v
  defp stringify(v, _), do: to_string(v)
end
