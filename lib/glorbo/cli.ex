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

  @type verb :: :doctor | :help | :unknown | :init
  @type result :: {verb(), 0 | 1 | 2, String.t()}

  # D-23: init flags. No `--repair` (D-46) — repair lives under `doctor --fix`.
  @init_switches [force: :boolean, skip_pull: :boolean, example: :boolean]

  # D-46: `--fix` flag accepted on `doctor`. Phase 2 only parses the flag and
  # emits a "deferred to Phase 5" notice; actual repair logic ships later.
  @doctor_switches [json: :boolean, fix: :boolean]

  @spec dispatch([String.t()]) :: result()
  def dispatch([]), do: {:help, 0, help_text()}
  def dispatch(["-h" | _]), do: {:help, 0, help_text()}
  def dispatch(["--help" | _]), do: {:help, 0, help_text()}
  def dispatch(["help" | _]), do: {:help, 0, help_text()}

  def dispatch(["init" | rest]) do
    {opts, _argv, _invalid} = OptionParser.parse(rest, strict: @init_switches)
    {_status, summary} = Glorbo.Init.run(opts)
    output = render_init_summary(summary)
    {:init, summary.exit_code, output}
  end

  def dispatch(["doctor" | rest]) do
    {opts, _argv, _invalid} = OptionParser.parse(rest, strict: @doctor_switches)
    results = Doctor.run_checks()

    base_output =
      if opts[:json] do
        Formatter.to_json(results)
      else
        Formatter.to_table(results)
      end

    output =
      if opts[:fix] && !opts[:json] do
        base_output <>
          "\n[--fix is a Phase 5 deliverable; no repair performed in Phase 2. Flag accepted silently.]\n"
      else
        base_output
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
      init [--force] [--skip-pull] [--example|--no-example]
                        Bootstrap a fresh Glorbo install (D-22)
      doctor [--json] [--fix]
                        Verify host prerequisites (Phase-2 checks included)
      help              Print this message

    Additional commands (up, down, serve, status, ...) are delivered in
    Phases 3-5. See DESIGN.md §10 for the full CLI surface.
    """
  end

  # ------ init output rendering ------

  defp render_init_summary(%{
         results: rs,
         failures: fs,
         next_steps: ns,
         exit_code: code
       }) do
    lines =
      Enum.map(rs, fn %{step: s, status: st, detail: d} ->
        icon =
          case st do
            :ok -> "✓"
            :skipped -> "⏭"
            :error -> "✗"
          end

        "  #{icon} #{s} — #{d}"
      end)

    footer =
      if fs == [] do
        ["All init steps completed successfully (exit #{code})."]
      else
        ["", "Failures:"] ++ Enum.map(fs, fn f -> "  ✗ #{f.step}: #{f.detail}" end)
      end

    (["Glorbo init"] ++
       lines ++
       footer ++ ["", "Next steps:"] ++ Enum.map(ns, &("  " <> &1)))
    |> Enum.join("\n")
  end
end
