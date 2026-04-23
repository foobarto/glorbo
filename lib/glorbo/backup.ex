defmodule Glorbo.Backup do
  @moduledoc """
  Produces a portable tar.gz of `~/.glorbo/` per D-19/D-20/D-21.

  Allowlist: `companies/`, `config.md`, `audit/`, `glorbo.db`.
  Excludes: `bin/`, `models/`, `containers/`, `runtime/`, `run/` (derived /
  re-downloadable).

  Preconditions: glorbo is down (pidfile absent or stale) unless
  `:force_live` is set (D-21). WAL is checkpointed (`PRAGMA
  wal_checkpoint(TRUNCATE)`) before archive to guarantee the archived
  `glorbo.db` is not stale (T-05-10).

  Security:

    * Output archive is written to a private temp path, `chmod 0600`,
      then atomically renamed into place (T-05-06 mitigation).
    * Symlinks are preserved as symlinks (no `:dereference` passed).

  See `.planning/phases/05-cli-completeness-backup-restore-portability/
  05-RESEARCH.md` §Pattern 3 for the reference implementation shape.
  """
  alias Glorbo.CLI.Audit
  alias Glorbo.CLI.Lifecycle.Pidfile

  @includes ~w(companies config.md audit glorbo.db)

  @doc """
  Internal programmatic entry.

  Options:

    * `:base` (`Path.t()`, default `~/.glorbo`) — source root.
    * `:output` (`Path.t()`, default `~/glorbo-backup-<UTC-ISO8601>.tar.gz`) —
      archive output path.
    * `:force_live` (`boolean`, default `false`) — bypass D-21 pidfile guard.
    * `:repo` (`module`, default `Glorbo.Repo`) — repo used for the
      `PRAGMA wal_checkpoint(TRUNCATE)` query.
    * `:skip_checkpoint` (`boolean`, default `false`) — test-only knob. Skips
      the WAL checkpoint (useful when the test does not start the real Repo
      against a live `glorbo.db`).

  Returns `{:ok, output_path}` on success, `{:error, reason}` otherwise.
  """
  @spec run(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def run(opts \\ []) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    output = Keyword.get(opts, :output, default_output_path())
    force_live? = Keyword.get(opts, :force_live, false)
    repo = Keyword.get(opts, :repo, Glorbo.Repo)
    skip_checkpoint? = Keyword.get(opts, :skip_checkpoint, false)

    with :ok <- ensure_down(base, force_live?),
         :ok <- maybe_checkpoint(base, repo, skip_checkpoint?),
         :ok <- recheck_down(base, force_live?),
         :ok <- write_archive(base, output) do
      {:ok, output}
    end
  end

  @doc """
  CLI entry. Parses `--output PATH` and `--force-live`, then routes to
  `run/1`. Emits `cli.backup.start` + `cli.backup.complete` audit events.
  """
  @spec run_cli([String.t()]) :: Glorbo.CLI.result()
  def run_cli(argv) do
    {opts, _positional, _invalid} =
      OptionParser.parse(argv,
        strict: [output: :string, force_live: :boolean, help: :boolean]
      )

    if opts[:help] do
      {:backup, 0, help_text()}
    else
      Audit.emit("backup", "start", %{output: opts[:output]})
      result = run(Keyword.take(opts, [:output, :force_live]))
      format_cli_result(result)
    end
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo backup — produce a portable archive of ~/.glorbo/.

    USAGE
      glorbo backup [--output PATH] [--force-live]

    DEFAULTS
      Output: ~/glorbo-backup-<UTC-ISO8601>.tar.gz
      Precondition: glorbo must be stopped (pidfile absent) unless
      --force-live is passed.

    INCLUDES
      companies/, config.md, audit/, glorbo.db
    EXCLUDES
      bin/, runtime/, run/ (re-downloadable/derived)
    """
  end

  # ------- Internals -------

  defp ensure_down(base, false) do
    case Pidfile.status(base) do
      :stopped -> :ok
      :stale -> :ok
      :running -> {:error, :glorbo_running}
    end
  end

  defp ensure_down(_base, true) do
    IO.warn(
      "--force-live: backing up while glorbo is running (WAL may be unstable)",
      []
    )

    :ok
  end

  # WR-04: re-check pidfile immediately before write_archive to close
  # the TOCTOU window between ensure_down and archive creation. A new
  # `glorbo up` between checkpoint and tar would otherwise capture a
  # half-written state.
  defp recheck_down(_base, true), do: :ok

  defp recheck_down(base, false) do
    case Pidfile.status(base) do
      :stopped -> :ok
      :stale -> :ok
      :running -> {:error, :glorbo_started_during_backup}
    end
  end

  defp maybe_checkpoint(_base, _repo, true), do: :ok

  defp maybe_checkpoint(base, repo, false) do
    db = Path.join(base, "glorbo.db")

    if File.exists?(db) do
      try do
        case Ecto.Adapters.SQL.query(repo, "PRAGMA wal_checkpoint(TRUNCATE)", []) do
          {:ok, %{rows: [[0, _log, _ckpt]]}} ->
            :ok

          {:ok, %{rows: [[1, _log, _ckpt]]}} ->
            {:error, {:checkpoint_busy, "writers still active — run glorbo down first"}}

          {:error, reason} ->
            {:error, {:checkpoint_failed, reason}}

          _ ->
            # Unexpected row shape — treat as checkpoint failure with the
            # raw result so tests/ops can diagnose.
            {:error, {:checkpoint_failed, :unexpected_row_shape}}
        end
      rescue
        e -> {:error, {:checkpoint_failed, Exception.message(e)}}
      end
    else
      :ok
    end
  end

  defp write_archive(base, output) do
    files =
      @includes
      |> Enum.flat_map(fn name ->
        abs = Path.join(base, name)

        if File.exists?(abs) do
          [{String.to_charlist(name), String.to_charlist(abs)}]
        else
          []
        end
      end)

    File.mkdir_p!(Path.dirname(output))
    tmp = output <> ".tmp." <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    case :erl_tar.create(String.to_charlist(tmp), files, [:compressed, :write]) do
      :ok ->
        with :ok <- File.chmod(tmp, 0o600),
             :ok <- File.rename(tmp, output) do
          :ok
        else
          {:error, reason} ->
            _ = File.rm(tmp)
            {:error, {:archive_finalize_failed, reason}}
        end

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:tar_failed, reason}}
    end
  end

  defp format_cli_result({:ok, path}) do
    Audit.emit("backup", "complete", %{path: path})
    {:backup, 0, "✓ backup created: #{path}\n"}
  end

  defp format_cli_result({:error, :glorbo_running}) do
    {:backup, 2, "⚠ glorbo is running. Run `glorbo down` first, or pass --force-live.\n"}
  end

  defp format_cli_result({:error, :glorbo_started_during_backup}) do
    {:backup, 2,
     "⚠ glorbo started mid-backup (pidfile re-check). Aborted to avoid capturing a half-written state.\n"}
  end

  defp format_cli_result({:error, {:checkpoint_busy, msg}}) do
    {:backup, 2, "⚠ SQLite checkpoint busy: #{msg}\n"}
  end

  defp format_cli_result({:error, reason}) do
    {:backup, 2, "Backup failed: #{inspect(reason)}. Run `glorbo doctor` for diagnostics.\n"}
  end

  defp default_output_path do
    ts =
      DateTime.utc_now()
      |> DateTime.to_iso8601()
      |> String.replace(":", "-")

    Path.expand("~/glorbo-backup-#{ts}.tar.gz")
  end
end
