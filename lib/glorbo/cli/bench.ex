defmodule Glorbo.CLI.Bench do
  @moduledoc """
  `glorbo bench` — benchmark-template CLI entry points (GEP-26).

  Phase A surface:
    * `glorbo bench list` — list company templates available for
      `glorbo new company --template <name>`.

  Phase B (follow-up, implementing GEP-26 D4):
    * `glorbo bench run <template> <task-id> --providers a,b,c`
      dispatches one task to N providers + records the run.
  """

  alias Glorbo.CLI.Scaffold.CompanyTemplate

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run([]), do: {:bench, 1, help_text()}
  def run(["--help" | _]), do: {:bench, 0, help_text()}
  def run(["-h" | _]), do: {:bench, 0, help_text()}
  def run(["list" | _]), do: do_list()

  def run(["run" | rest]) do
    # Phase B stub — does NOT dispatch anything yet.
    {:bench, 1, stub_run_message(rest)}
  end

  def run([verb | _]) do
    {:bench, 1, "Unknown bench verb: '#{verb}'. Try `glorbo bench --help`.\n"}
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

  defp stub_run_message(_rest) do
    """
    glorbo bench run — Phase B, not implemented yet.

    Tracking: GEP-26 D4. To simulate manually until Phase B ships,
    scaffold one company per provider with:

      glorbo new company bench-claude --template bench-softdev --provider claude-code
      glorbo new company bench-codex  --template bench-softdev --provider codex
      glorbo new company bench-gemini --template bench-softdev --provider gemini-cli

    ...run the same task in each, then eyeball the outputs.
    """
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo bench — benchmark-template tooling (GEP-26).

    USAGE
      glorbo bench list              List available company templates.
      glorbo bench run ...           (Phase B — not yet implemented.)

    EXAMPLES
      glorbo bench list
      glorbo new company acme-bench --template bench-softdev

    See docs/geps/0026-benchmark-templates-and-ab-comparison.md
    for the broader design.
    """
  end
end
