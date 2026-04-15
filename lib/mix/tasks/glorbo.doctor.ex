defmodule Mix.Tasks.Glorbo.Doctor do
  @moduledoc """
  Verifies host prerequisites for running Glorbo.

  ## Usage

      mix glorbo.doctor         # human-readable table
      mix glorbo.doctor --json  # machine-readable JSON

  Exit code `0` when every check passes; `1` when any fail. Non-destructive —
  creates `~/.glorbo/` if missing (idempotent) but never installs system
  packages (D-21).

  The release binary exposes the same surface via `./glorbo doctor`; both
  entry points share `Glorbo.Doctor.run_checks/0`.
  """
  @shortdoc "Verify host prerequisites for Glorbo"

  use Mix.Task

  alias Glorbo.Doctor
  alias Glorbo.Doctor.Formatter

  @switches [json: :boolean]

  @impl Mix.Task
  def run(argv) do
    results = Doctor.run_checks()
    report(results, argv)
  end

  @doc false
  @spec report([Doctor.check()], [String.t()]) :: :ok | no_return()
  def report(results, argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    output =
      if opts[:json] do
        Formatter.to_json(results)
      else
        Formatter.to_table(results)
      end

    IO.puts(output)

    if Enum.all?(results, & &1.pass) do
      :ok
    else
      exit({:shutdown, 1})
    end
  end
end
