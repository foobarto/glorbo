defmodule GlorboWeb.AuditExportController do
  @moduledoc """
  CSV export of a company's audit log for the current month
  (#259).

  `GET /companies/:company/audit.csv` streams the current
  month's `audit/YYYY-MM.jsonl` as CSV with columns:
  `ts, actor, action, target, detail_json`.

  Detail is serialised as a JSON string in the last column so
  spreadsheet tools can filter on it without requiring a second
  table. Escapes CSV-breaking characters per RFC 4180 (quote
  wrapping + `"" ` for embedded quotes).

  Read-only; gated by the `:dashboard` pipeline so LAN-exposure
  with `dashboard_token:` set still requires the token (same gate
  as `/api/search`).
  """
  use GlorboWeb, :controller

  @columns ~w(ts actor action target detail)

  def export(conn, %{"company" => co}) do
    if GlorboWeb.Slug.valid?(co) do
      base = Glorbo.Filesystem.Hierarchy.default_root()
      month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
      path = Path.join([base, "companies", co, "audit", "#{month}.jsonl"])

      case File.read(path) do
        {:ok, content} ->
          csv = build_csv(content)

          conn
          |> put_resp_content_type("text/csv")
          |> put_resp_header(
            "content-disposition",
            ~s|attachment; filename="#{co}-audit-#{month}.csv"|
          )
          |> send_resp(200, csv)

        _ ->
          conn
          |> put_resp_content_type("text/csv")
          |> send_resp(200, header_row())
      end
    else
      conn |> send_resp(400, "invalid company slug")
    end
  end

  defp build_csv(content) do
    rows =
      content
      |> String.split("\n", trim: true)
      |> Enum.map(&row_from_line/1)
      |> Enum.reject(&is_nil/1)

    [header_row() | rows] |> Enum.join("")
  end

  defp header_row do
    Enum.join(@columns, ",") <> "\n"
  end

  defp row_from_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = entry} ->
        [
          csv_cell(entry["ts"]),
          csv_cell(entry["actor"]),
          csv_cell(entry["action"]),
          csv_cell(entry["target"]),
          csv_cell(detail_as_json(entry["detail"]))
        ]
        |> Enum.join(",")
        |> Kernel.<>("\n")

      _ ->
        nil
    end
  end

  defp detail_as_json(nil), do: ""
  defp detail_as_json(value) when is_binary(value), do: value

  defp detail_as_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> ""
    end
  end

  @csv_quote "\""
  @csv_escaped_quote "\"\""

  # threatmodel M05: Excel / LibreOffice / Google Sheets treat any
  # cell starting with `= + - @ \t \r` as a formula, so an
  # attacker-controlled audit field (actor, target, detail) can
  # execute spreadsheet code when the CSV is opened. Neutralise
  # by prefixing with a single tick; the CSV content still escapes
  # as a quoted cell because the tick + formula-lead trips the
  # quoting needed check below.
  @formula_leads ["=", "+", "-", "@", "\t", "\r"]

  defp csv_cell(nil), do: ""
  defp csv_cell(value) when not is_binary(value), do: csv_cell(to_string(value))

  defp csv_cell(value) do
    neutralised = neutralise_formula(value)

    if needs_quoting?(neutralised) do
      @csv_quote <> String.replace(neutralised, @csv_quote, @csv_escaped_quote) <> @csv_quote
    else
      neutralised
    end
  end

  defp neutralise_formula(<<c::utf8, _::binary>> = value)
       when <<c::utf8>> in @formula_leads do
    "'" <> value
  end

  defp neutralise_formula(value), do: value

  defp needs_quoting?(value) do
    String.contains?(value, [",", "\"", "\n", "\r", "'"])
  end
end
