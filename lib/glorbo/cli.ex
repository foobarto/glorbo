defmodule Glorbo.CLI do
  @moduledoc """
  Release-binary CLI dispatch. Pure — no side effects. Called from
  `Glorbo.Application.start/2` when `Burrito.Util.Args.argv/0` is non-empty.

  `dispatch/1` returns a `{verb, exit_code, output}` tuple. The caller is
  responsible for printing `output` and halting with `exit_code`; tests call
  `dispatch/1` directly and assert the tuple shape, no CaptureIO needed.

  Per user-confirmed A6 (Phase 1 CONTEXT): `./glorbo` (no args) prints help
  and exits 0. Plan 05-01 extends the verb set with the full DESIGN.md §10
  surface; unimplemented verbs return Wave-0 stub tuples until Plans 02/03
  fill their respective modules.
  """

  alias Glorbo.CLI.{Lifecycle, Scaffold, Logs, Migrate, Console, DoctorFix}
  alias Glorbo.{Backup, Restore}
  alias Glorbo.Doctor
  alias Glorbo.Doctor.Formatter

  @type verb ::
          :doctor
          | :help
          | :unknown
          | :init
          | :up
          | :down
          | :status
          | :serve
          | :run
          | :new_company
          | :new_agent
          | :new_project
          | :logs
          | :migrate
          | :backup
          | :restore
          | :console
          | :reindex

  @type result :: {verb(), 0 | 1 | 2 | 3, String.t()}

  # init flags. No `--repair` — repair lives under `doctor --fix`.
  @init_switches [force: :boolean, example: :boolean]

  # D-46 + Plan 05-01: `--fix` now routes to `Glorbo.CLI.DoctorFix.run/1`
  # (Wave-0 stub returning a "not implemented in Wave 0 (Plan 03 fills)"
  # tuple; Plan 03 fills the actual Fixer registry).
  @doctor_switches [json: :boolean, fix: :boolean, dry_run: :boolean]

  @spec dispatch([String.t()]) :: result()
  def dispatch([]), do: {:help, 0, help_text()}
  def dispatch(["-h" | _]), do: {:help, 0, help_text()}
  def dispatch(["--help" | _]), do: {:help, 0, help_text()}
  def dispatch(["help"]), do: {:help, 0, help_text()}

  # `glorbo help <verb>` — verb-specific usage text (D-05, like `git help`).
  # Empty verb falls back to global help so `glorbo help ""` doesn't
  # produce a nonsense "Unknown verb: " message (TODO.md Important #12).
  def dispatch(["help", verb | _]) when is_binary(verb) and verb != "" do
    {:help, 0, verb_help_text(verb)}
  end

  def dispatch(["help", _empty | _]), do: {:help, 0, help_text()}

  def dispatch(["init" | rest]) do
    {opts, _argv, _invalid} = OptionParser.parse(rest, strict: @init_switches)
    {_status, summary} = Glorbo.Init.run(opts)
    output = render_init_summary(summary)
    {:init, summary.exit_code, output}
  end

  def dispatch(["doctor" | rest]) do
    {opts, _argv, _invalid} = OptionParser.parse(rest, strict: @doctor_switches)

    if opts[:fix] do
      # Plan 05-01: route --fix through the DoctorFix module. Wave-0 stub
      # returns the "not implemented in Wave 0 (Plan 03 fills)" tuple;
      # Plan 03 populates the actual Fixer registry.
      DoctorFix.run(opts)
    else
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
  end

  # Phase-5 lifecycle verbs (Plan 02 fills).
  def dispatch(["up" | rest]), do: Lifecycle.Up.run(rest)
  def dispatch(["down" | rest]), do: Lifecycle.Down.run(rest)
  def dispatch(["status" | rest]), do: Lifecycle.Status.run(rest)
  def dispatch(["serve" | rest]), do: Lifecycle.Serve.run(rest)
  def dispatch(["run" | rest]), do: Lifecycle.Run.run(rest)

  # Phase-5 scaffolding (Plan 02 fills). `new` without a subcommand or with
  # an unknown subcommand returns :unknown/1 per D-04.
  def dispatch(["new", "company" | rest]), do: Scaffold.Company.run(rest)
  def dispatch(["new", "agent" | rest]), do: Scaffold.Agent.run(rest)
  def dispatch(["new", "project" | rest]), do: Scaffold.Project.run(rest)

  def dispatch(["new", sub | _]) do
    {:unknown, 1, "Unknown subcommand: new #{sub}\n\n" <> help_text()}
  end

  def dispatch(["new"]) do
    {:unknown, 1, "Usage: glorbo new {company|agent|project} <slug>\n\n" <> help_text()}
  end

  # Phase-5 observability + maintenance + portability + ops.
  def dispatch(["logs" | rest]), do: Logs.run(rest)
  def dispatch(["migrate" | rest]), do: Migrate.run(rest)
  def dispatch(["backup" | rest]), do: Backup.run_cli(rest)
  def dispatch(["restore" | rest]), do: Restore.run_cli(rest)
  def dispatch(["console" | rest]), do: Console.run(rest)

  def dispatch(["reindex" | _rest]) do
    # Documented in help_text + DESIGN.md §10 but previously missing from
    # dispatch/1 — produced a spurious "Unknown command: reindex" for users
    # following the docs. Reindex.run/1 is a pure operation (no daemon
    # required) so the CLI verb runs it directly.
    base = System.get_env("GLORBO_HOME") || Path.expand("~/.glorbo")
    {:ok, %{indexed: i, skipped: s, deleted: d}} = Glorbo.Filesystem.Reindex.run(base: base)
    output = "glorbo reindex — indexed=#{i} skipped=#{s} deleted=#{d}\n"
    {:reindex, 0, output}
  end

  # CATCH-ALL — MUST stay last. Existing Phase-1 tests assert that unknown
  # top-level verbs return :unknown/1.
  def dispatch([verb | _]) do
    {:unknown, 1, "Unknown command: #{verb}\n\n" <> help_text()}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    Glorbo 0.0.3 — filesystem-first agent orchestration

    USAGE
      glorbo <command> [args]

    COMMANDS
      init [--force] [--example|--no-example]
                               Bootstrap a fresh Glorbo install
      up                       Start glorbo in background (writes ~/.glorbo/run/glorbo.pid)
      down                     Stop the running glorbo daemon
      status                   Show run-state (exit 0 running, 3 not running)
      serve                    Run glorbo in the foreground (blocks until SIGINT)
      run <co>/<agent> <task>  One-shot agent dispatch without the dashboard
      new company <slug>       Scaffold a new company directory
      new agent <co>/<slug>    Scaffold a new agent (Director-only)
      new project <co>/<slug>  Scaffold a new project
      logs <co> [agent]        Tail audit or stdout log (--follow, --lines N)
      migrate                  Run Ecto migrations against ~/.glorbo/glorbo.db
      backup [--output PATH]   Produce a portable tar.gz of ~/.glorbo/
      restore <archive>        Extract, migrate, reindex, doctor --fix
      doctor [--json] [--fix]  Verify host prerequisites; --fix repairs what it can
      reindex                  Rebuild ~/.glorbo/glorbo.db from disk
      console                  Open iex --remsh into the running release
      help [<verb>]            Print help (verb-specific when given)

    See DESIGN.md §10 for the full CLI surface and exit-code semantics.
    """
  end

  # ------ verb-specific help routing (D-05) ------

  defp verb_help_text("up"), do: Lifecycle.Up.help_text()
  defp verb_help_text("down"), do: Lifecycle.Down.help_text()
  defp verb_help_text("status"), do: Lifecycle.Status.help_text()
  defp verb_help_text("serve"), do: Lifecycle.Serve.help_text()
  defp verb_help_text("run"), do: Lifecycle.Run.help_text()
  defp verb_help_text("new"), do: new_help_text()
  defp verb_help_text("logs"), do: Logs.help_text()
  defp verb_help_text("migrate"), do: Migrate.help_text()
  defp verb_help_text("backup"), do: Backup.help_text()
  defp verb_help_text("restore"), do: Restore.help_text()
  defp verb_help_text("console"), do: Console.help_text()
  defp verb_help_text("doctor"), do: doctor_help_text()
  defp verb_help_text(_other), do: help_text()

  defp new_help_text do
    """
    glorbo new — scaffold a new company, agent, or project.

    USAGE
      glorbo new company <slug>
      glorbo new agent <company>/<slug>
      glorbo new project <company>/<slug>
    """
  end

  defp doctor_help_text do
    """
    glorbo doctor — verify host prerequisites.

    USAGE
      glorbo doctor [--json] [--fix] [--dry-run]

    FLAGS
      --json      Emit machine-readable JSON instead of the table.
      --fix       Attempt to repair failed checks (see --dry-run).
      --dry-run   With --fix: print repairs without running them.
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
