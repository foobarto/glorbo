defmodule Gep.Formatter do
  @moduledoc """
  Terminal output for GEP validation results.
  """

  @spec format([Gep.Record.t()], [map()]) :: :ok | no_return()
  def format(records, results) do
    errors = Enum.filter(results, &(&1.severity == :error))
    warnings = Enum.filter(results, &(&1.severity == :warning))

    IO.puts("")

    IO.puts([
      IO.ANSI.cyan(),
      "GEP Validator — ",
      Integer.to_string(length(records)),
      " GEPs checked",
      IO.ANSI.reset()
    ])

    IO.puts("")

    per_gep_results = Enum.filter(results, &Map.has_key?(&1, :gep_number))

    records
    |> Enum.sort_by(& &1.number)
    |> Enum.each(fn record ->
      gep_errors =
        Enum.filter(per_gep_results, &(&1.gep_number == record.number && &1.severity == :error))

      gep_warnings =
        Enum.filter(per_gep_results, &(&1.gep_number == record.number && &1.severity == :warning))

      cond do
        gep_errors != [] ->
          IO.puts([IO.ANSI.red(), "✗ ", gep_label(record), "  ", record.title, IO.ANSI.reset()])

          Enum.each(gep_errors, fn e ->
            IO.puts([IO.ANSI.red(), "    → ", e.detail, IO.ANSI.reset()])
          end)

        gep_warnings != [] ->
          IO.puts([
            IO.ANSI.yellow(),
            "⚠ ",
            gep_label(record),
            "  ",
            record.title,
            IO.ANSI.reset()
          ])

          Enum.each(gep_warnings, fn w ->
            IO.puts([IO.ANSI.yellow(), "    → ", w.detail, IO.ANSI.reset()])
          end)

        true ->
          IO.puts([IO.ANSI.green(), "✓ ", gep_label(record), "  ", record.title, IO.ANSI.reset()])
      end
    end)

    IO.puts("")

    global_results = Enum.filter(results, &(!Map.has_key?(&1, :gep_number)))
    global_errors = Enum.filter(global_results, &(&1.severity == :error))
    global_warnings = Enum.filter(global_results, &(&1.severity == :warning))
    global_passes = Enum.filter(global_results, &(&1.severity == :pass))

    Enum.each(global_passes, fn p ->
      IO.puts([IO.ANSI.green(), "✓ ", p.label, IO.ANSI.reset()])
    end)

    Enum.each(global_errors, fn e ->
      IO.puts([IO.ANSI.red(), "✗ ", e.label, IO.ANSI.reset()])
      IO.puts([IO.ANSI.red(), "    → ", e.detail, IO.ANSI.reset()])
    end)

    Enum.each(global_warnings, fn w ->
      IO.puts([IO.ANSI.yellow(), "⚠ ", w.label, IO.ANSI.reset()])
      IO.puts([IO.ANSI.yellow(), "    → ", w.detail, IO.ANSI.reset()])
    end)

    IO.puts("")

    cond do
      errors == [] and warnings == [] ->
        IO.puts([IO.ANSI.green(), "All checks passed", IO.ANSI.reset()])

      errors == [] ->
        IO.puts([IO.ANSI.yellow(), "#{length(warnings)} warning(s), no errors", IO.ANSI.reset()])

      true ->
        IO.puts([
          IO.ANSI.red(),
          "#{length(errors)} error(s), #{length(warnings)} warning(s)",
          IO.ANSI.reset()
        ])

        exit({:shutdown, 1})
    end
  end

  defp gep_label(%Gep.Record{number: n}), do: "GEP-#{String.pad_leading("#{n}", 4, "0")}"
end
