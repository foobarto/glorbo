defmodule Glorbo.CLI do
  @moduledoc """
  Release-binary CLI dispatch. Pure — no side effects. Called from
  `Glorbo.Application.start/2` when `Burrito.Util.Args.argv/0` is non-empty.

  `dispatch/1` returns a `{verb, exit_code, output}` tuple. The caller is
  responsible for printing `output` and halting with `exit_code`; tests call
  `dispatch/1` directly and assert the tuple shape, no CaptureIO needed.

  Per user-confirmed A6 (Phase 1 CONTEXT): `./glorbo` (no args) prints help
  and exits 0. The explicit headless verb `./glorbo run` / `serve` lands in
  Phase 5; for now, no verb = help.
  """

  alias Glorbo.Doctor
  alias Glorbo.Doctor.Formatter

  @type verb :: :doctor | :help | :unknown
  @type result :: {verb(), 0 | 1 | 2, String.t()}

  @doctor_switches [json: :boolean]

  @spec dispatch([String.t()]) :: result()
  def dispatch([]), do: {:help, 0, help_text()}
  def dispatch(["-h" | _]), do: {:help, 0, help_text()}
  def dispatch(["--help" | _]), do: {:help, 0, help_text()}
  def dispatch(["help" | _]), do: {:help, 0, help_text()}

  def dispatch(["doctor" | rest]) do
    {opts, _argv, _invalid} = OptionParser.parse(rest, strict: @doctor_switches)
    results = Doctor.run_checks()

    output =
      if opts[:json] do
        Formatter.to_json(results)
      else
        Formatter.to_table(results)
      end

    exit_code = Glorbo.Doctor.exit_code(results)
    {:doctor, exit_code, output}
  end

  def dispatch([verb | _]) do
    {:unknown, 1, "Unknown command: #{verb}\n\n" <> help_text()}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    Glorbo 0.1.0 — filesystem-first agent orchestration

    USAGE
      glorbo <command> [args]

    COMMANDS
      doctor [--json]   Verify host prerequisites (kernel, uidmap, disk, ~/.glorbo/, ERTS)
      help              Print this message

    Additional commands (init, up, down, serve, status, ...) are delivered in
    Phases 2-5. See DESIGN.md §10 for the full CLI surface.
    """
  end
end
