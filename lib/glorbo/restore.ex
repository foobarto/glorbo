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
  require Logger
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
         {:ok, private_archive} <- copy_archive_to_private(archive, base) do
      try do
        with :ok <- traversal_guard(private_archive),
             :ok <- extract(private_archive, base),
             :ok <- maybe_migrate(repo, skip_migrate?),
             :ok <- reindex(base) do
          maybe_fixer(skip_fixer?)
        end
      after
        _ = File.rm(private_archive)
      end
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

  # Gemini round-4 finding (PR #36, LOW): `traversal_guard/1` and
  # `extract/2` each open the archive path independently. On a
  # shared filesystem (archive in `/tmp` with concurrent writers),
  # an attacker who can write to the archive path can swap a
  # verified-safe archive for a malicious one between the two opens.
  # Single-user host: not exploitable. Defense-in-depth: copy the
  # archive bytes once into a private path under `base` (which the
  # daemon user owns), with `O_EXCL`-style exclusive open via
  # `:file.open([:exclusive])`, then run both passes against that
  # immutable local copy. Cleaned up in the `after` block of
  # `run/2`.
  defp copy_archive_to_private(archive, base) do
    File.mkdir_p!(base)
    rand = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    private = Path.join(base, ".restore-input-#{rand}")

    with {:ok, src_fd} <- :file.open(String.to_charlist(archive), [:read, :raw, :binary]),
         {:ok, dst_fd} <-
           :file.open(String.to_charlist(private), [:write, :raw, :binary, :exclusive]) do
      try do
        case :file.copy(src_fd, dst_fd) do
          {:ok, _bytes} -> {:ok, private}
          {:error, reason} -> {:error, {:archive_copy_failed, reason}}
        end
      after
        _ = :file.close(src_fd)
        _ = :file.close(dst_fd)
      end
    else
      {:error, reason} -> {:error, {:archive_copy_failed, reason}}
    end
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

  # Default archive-bomb cap: 10 GiB of summed uncompressed entry bytes
  # (WR-03). Overridable via opts for tests.
  @default_max_uncompressed 10 * 1024 * 1024 * 1024

  defp traversal_guard(archive) do
    with {:ok, names} <- tar_table_names(archive),
         {:ok, headers} <- tar_table_verbose(archive),
         :ok <- reject_path_traversal(names),
         :ok <- reject_symlink_entries(headers) do
      reject_size_overflow(headers, @default_max_uncompressed)
    end
  end

  defp tar_table_names(archive) do
    case :erl_tar.table(String.to_charlist(archive), [:compressed]) do
      {:ok, entries} -> {:ok, Enum.map(entries, &to_string/1)}
      {:error, reason} -> {:error, {:table_failed, reason}}
    end
  end

  defp tar_table_verbose(archive) do
    case :erl_tar.table(String.to_charlist(archive), [:verbose, :compressed]) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, {:table_failed, reason}}
    end
  end

  defp reject_path_traversal(names) do
    dangerous =
      Enum.filter(names, fn name ->
        String.starts_with?(name, "/") or
          ".." in String.split(name, "/", trim: true)
      end)

    if dangerous == [], do: :ok, else: {:error, {:unsafe_archive, dangerous}}
  end

  # Gemini round-4 finding (PR #36): `:erl_tar.extract` materialises
  # entries in archive order, including symlinks. A crafted archive
  # with entry 1 = `evil` (symlink → `/tmp`) and entry 2 =
  # `evil/payload` (regular file) caused the kernel to write
  # `/tmp/payload` during EXTRACT — the post-extract
  # `verify_no_escaping_symlinks` walk caught the residual symlink
  # but couldn't prevent the OOB write that already happened.
  #
  # Defense: refuse ANY archive containing symlink or hardlink
  # entries up-front, BEFORE the extract call ever runs.
  # `Glorbo.Backup.run/1` builds archives from a flat file list with
  # `:erl_tar.create` (which follows source-side symlinks and stores
  # the resolved file content, not link records), so no legitimate
  # Glorbo backup contains :symlink / :link entries. Any archive
  # that does is either the attack we're defending against or a
  # non-Glorbo source we don't support.
  defp reject_symlink_entries(headers) do
    links =
      Enum.filter(headers, fn
        {_name, type, _size, _mtime, _mode, _uid, _gid} -> type in [:symlink, :link]
        _ -> false
      end)

    case links do
      [] ->
        :ok

      _ ->
        bad =
          Enum.map(links, fn {name, type, _size, _mtime, _mode, _uid, _gid} ->
            %{name: to_string(name), type: type}
          end)

        {:error, {:archive_contains_links, bad}}
    end
  end

  # WR-03: sum uncompressed entry sizes and reject archives exceeding the
  # cap. The verbose table surfaces sizes as the 3rd tuple element.
  defp reject_size_overflow(headers, max_bytes) do
    total =
      Enum.reduce(headers, 0, fn
        {_name, _type, size, _mtime, _mode, _uid, _gid}, acc when is_integer(size) ->
          acc + size

        _, acc ->
          acc
      end)

    if total <= max_bytes,
      do: :ok,
      else: {:error, {:archive_too_large, total, max_bytes}}
  end

  defp extract(archive, base) do
    # Transactional extract: unpack into a sibling staging directory
    # first, verify archive integrity + symlink containment, THEN move
    # the contents into `base`. A prior version extracted directly into
    # `base` and only rolled back newly-created top-level entries on
    # rejection, which meant any existing file the archive overwrote
    # was already clobbered before verification ran (codex round-2).
    File.mkdir_p!(base)
    staging = staging_dir_for(base)
    File.mkdir_p!(staging)

    try do
      with :ok <- extract_into(archive, staging),
           :ok <- verify_no_escaping_symlinks(staging) do
        move_staging_into_base(staging, base)
      end
    after
      # Best-effort wipe. Successful moves leave `staging` empty; a
      # verify-rejection leaves the malicious tree under `staging`.
      # Either way, nothing under `base` is touched by this cleanup.
      _ = File.rm_rf(staging)
    end
  end

  defp staging_dir_for(base) do
    ts = System.system_time(:microsecond)
    Path.expand(base) <> ".restore-#{ts}"
  end

  defp extract_into(archive, cwd) do
    case :erl_tar.extract(
           String.to_charlist(archive),
           [:compressed, {:cwd, String.to_charlist(cwd)}]
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:extract_failed, reason}}
    end
  end

  defp move_staging_into_base(staging, base) do
    case File.ls(staging) do
      {:ok, entries} ->
        Enum.each(entries, fn name ->
          src = Path.join(staging, name)
          dst = Path.join(base, name)
          # Replace any pre-existing top-level entry atomically from the
          # user's perspective. rename/2 fails across filesystems; fall
          # back to rm + cp_r if that happens.
          _ = File.rm_rf(dst)

          case File.rename(src, dst) do
            :ok ->
              :ok

            {:error, :exdev} ->
              File.cp_r!(src, dst)
              File.rm_rf!(src)

            {:error, reason} ->
              raise "restore: rename #{src} -> #{dst} failed: #{inspect(reason)}"
          end
        end)

        :ok

      {:error, reason} ->
        {:error, {:staging_listing_failed, reason}}
    end
  end

  defp verify_no_escaping_symlinks(base) do
    base_abs = base |> Path.expand() |> Path.absname()

    dangerous =
      base
      |> walk_all_entries()
      |> Enum.flat_map(fn path ->
        case :file.read_link(path) do
          {:ok, target_charlist} ->
            target = to_string(target_charlist)

            # Resolve target relative to the symlink's directory, then
            # check containment under base.
            resolved =
              if Path.type(target) == :absolute do
                Path.expand(target)
              else
                Path.expand(target, Path.dirname(path))
              end

            resolved_abs = Path.absname(resolved)

            if symlink_escapes?(resolved_abs, base_abs) do
              [%{path: Path.relative_to(path, base), target: target}]
            else
              []
            end

          {:error, _} ->
            []
        end
      end)

    if dangerous == [],
      do: :ok,
      else: {:error, {:unsafe_archive_symlinks, dangerous}}
  end

  # True when the resolved symlink target is NOT inside base_abs.
  defp symlink_escapes?(resolved_abs, base_abs) do
    not (resolved_abs == base_abs or
           String.starts_with?(resolved_abs, base_abs <> "/"))
  end

  # Depth-first walk yielding every path under base (files, dirs, symlinks).
  # Uses :file.read_link_info to avoid following symlinks during traversal.
  defp walk_all_entries(root) do
    case :file.list_dir(root) do
      {:ok, entries} ->
        Enum.flat_map(entries, &classify_entry(Path.join(root, to_string(&1))))

      {:error, _} ->
        []
    end
  end

  defp classify_entry(path) do
    case :file.read_link_info(path) do
      {:ok, info} -> classify_by_type(path, info_type(info))
      {:error, _} -> []
    end
  end

  defp classify_by_type(path, :directory), do: [path | walk_all_entries(path)]
  defp classify_by_type(path, _other), do: [path]

  # Extract the :type field from a file_info record without requiring
  # the file.hrl include (brittle across OTP versions). The record shape
  # is {:file_info, size, type, ...} — type is element index 2 (0-based)
  # but :file_info is a record so we use the 3rd tuple element (1-based
  # after the tag).
  defp info_type(info) when is_tuple(info), do: elem(info, 2)

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
      e ->
        Logger.debug("restore: migrate failed — #{inspect(e)}")
        {:error, {:migrate_failed, Exception.message(e)}}
    catch
      :exit, reason ->
        Logger.debug("restore: migrate exited — #{inspect(reason)}")
        {:error, :migrate_failed}
    end
  end

  defp reindex(base) do
    # Reindex.run/1 is typed `{:ok, result()}` only. If it ever starts
    # returning {:error, _} the compiler will flag this clause; for
    # now we surface exceptions + exits via rescue/catch below.
    {:ok, _} = Glorbo.Filesystem.Reindex.run(base: base)
    :ok
  rescue
    e ->
      Logger.debug("restore: reindex raised — #{inspect(e)}")
      {:error, {:reindex_failed, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.debug("restore: reindex exited — #{inspect(reason)}")
      {:error, :reindex_failed}

    kind, reason ->
      Logger.debug("restore: reindex caught #{kind} — #{inspect(reason)}")
      {:error, :reindex_failed}
  end

  defp maybe_fixer(true), do: :ok

  # WR-07: the post-extract doctor --fix run is best-effort (the archive
  # is already on disk; the Director can re-run doctor manually). But
  # silently collapsing every failure to :ok — including fixer bugs and
  # exit-code-bearing results with non-zero codes — hides genuine
  # problems. Emit a structured Logger.warning for each failure mode
  # while keeping the :ok return contract so callers see "restore
  # complete". The audit trail still records the fix attempt.
  defp maybe_fixer(false) do
    case Glorbo.Doctor.Fixer.run([]) do
      {:doctor, 0, _body} ->
        :ok

      {:doctor, code, body} ->
        Logger.warning("post-restore doctor --fix exited #{code}: #{body}")
        :ok

      other ->
        Logger.warning("post-restore doctor --fix returned unexpected shape: #{inspect(other)}")
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "post-restore doctor --fix raised #{inspect(e.__struct__)}: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning("post-restore doctor --fix exited (EXIT): #{inspect(reason)}")
      :ok
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

  defp format_cli_result({:error, {:unsafe_archive_symlinks, entries}}, _archive) do
    {:restore, 2,
     "⚠ archive contains symlinks that escape ~/.glorbo/: #{inspect(entries)}. Refusing to extract.\n"}
  end

  defp format_cli_result({:error, {:archive_contains_links, entries}}, _archive) do
    {:restore, 2,
     "⚠ archive contains symlink/hardlink entries (#{length(entries)}): " <>
       "#{inspect(entries)}. Glorbo backups never contain links — refusing to extract " <>
       "(pre-extract symlink-write defense).\n"}
  end

  defp format_cli_result({:error, {:archive_too_large, total, cap}}, _archive) do
    {:restore, 2,
     "⚠ archive uncompressed size #{total} bytes exceeds cap #{cap} bytes (archive-bomb guard). Refusing to extract.\n"}
  end

  defp format_cli_result({:error, {:archive_copy_failed, reason}}, _archive) do
    {:restore, 2, "Failed to stage archive into private location: #{inspect(reason)}.\n"}
  end

  defp format_cli_result({:error, reason}, _archive) do
    {:restore, 2, "Restore failed: #{inspect(reason)}\n"}
  end
end
