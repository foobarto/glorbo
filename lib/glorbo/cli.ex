defmodule Glorbo.CLI do
  @moduledoc """
  Release-binary CLI dispatch. Pure — no side effects. Called from
  `Glorbo.Application.start/2` when `Burrito.Util.Args.argv/0` is non-empty.

  `dispatch/1` returns a `{verb, exit_code, output}` tuple. The caller is
  responsible for printing `output` and halting with `exit_code`; tests call
  `dispatch/1` directly and assert the tuple shape, no CaptureIO needed.

  `./glorbo` (no args) prints help and exits 0. The full DESIGN.md §10
  verb surface is wired.
  """

  alias Glorbo.CLI.{
    Console,
    DoctorFix,
    Harness,
    ImportPaperclip,
    Install,
    Lifecycle,
    Logs,
    Migrate,
    Scaffold
  }

  alias Glorbo.{Backup, Restore}
  alias Glorbo.Doctor
  alias Glorbo.Doctor.Formatter

  @type verb ::
          :doctor
          | :help
          | :version
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
          | :new_skill
          | :templates
          | :logs
          | :migrate
          | :backup
          | :restore
          | :console
          | :reindex
          | :import_paperclip
          | :validate
          | :fmt
          | :bench
          | :harness
          | :history
          | :shell
          | :install
          | :uninstall
          | :reset_password

  @type result :: {verb(), 0 | 1 | 2 | 3, String.t()}

  # init flags. No `--repair` — repair lives under `doctor --fix`.
  @init_switches [force: :boolean, example: :boolean]

  # `--fix` routes to `Glorbo.CLI.DoctorFix.run/1` which dispatches to
  # a registry of per-check fixers. `--install-deps` is an opt-in
  # extension that lets fixers actually run `sudo <pkgmgr> install`
  # for missing host packages (bwrap, pasta, uidmap) instead of just
  # printing the install command.
  @doctor_switches [
    json: :boolean,
    fix: :boolean,
    dry_run: :boolean,
    install_deps: :boolean
  ]

  @spec dispatch([String.t()]) :: result()
  def dispatch([]), do: {:help, 0, help_text()}
  def dispatch(["-h" | _]), do: {:help, 0, help_text()}
  def dispatch(["--help" | _]), do: {:help, 0, help_text()}
  def dispatch(["help"]), do: {:help, 0, help_text()}
  def dispatch(["version" | _]), do: {:version, 0, version_text()}
  def dispatch(["--version" | _]), do: {:version, 0, version_text()}
  def dispatch(["-V" | _]), do: {:version, 0, version_text()}

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
  # GEP-0053: clear the director dashboard passphrase (recovery → bootstrap).
  def dispatch(["reset-password" | rest]), do: Lifecycle.ResetPassword.run(rest)
  def dispatch(["run" | rest]), do: Lifecycle.Run.run(rest)

  # Phase-5 scaffolding (Plan 02 fills). `new` without a subcommand or with
  # an unknown subcommand returns :unknown/1 per D-04.
  def dispatch(["new", "company" | rest]), do: Scaffold.Company.run(rest)
  def dispatch(["new", "agent" | rest]), do: Scaffold.Agent.run(rest)
  def dispatch(["new", "project" | rest]), do: Scaffold.Project.run(rest)
  def dispatch(["new", "skill" | rest]), do: Scaffold.Skill.run(rest)

  def dispatch(["new", sub | _]) do
    {:unknown, 1, "Unknown subcommand: new #{sub}\n\n" <> help_text()}
  end

  def dispatch(["new"]) do
    {:unknown, 1, "Usage: glorbo new {company|agent|project|skill} <slug>\n\n" <> help_text()}
  end

  def dispatch(["templates" | rest]), do: Scaffold.TemplatesVerb.run(rest)

  # GEP-26: benchmark company templates + A/B dispatch.
  def dispatch(["bench" | rest]), do: Glorbo.CLI.Bench.run(rest)
  def dispatch(["harness" | rest]), do: Harness.run(rest)

  # `glorbo import paperclip <src>` — import an agentcompanies tree.
  def dispatch(["import", "paperclip" | rest]), do: ImportPaperclip.run(rest)

  def dispatch(["import", sub | _]) do
    {:unknown, 1, "Unknown subcommand: import #{sub}\n\nSee: glorbo help import\n"}
  end

  def dispatch(["import"]) do
    {:unknown, 1, "Usage: glorbo import paperclip <src-dir> [--as <slug>]\n"}
  end

  # Phase-5 observability + maintenance + portability + ops.
  def dispatch(["logs" | rest]), do: Logs.run(rest)
  def dispatch(["migrate" | rest]), do: Migrate.run(rest)
  def dispatch(["backup" | rest]), do: Backup.run_cli(rest)
  def dispatch(["restore" | rest]), do: Restore.run_cli(rest)
  def dispatch(["console" | rest]), do: Console.run(rest)

  def dispatch(["reindex" | _rest]) do
    # Documented in help_text + DESIGN.md §10. Reindex needs Glorbo.Repo
    # running (it calls Repo.get/3 inside process_file/1) but Burrito's
    # CLI path boots BEFORE the supervision tree — so we start the Repo
    # on demand and stop it when done. Tolerates already-started for the
    # `mix glorbo.cli` dev path where the app is already up.
    base = System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
    repo_started? = ensure_repo_started()

    try do
      {:ok, m} = Glorbo.Filesystem.Reindex.run(base: base)

      output =
        "glorbo reindex — indexed=#{m.indexed} skipped=#{m.skipped} deleted=#{m.deleted} " <>
          "audit_events=#{m.audit_events} approvals=#{m.tasks_approval_state} " <>
          "budgets=#{m.budgets}\n"

      {:reindex, 0, output}
    after
      if repo_started?, do: Glorbo.Repo.stop(5_000)
    end
  end

  # GEP-25 R27 — read-only schema validator. Walks a path (default:
  # GLORBO_HOME), classifies every file via Glorbo.FileSpec, emits
  # findings. `--json` → NDJSON for CI; `--summary` → one-line count;
  # otherwise human-readable text.
  @validate_switches [json: :boolean, summary: :boolean, severity: :string, kind: :string]
  def dispatch(["validate" | rest]) do
    {opts, argv, _invalid} = OptionParser.parse(rest, strict: @validate_switches)

    base = System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
    path = List.first(argv) || base

    findings_opts = []

    findings_opts =
      if opts[:kind], do: Keyword.put(findings_opts, :kind, opts[:kind]), else: findings_opts

    findings_opts =
      case opts[:severity] do
        nil -> findings_opts
        "error" -> Keyword.put(findings_opts, :severity, :error)
        "warning" -> Keyword.put(findings_opts, :severity, :warning)
        "info" -> Keyword.put(findings_opts, :severity, :info)
        _ -> findings_opts
      end

    %{findings: findings, stats: stats} =
      Glorbo.FileSpec.Validator.validate_path(path, findings_opts)

    mode =
      cond do
        opts[:json] -> :json
        opts[:summary] -> :summary
        true -> :human
      end

    output = Glorbo.FileSpec.FindingsFormatter.render(mode, findings, stats)
    exit_code = Glorbo.FileSpec.Validator.exit_code(findings)
    {:validate, exit_code, IO.iodata_to_binary(output)}
  end

  # GEP-25 R33 — syntactic formatter. Default `--check` (read-only,
  # reports drift, exits 1 if any file would change). `--write`
  # applies via atomic tmp+rename. Body prose untouched.
  @fmt_switches [check: :boolean, write: :boolean]
  def dispatch(["fmt" | rest]) do
    {opts, argv, _invalid} = OptionParser.parse(rest, strict: @fmt_switches)

    base = System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
    path = List.first(argv) || base

    result =
      if opts[:write] do
        Glorbo.FileSpec.Formatter.write_path(path)
      else
        Glorbo.FileSpec.Formatter.check_path(path)
      end

    %{changed: changed, stats: stats} = result

    output = render_fmt_output(opts, changed, stats)
    write? = !!opts[:write]
    exit_code = if stats.changed > 0 and not write?, do: 1, else: 0
    {:fmt, exit_code, output}
  end

  # GEP-32 phase 4 — localhost auto-detect for native providers.
  # Probes the known-port ladder, reports what's running. No side
  # effects; activation (creating the provider TOML override) is a
  # separate Director-triggered step.
  @detect_switches [json: :boolean]
  def dispatch(["detect-providers" | rest]) do
    {opts, _argv, _invalid} = OptionParser.parse(rest, strict: @detect_switches)

    detections = Glorbo.Providers.Detect.run()

    output =
      if opts[:json] do
        detections
        |> Enum.map_join("\n", fn det ->
          det
          |> Map.update!(:status, &Atom.to_string/1)
          |> Map.update!(:detail, &normalize_detail_for_json/1)
          |> Jason.encode!()
        end)
        |> Kernel.<>("\n")
      else
        header = "glorbo detect-providers — probed #{length(detections)} localhost candidate(s)\n"
        body = Enum.map_join(detections, "\n", &Glorbo.Providers.Detect.format_line/1)
        header <> body <> "\n"
      end

    exit_code = if Enum.any?(detections, &(&1.status == :ready)), do: 0, else: 1
    {:detect_providers, exit_code, output}
  end

  # GEP-33 Phase 1 — opt-in git history layer for ~/.glorbo/.
  # `init` bootstraps the repo; `status` and `log` are read-only.
  # `show`/`diff`/`restore` land in a follow-up.
  @history_log_switches [limit: :integer]
  def dispatch(["history"]), do: {:history, 1, history_help_text()}
  def dispatch(["history", "--help" | _]), do: {:history, 0, history_help_text()}
  def dispatch(["history", "-h" | _]), do: {:history, 0, history_help_text()}

  def dispatch(["history", "init" | rest]) do
    if rest != [] do
      {:history, 1,
       "glorbo history init — takes no arguments, got #{Enum.join(rest, " ")}\n\n" <>
         history_help_text()}
    else
      case Glorbo.HomeHistory.init([]) do
        {:ok, %{repo: repo, initial_commit: sha, tracked: count}} ->
          out =
            "glorbo history — initialised\n" <>
              "  repo: #{repo}\n" <>
              "  initial commit: #{sha}\n" <>
              "  tracked paths: #{count}\n"

          {:history, 0, out}

        {:error, :already_initialised} ->
          {:history, 1, "glorbo history — already initialised (no-op)\n"}

        {:error, {:base_missing, base}} ->
          {:history, 2, "glorbo history — base directory does not exist: #{base}\n"}

        {:error, reason} ->
          {:history, 2, "glorbo history — init failed: #{inspect(reason)}\n"}
      end
    end
  end

  def dispatch(["history", "status" | _rest]) do
    case Glorbo.HomeHistory.status([]) do
      {:ok, %{enabled: false}} ->
        {:history, 1, "glorbo history — disabled (run `glorbo history init`)\n"}

      {:ok, %{enabled: true, dirty: []}} ->
        {:history, 0, "glorbo history — enabled · clean\n"}

      {:ok, %{enabled: true, dirty: dirty}} ->
        body =
          "glorbo history — enabled · #{length(dirty)} dirty path(s)\n" <>
            Enum.map_join(dirty, "\n", &("  " <> &1)) <> "\n"

        {:history, 0, body}

      {:error, reason} ->
        {:history, 2, "glorbo history — status failed: #{inspect(reason)}\n"}
    end
  end

  def dispatch(["history", "log" | rest]) do
    {opts, _argv, invalid} = OptionParser.parse(rest, strict: @history_log_switches)

    cond do
      invalid != [] ->
        unknown = invalid |> Enum.map_join(" ", fn {k, _} -> k end)

        {:history, 1,
         "glorbo history log — unknown switch(es): #{unknown}\n\n" <> history_help_text()}

      not is_nil(opts[:limit]) and opts[:limit] <= 0 ->
        {:history, 1, "glorbo history log — --limit must be a positive integer\n"}

      true ->
        run_history_log(Keyword.get(opts, :limit, 20))
    end
  end

  def dispatch(["history", "show", rev | _rest]) do
    case Glorbo.HomeHistory.show(rev, []) do
      {:ok, out} ->
        {:history, 0, out <> "\n"}

      {:error, :not_initialised} ->
        {:history, 1, "glorbo history — disabled (run `glorbo history init`)\n"}

      {:error, :invalid_rev} ->
        {:history, 1, "glorbo history show — invalid revision: #{rev}\n"}

      {:error, reason} ->
        {:history, 2, "glorbo history show — failed: #{inspect(reason)}\n"}
    end
  end

  def dispatch(["history", "show" | _]) do
    {:history, 1,
     "glorbo history show <rev> — missing revision argument\n\n" <> history_help_text()}
  end

  @history_diff_switches [path: :string]
  def dispatch(["history", "diff" | rest]) do
    {opts, argv, invalid} = OptionParser.parse(rest, strict: @history_diff_switches)

    cond do
      invalid != [] ->
        unknown = invalid |> Enum.map_join(" ", fn {k, _} -> k end)

        {:history, 1,
         "glorbo history diff — unknown switch(es): #{unknown}\n\n" <> history_help_text()}

      argv == [] ->
        {:history, 1,
         "glorbo history diff <rev> [<rev2>] — missing revision argument\n\n" <>
           history_help_text()}

      true ->
        run_history_diff(argv, opts)
    end
  end

  def dispatch(["history", "restore", rev, path | rest]) do
    # `--yes` performs the actual restore; default is dry-run so a
    # mistyped command never silently mutates the working tree.
    # `HomeHistory.restore/4`'s `:confirm` opt means "the caller has
    # confirmed; do the write" — so map `--yes` → `confirm: true`.
    confirm? = "--yes" in rest

    case Glorbo.HomeHistory.restore(rev, path, %{actor: :director}, confirm: confirm?) do
      {:ok, %{would_restore: path, head_commit: sha}} ->
        {:history, 0,
         "glorbo history restore — would restore #{path} from #{rev} (HEAD=#{sha})\n" <>
           "Re-run with --yes to actually perform the restore.\n"}

      {:ok, %{sha: sha, committed: 1}} ->
        {:history, 0, "glorbo history restore — restored #{path} from #{rev} (commit #{sha})\n"}

      {:ok, %{committed: 0}} ->
        {:history, 0, "glorbo history restore — #{path} at #{rev} matches working tree (no-op)\n"}

      {:error, :not_initialised} ->
        {:history, 1, "glorbo history — disabled (run `glorbo history init`)\n"}

      {:error, :invalid_rev} ->
        {:history, 1, "glorbo history restore — invalid revision: #{rev}\n"}

      {:error, :invalid_path} ->
        {:history, 1, "glorbo history restore — invalid path: #{path}\n"}

      {:error, :path_excluded} ->
        {:history, 1, "glorbo history restore — path is outside tracked scope: #{path}\n"}

      {:error, reason} ->
        {:history, 2, "glorbo history restore — failed: #{inspect(reason)}\n"}
    end
  end

  def dispatch(["history", "restore" | _]) do
    {:history, 1,
     "glorbo history restore <rev> <path> [--yes] — missing arguments\n\n" <> history_help_text()}
  end

  def dispatch(["history", verb | _]) do
    {:history, 1, "Unknown history subcommand: #{verb}\n\n" <> history_help_text()}
  end

  # GEP-37: interactive Director shell. Phase 0 — CLI wiring +
  # placeholder banner; runtime + views land in subsequent rounds.
  def dispatch(["shell" | rest]), do: Glorbo.Shell.run(rest)

  # User-level systemd service install / uninstall. Linux-only;
  # writes ~/.config/systemd/user/glorbo.service and enables it.
  def dispatch(["install" | rest]), do: Install.run(rest)
  def dispatch(["uninstall" | rest]), do: Install.uninstall(rest)

  # CATCH-ALL — MUST stay last. Existing Phase-1 tests assert that unknown
  # top-level verbs return :unknown/1.
  def dispatch([verb | _]) do
    {:unknown, 1, "Unknown command: #{verb}\n\n" <> help_text()}
  end

  defp run_history_diff([rev1], opts) do
    case Glorbo.HomeHistory.diff(rev1, nil, path: opts[:path]) do
      {:ok, out} -> {:history, 0, out <> "\n"}
      {:error, err} -> diff_error_to_message(err)
    end
  end

  defp run_history_diff([rev1, rev2], opts) do
    case Glorbo.HomeHistory.diff(rev1, rev2, path: opts[:path]) do
      {:ok, out} -> {:history, 0, out <> "\n"}
      {:error, err} -> diff_error_to_message(err)
    end
  end

  defp run_history_diff(_, _) do
    {:history, 1,
     "glorbo history diff <rev> [<rev2>] — too many revisions\n\n" <> history_help_text()}
  end

  defp diff_error_to_message(:not_initialised),
    do: {:history, 1, "glorbo history — disabled (run `glorbo history init`)\n"}

  defp diff_error_to_message(:invalid_rev),
    do: {:history, 1, "glorbo history diff — invalid revision\n"}

  defp diff_error_to_message(:invalid_path),
    do: {:history, 1, "glorbo history diff — invalid path\n"}

  defp diff_error_to_message(reason),
    do: {:history, 2, "glorbo history diff — failed: #{inspect(reason)}\n"}

  defp run_history_log(limit) do
    case Glorbo.HomeHistory.log(limit: limit) do
      {:ok, []} ->
        {:history, 0, "glorbo history — no commits\n"}

      {:ok, rows} ->
        body =
          "glorbo history — #{length(rows)} commit(s)\n" <>
            Enum.map_join(rows, "\n", fn r ->
              "  #{r.sha}  #{r.subject} · #{r.author_name} · #{r.relative_time}"
            end) <> "\n"

        {:history, 0, body}

      {:error, :not_initialised} ->
        {:history, 1, "glorbo history — disabled (run `glorbo history init`)\n"}

      {:error, reason} ->
        {:history, 2, "glorbo history — log failed: #{inspect(reason)}\n"}
    end
  end

  defp normalize_detail_for_json(nil), do: nil
  defp normalize_detail_for_json(value) when is_binary(value), do: value
  defp normalize_detail_for_json(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_detail_for_json(value), do: inspect(value)

  defp render_fmt_output(opts, changed, stats) do
    mode = if opts[:write], do: "write", else: "check"

    header =
      "glorbo fmt (#{mode}) — #{stats.files_examined} files · " <>
        "#{stats.changed} changed · #{stats.unchanged} unchanged · #{stats.skipped} skipped\n"

    drift =
      if changed == [] do
        ""
      else
        verb = if opts[:write], do: "rewrote", else: "would rewrite"
        "\n#{verb}:\n" <> Enum.map_join(changed, "\n", fn p -> "  " <> p end) <> "\n"
      end

    header <> drift
  end

  defp ensure_repo_started do
    case Glorbo.Repo.start_link() do
      {:ok, _pid} -> true
      {:error, {:already_started, _pid}} -> false
    end
  end

  @spec version_text() :: String.t()
  def version_text do
    case :application.get_key(:glorbo, :vsn) do
      {:ok, vsn} -> "glorbo " <> List.to_string(vsn)
      _ -> "glorbo unknown"
    end
  end

  @spec help_text() :: String.t()
  def help_text do
    # Read the version from the loaded application spec rather than
    # hardcoding it in the help string. Each `chore(release)` bump
    # to mix.exs would otherwise need a paired help-text edit, and
    # in practice it didn't get one — help drifted to "0.0.4" while
    # mix.exs sat at 0.8.0.
    version =
      case :application.get_key(:glorbo, :vsn) do
        {:ok, vsn} -> List.to_string(vsn)
        _ -> "unknown"
      end

    """
    Glorbo #{version} — filesystem-first agent orchestration

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
      harness ...              Internal native-provider harness (GEP-32)
      new company <slug>       Scaffold a new company directory
      new agent <co>/<slug>    Scaffold a new agent (--template supported)
      new project <co>/<slug>  Scaffold a new project
      new skill <co> <name>    Scaffold a new skill (--template supported)
      templates list [kind]    List agent/skill templates (GEP-10)
      templates show <kind> <name>
                               Print a template's contents
      import paperclip <src>   Import a paperclip.ai agentcompanies tree
      logs <co> [agent]        Tail audit or stdout log (--follow, --lines N)
      migrate                  Run Ecto migrations against ~/.glorbo/glorbo.db
      backup [--output PATH]   Produce a portable tar.gz of ~/.glorbo/
      restore <archive>        Extract, migrate, reindex, doctor --fix
      doctor [--json] [--fix]  Verify host prerequisites; --fix repairs what it can
      reindex                  Rebuild ~/.glorbo/glorbo.db from disk
      validate [PATH]          Check on-disk files against file-format specs (GEP-25)
                               Flags: --json, --summary, --severity lvl, --kind kind
      fmt [PATH]               Normalise YAML frontmatter key order + fences (GEP-25)
                               Flags: --check (default, exits 1 on drift), --write
      detect-providers         Probe localhost for native providers (ollama, llama.cpp,
                               LocalAI, vLLM, LM Studio). No side effects. Flags: --json
      history <sub>            Opt-in git history layer for ~/.glorbo/ (GEP-33).
                               Subcommands: init, status, log [--limit N],
                               show, diff, restore.
      shell                    [alpha] Interactive Director terminal (GEP-37 Phase 0)
      install [--force]        Install + enable user systemd service (Linux)
              [--no-start]
      uninstall                Disable + remove the user systemd service
      console                  Open iex --remsh into the running release
      reset-password           Clear the dashboard passphrase → first-run setup (GEP-0053)
      help [<verb>]            Print help (verb-specific when given)
      version                  Print the binary's version (also: --version, -V)

    See DESIGN.md §10 for the full CLI surface and exit-code semantics.
    """
  end

  # ------ verb-specific help routing (D-05) ------

  defp verb_help_text("up"), do: Lifecycle.Up.help_text()
  defp verb_help_text("down"), do: Lifecycle.Down.help_text()
  defp verb_help_text("status"), do: Lifecycle.Status.help_text()
  defp verb_help_text("serve"), do: Lifecycle.Serve.help_text()
  defp verb_help_text("reset-password"), do: Lifecycle.ResetPassword.help_text()
  defp verb_help_text("run"), do: Lifecycle.Run.help_text()
  defp verb_help_text("harness"), do: Harness.help_text()
  defp verb_help_text("new"), do: new_help_text()
  defp verb_help_text("templates"), do: Scaffold.TemplatesVerb.help_text()
  defp verb_help_text("import"), do: ImportPaperclip.help_text()
  defp verb_help_text("logs"), do: Logs.help_text()
  defp verb_help_text("migrate"), do: Migrate.help_text()
  defp verb_help_text("backup"), do: Backup.help_text()
  defp verb_help_text("restore"), do: Restore.help_text()
  defp verb_help_text("console"), do: Console.help_text()
  defp verb_help_text("doctor"), do: doctor_help_text()
  defp verb_help_text("history"), do: history_help_text()
  defp verb_help_text("install"), do: Install.install_help_text()
  defp verb_help_text("uninstall"), do: Install.uninstall_help_text()
  defp verb_help_text(_other), do: help_text()

  defp history_help_text do
    """
    glorbo history — opt-in git history layer for ~/.glorbo/ (GEP-33).

    USAGE
      glorbo history init                       Bootstrap the repo + write .gitignore
      glorbo history status                     Show enabled/disabled + dirty paths
      glorbo history log [--limit N]            Most recent commits (default N=20)
      glorbo history show <rev>                 Show one commit (metadata + stat)
      glorbo history diff <rev> [<rev2>] [--path P]
                                                Diff a rev vs working tree, or two revs
      glorbo history restore <rev> <path> [--yes]
                                                Restore one path from <rev>; without
                                                --yes shows what would change.

    Filesystem remains the source of truth (GEP-3). Git here is
    derivative — it never replaces the audit log or the working tree.
    Restore appends a new commit describing the restore (append-only).
    """
  end

  defp new_help_text do
    """
    glorbo new — scaffold a new company, agent, project, or skill.

    USAGE
      glorbo new company <slug>
      glorbo new agent <company>/<slug> [--template T]
      glorbo new project <company>/<slug>
      glorbo new skill <company> <name> [--template T]

    See `glorbo templates list` for available templates (GEP-10).
    """
  end

  defp doctor_help_text do
    """
    glorbo doctor — verify host prerequisites.

    USAGE
      glorbo doctor [--json] [--fix] [--dry-run] [--install-deps]

    FLAGS
      --json           Emit machine-readable JSON instead of the table.
      --fix            Attempt to repair failed checks (see --dry-run).
      --dry-run        With --fix: print repairs without running them.
      --install-deps   With --fix: actually run `sudo <pkgmgr> install`
                       for missing host packages (bwrap, pasta, uidmap).
                       Without this flag, --fix only prints the install
                       command for these checks. Detects fedora / debian
                       / ubuntu / arch from /etc/os-release; skips
                       cleanly on unknown distros. Will prompt for sudo
                       password unless cached.
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
