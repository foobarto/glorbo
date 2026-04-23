defmodule Glorbo.CLI.Bench do
  @moduledoc """
  `glorbo bench` — benchmark-template CLI entry points (GEP-26).

    * `glorbo bench list` — list company templates available for
      `glorbo new company --template <name>`.
    * `glorbo bench run <template> <task-id> --providers a,b,c
      [--keep-shadow]` — fork a shadow company per provider, fire
      the named task, collect outputs under
      `~/.glorbo/benchmarks/runs/<run-id>/`. The scoring UI at
      `/benchmarks/<run-id>` picks the run up automatically.
  """

  alias Glorbo.Benchmarks.Orchestrator
  alias Glorbo.CLI.Scaffold.CompanyTemplate

  @run_switches [providers: :string, keep_shadow: :boolean]

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run([]), do: {:bench, 1, help_text()}
  def run(["--help" | _]), do: {:bench, 0, help_text()}
  def run(["-h" | _]), do: {:bench, 0, help_text()}
  def run(["list" | _]), do: do_list()

  def run(["run" | rest]), do: do_run(rest)

  def run([verb | _]) do
    {:bench, 1, "Unknown bench verb: '#{verb}'. Try `glorbo bench --help`.\n"}
  end

  defp do_run(argv) do
    {opts, positional, _invalid} = OptionParser.parse(argv, strict: @run_switches)

    case positional do
      [template, task_id] ->
        providers = parse_providers_opt(opts[:providers])

        case providers do
          [] ->
            {:bench, 1, "Missing --providers a,b,c.\n\n" <> help_text()}

          list ->
            execute_run(template, task_id, list, keep_shadow?: !!opts[:keep_shadow])
        end

      _ ->
        {:bench, 1,
         "Expected `glorbo bench run <template> <task-id> --providers a,b,c`.\n\n" <>
           help_text()}
    end
  end

  defp parse_providers_opt(nil), do: []

  defp parse_providers_opt(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp execute_run(template, task_id, providers, opts) do
    case Orchestrator.run(template, task_id, providers, opts) do
      {:ok, result} ->
        exit_code = if Enum.all?(result.results, & &1.ok?), do: 0, else: 2
        {:bench, exit_code, render_run_summary(result)}

      {:error, reason} ->
        {:bench, 1, "bench run failed: #{inspect(reason)}\n"}
    end
  end

  defp render_run_summary(result) do
    rows =
      Enum.map_join(result.results, "\n", fn row ->
        glyph = if row.ok?, do: "✓", else: "✗"
        tail = if row.ok?, do: Path.relative_to_cwd(row.path), else: inspect(row.error)
        "  #{glyph} #{row.provider}  #{tail}"
      end)

    """
    bench run #{result.run_id}
    #{rows}

    Manifest: #{Path.relative_to_cwd(result.manifest_path)}
    Score:    /benchmarks/#{result.run_id}
    """
  end

  defp do_list do
    templates = CompanyTemplate.list_templates()

    case templates do
      [] ->
        {:bench, 0, "No benchmark templates installed.\n"}

      list ->
        header = "Available company templates:\n\n"

        body =
          Enum.map_join(list, "\n", fn t ->
            "  * #{t.name} (#{t.archetype}, v#{t.version})\n" <>
              "      #{t.description}\n" <>
              "      default: #{t.default_provider} / #{t.default_model}\n"
          end)

        usage =
          """

          Scaffold with:
            glorbo new company <slug> --template <name>
          """

        {:bench, 0, header <> body <> usage}
    end
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo bench — benchmark-template tooling (GEP-26).

    USAGE
      glorbo bench list
          List available company templates.

      glorbo bench run <template> <task-id> --providers a,b,c [--keep-shadow]
          Fork a shadow company per provider, fire the named task, collect
          outputs under ~/.glorbo/benchmarks/runs/<run-id>/. Score from
          the dashboard at /benchmarks/<run-id>.

    EXAMPLES
      glorbo bench list
      glorbo new company acme-bench --template bench-softdev
      glorbo bench run bench-softdev bugs-1 --providers claude-code,codex,gemini-cli

    See docs/geps/0026-benchmark-templates-and-ab-comparison.md
    for the broader design.
    """
  end
end
