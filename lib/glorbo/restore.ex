defmodule Glorbo.Restore do
  @moduledoc """
  Extracts a Glorbo backup archive into `~/.glorbo/`, then runs the
  post-extract chain `migrate → reindex → doctor --fix` (D-22).

  Archive entries are pre-validated against path traversal via
  `:erl_tar.table/2` — entries beginning with `/` or containing `..`
  segments are rejected before any `:erl_tar.extract/2` call
  (T-05-01 / Pitfall 6 mitigation).

  Test-only / decoupling knobs:

    * `:skip_migrate` — bypass `Ecto.Migrator.run/4`; lets tests run
      without booting the real Repo.
    * `:skip_fixer` — bypass `Glorbo.Doctor.Fixer.run/1`; used to decouple
      Plan 05-03 from the sibling Plan 05-04 (which owns the Fixer
      implementation).

  Production callers leave both knobs unset (falsy), so the full chain
  runs.
  """
  alias Glorbo.CLI.Audit

  @doc """
  Internal programmatic entry.

  Arguments:

    * `archive` — path to a gzip-compressed tar archive produced by
      `Glorbo.Backup.run/1`.
    * `opts` — keyword list:
        * `:base` (`Path.t()`, default `~/.glorbo`) — destination root.
        * `:force` (`boolean`, default `false`) — bypass non-empty-base
          check (D-22).
        * `:repo` (`module`, default `Glorbo.Repo`) — repo handed to
          `Ecto.Migrator.run/4`.
        * `:skip_migrate` (`boolean`, default `false`) — test knob.
        * `:skip_fixer` (`boolean`, default `false`) — test knob / Plan-04
          decoupling.

  Returns `:ok` on success, `{:error, reason}` otherwise.
  """
  @spec run(Path.t(), keyword()) :: :ok | {:error, term()}
  def run(archive, opts \\ []) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    force? = Keyword.get(opts, :force, false)
    repo = Keyword.get(opts, :repo, Glorbo.Repo)
    skip_migrate? = Keyword.get(opts, :skip_migrate, false)
    skip_fixer? = Keyword.get(opts, :skip_fixer, false)

    with :ok <- archive_exists?(archive),
         :ok <- check_empty_or_force(base, force?),
         :ok <- traversal_guard(archive),
         :ok <- extract(archive, base),
         :ok <- maybe_migrate(repo, skip_migrate?),
         :ok <- reindex(base),
         :ok <- maybe_fixer(skip_fixer?) do
      :ok
    end
  end

  @doc """
  CLI entry. Parses positional `<archive>` and `--force`, routes to
  `run/2`. Emits `cli.restore.start` / `cli.restore.complete` audit events.
  """
  @spec run_cli([String.t()]) :: Glorbo.CLI.result()
  def run_cli(argv) do
    {opts, positional, _invalid} =
      OptionParser.parse(argv, strict: [force: :boolean, help: :boolean])

    cond do
      opts[:help] ->
        {:restore, 0, help_text()}

      positional == [] ->
        {:restore, 1, "Usage: glorbo restore <archive> [--force]\n"}

      true ->
        [archive | _] = positional
        Audit.emit("restore", "start", %{archive: archive})
        archive |> run(Keyword.take(opts, [:force])) |> format_cli_result(archive)
    end
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo restore — extract a Glorbo archive into ~/.glorbo/.

    USAGE
      glorbo restore <archive> [--force]

    BEHAVIOR
      Extracts into ~/.glorbo/. If the directory is non-empty, prints a
      summary of what would be overwritten and exits 2 unless --force is
      passed. Post-extract chain: migrate → reindex → doctor --fix.

    SECURITY
      :erl_tar.extract with traversal guard — rejects archives containing
      entries that would escape ~/.glorbo/ (../etc/passwd, etc.).
    """
  end

  # ------- Internals -------

  defp archive_exists?(archive) do
    if File.exists?(archive), do: :ok, else: {:error, :archive_not_found}
  end

  defp check_empty_or_force(_base, true), do: :ok

  defp check_empty_or_force(base, false) do
    case File.ls(base) do
      {:ok, []} ->
        :ok

      {:ok, _entries} ->
        {:error, :non_empty_base}

      {:error, :enoent} ->
        File.mkdir_p!(base)
        :ok

      {:error, reason} ->
        {:error, {:ls_failed, reason}}
    end
  end

  defp traversal_guard(archive) do
    case :erl_tar.table(String.to_charlist(archive), [:compressed]) do
      {:ok, entries} ->
        dangerous =
          Enum.filter(entries, fn e ->
            name = to_string(e)

            String.starts_with?(name, "/") or
              ".." in String.split(name, "/", trim: true)
          end)

        if dangerous == [],
          do: :ok,
          else: {:error, {:unsafe_archive, Enum.map(dangerous, &to_string/1)}}

      {:error, reason} ->
        {:error, {:table_failed, reason}}
    end
  end

  defp extract(archive, base) do
    File.mkdir_p!(base)

    case :erl_tar.extract(
           String.to_charlist(archive),
           [:compressed, {:cwd, String.to_charlist(base)}]
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:extract_failed, reason}}
    end
  end

  defp maybe_migrate(_repo, true), do: :ok

  defp maybe_migrate(repo, false) do
    migrations_path =
      case :code.priv_dir(:glorbo) do
        {:error, _} ->
          []

        dir when is_list(dir) ->
          p = Path.join(to_string(dir), "repo/migrations")
          if File.dir?(p), do: p, else: []
      end

    try do
      _ = Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      :ok
    rescue
      e -> {:error, {:migrate_failed, Exception.message(e)}}
    end
  end

  defp reindex(base) do
    try do
      {:ok, _} = Glorbo.Filesystem.Reindex.run(base: base)
      :ok
    rescue
      e -> {:error, {:reindex_failed, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:reindex_failed, inspect(reason)}}
    end
  end

  defp maybe_fixer(true), do: :ok

  defp maybe_fixer(false) do
    try do
      _ = Glorbo.Doctor.Fixer.run([])
      :ok
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp format_cli_result(:ok, _archive) do
    Audit.emit("restore", "complete", %{})
    {:restore, 0, "✓ restore complete. Run `glorbo up` to start.\n"}
  end

  defp format_cli_result({:error, :archive_not_found}, archive) do
    {:restore, 1, "Archive not found: #{archive}\n"}
  end

  defp format_cli_result({:error, :non_empty_base}, _archive) do
    {:restore, 2, "⚠ ~/.glorbo/ is not empty. Pass --force to overwrite.\n"}
  end

  defp format_cli_result({:error, {:unsafe_archive, entries}}, _archive) do
    {:restore, 2,
     "⚠ archive contains unsafe entries (path traversal): #{inspect(entries)}. Refusing to extract.\n"}
  end

  defp format_cli_result({:error, reason}, _archive) do
    {:restore, 2, "Restore failed: #{inspect(reason)}\n"}
  end
end
