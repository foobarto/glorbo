defmodule Glorbo.Doctor.Formatter do
  @moduledoc """
  Renders `Glorbo.Doctor.run_checks/0` output as a human-readable table
  (default) or stable-keyed JSON (`--json`). Color output honours
  `IO.ANSI.enabled?/0` so pipes and redirected output stay clean (D-20).
  """

  alias IO.ANSI

  # WR-13: read version at runtime from the loaded :glorbo application spec
  # so a release upgrade reports the new version instead of the compile-
  # time constant baked into the binary.
  @spec version() :: String.t()
  defp version do
    case Application.spec(:glorbo, :vsn) do
      nil -> "0.1.0"
      vsn -> to_string(vsn)
    end
  end

  @spec to_table([Glorbo.Doctor.check()]) :: String.t()
  def to_table(results) when is_list(results) do
    header = "Glorbo Doctor — host prerequisite check"
    rows = Enum.map_join(results, "\n", &format_row/1)
    summary = format_summary(results)
    Enum.join([header, "", rows, "", summary], "\n")
  end

  @spec to_json([Glorbo.Doctor.check()]) :: String.t()
  def to_json(results) when is_list(results) do
    passed = Enum.count(results, & &1.pass)
    total = length(results)
    all_passed = passed == total

    Jason.encode!(
      %{
        version: version(),
        checks: results,
        all_passed: all_passed,
        passed_count: passed,
        total_count: total,
        exit_code: Glorbo.Doctor.exit_code(results)
      },
      pretty: true
    )
  end

  defp format_row(%{pass: pass, name: name, detail: detail, required: required} = check) do
    icon = if pass, do: color("✓", :green), else: color("✗", :red)
    label = String.pad_trailing(name, 20)
    sev_tag = severity_tag(Map.get(check, :severity))
    "  #{icon} #{label} #{sev_tag}#{detail} (required: #{required})"
  end

  defp severity_tag(:blocker), do: "[blocker] "
  defp severity_tag(:warning), do: "[warn]    "
  defp severity_tag(_), do: ""

  defp format_summary(results) do
    passed = Enum.count(results, & &1.pass)
    total = length(results)

    if passed == total do
      color("All checks passed (#{passed}/#{total}).", :green)
    else
      color("#{total - passed} check(s) failed (#{passed}/#{total} passed).", :red)
    end
  end

  defp color(text, color) do
    if ANSI.enabled?() do
      [color, text] |> ANSI.format(true) |> IO.iodata_to_binary()
    else
      text
    end
  end
end
