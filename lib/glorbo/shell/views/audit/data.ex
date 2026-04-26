defmodule Glorbo.Shell.Views.Audit.Data do
  @moduledoc """
  GEP-37 Phase 3e — read path for the Audit view.

  Streams the current-month JSONL audit log
  (`companies/<co>/audit/<YYYY-MM>.jsonl`) line-by-line and
  returns the most-recent N decoded entries. Mirrors the
  bounded-memory tail strategy from
  `GlorboWeb.AuditLive.load_tail/2` — JSONL files can grow
  large, so we read once but accumulate only the last N
  lines as we go.

  Phase 3e uses a hard-coded current-month window. Phase 3f
  will add cross-month older-page support + the live-tail
  EventBus subscription that the Phase-1 supervisor already
  wires up.

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

  @spec load_tail(Path.t(), String.t(), pos_integer()) :: [entry_row()]
  def load_tail(base, company, n \\ @default_tail) when is_integer(n) and n > 0 do
    path = audit_path(base, company)

    if File.regular?(path) do
      path
      |> File.stream!([], :line)
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

  defp audit_path(base, company) do
    ym = current_year_month()
    Path.join([base, "companies", company, "audit", "#{ym}.jsonl"])
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
