defmodule Glorbo.FileSpec.FindingsFormatter do
  @moduledoc """
  Output formatting for `Glorbo.FileSpec.Validator` findings (R27).

  Renamed in R33 from `Glorbo.FileSpec.Formatter` to avoid clash
  with the (new) file-rewriter module `Glorbo.FileSpec.Formatter`
  which produces canonical on-disk text. This module only formats
  the validator's in-memory findings list for the CLI: human text,
  NDJSON (one finding per line, GEP-25 D6), or a one-line summary
  count.
  """

  @type mode :: :human | :json | :summary

  @doc """
  Render findings per `mode`.

  `stats` carries the counts produced by the validator (used in the
  summary footer / the JSON summary line).
  """
  @spec render(mode(), [Glorbo.FileSpec.finding()], map()) :: iodata()
  def render(:human, findings, stats), do: human(findings, stats)
  def render(:json, findings, stats), do: ndjson(findings, stats)
  def render(:summary, _findings, stats), do: summary(stats)

  # ------------------------------------------------------------------
  # Human
  # ------------------------------------------------------------------

  defp human([], stats), do: ["glorbo validate — ", summary_line(stats), "\n"]

  defp human(findings, stats) do
    [
      Enum.map(findings, &format_finding/1),
      "\n",
      "glorbo validate — ",
      summary_line(stats),
      "\n"
    ]
  end

  defp format_finding(%{severity: sev, file: file, code: code, message: msg, line: line}) do
    loc =
      case line do
        nil -> file
        n -> "#{file}:#{n}"
      end

    [tag(sev), " ", loc, ": ", Atom.to_string(code), " — ", msg, "\n"]
  end

  defp tag(:error), do: "error"
  defp tag(:warning), do: "warn "
  defp tag(:info), do: "info "

  # ------------------------------------------------------------------
  # NDJSON
  # ------------------------------------------------------------------

  defp ndjson(findings, stats) do
    lines =
      for f <- findings do
        json = Jason.encode!(Map.put(f, :type, "finding"))
        [json, "\n"]
      end

    summary_line =
      Jason.encode!(%{
        type: "summary",
        files_examined: stats.files_examined,
        errors: stats.errors,
        warnings: stats.warnings,
        infos: stats.infos,
        total: stats.total
      })

    [lines, summary_line, "\n"]
  end

  # ------------------------------------------------------------------
  # Summary only
  # ------------------------------------------------------------------

  defp summary(stats), do: [summary_line(stats), "\n"]

  defp summary_line(stats) do
    [
      Integer.to_string(stats.files_examined),
      " files · ",
      Integer.to_string(stats.errors),
      " error(s), ",
      Integer.to_string(stats.warnings),
      " warning(s), ",
      Integer.to_string(stats.infos),
      " info(s)"
    ]
  end
end
