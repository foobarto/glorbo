defmodule Glorbo.Filesystem.Reindex do
  @moduledoc """
  MD5-incremental reindex engine (D-26, D-27).

  Walks `companies/` under the given base, MD5-hashes every `.md` file,
  compares against `reindex_state`, and upserts the `companies` / `agents`
  domain rows when frontmatter changed. Deletes state rows for files that
  vanished from disk.

  **W2 scope:** Phase-2 reindex reconstructs `companies`, `agents`, and
  `reindex_state` only. The `audit_events` table is NOT rebuilt from disk
  here — JSONL is the source of truth, and Phase 3 will add a separate
  import path for audit data.

  **B4 contract (load-bearing):** `process_file/1` is PRIVATE. Plan 04 will
  add a public `process_path/2` wrapper for the watcher integration; do
  NOT promote `process_file/1` to public — that would change the surface
  this plan delivers.

  Symlink defence (T-2-03): before hashing, each candidate path's expansion
  must remain inside `companies_dir`; symlinks that escape are skipped and
  logged.

  Corrupt-YAML behaviour (D-29): logs a warning with the file path, marks
  the file as skipped, continues. Does not crash the reindex.
  """
  require Logger

  import Ecto.Query

  alias Glorbo.{Agent, Company, Repo}
  alias Glorbo.Filesystem.{Frontmatter, ReindexState}

  @type result :: %{indexed: integer(), skipped: integer(), deleted: integer()}

  # WR-14: match Frontmatter's 10 MB cap so a multi-GB markdown file can't
  # OOM the BEAM via File.read!/1 before the parser would have rejected it.
  @max_file_bytes 10_485_760

  @doc """
  Mark a single path as dirty — triggers an incremental re-index of that
  file only (Plan 04, B4). Thin wrapper around `process_path/2`.

  Phase 2: simple — re-process this single file synchronously. Phase 3 may
  replace with an async-queue + batch re-index.
  """
  @spec mark_dirty(String.t(), Path.t()) :: :ok
  def mark_dirty(company, path) do
    _ = process_path(company, path)
    :ok
  end

  @doc """
  Public wrapper around the PRIVATE `process_file/1` (B4 contract).

  `process_file/1` stays `defp` — Plan 04 adds this public wrapper rather
  than promoting the private helper, to keep Plan 01's surface stable.
  The `company` argument is currently unused but reserved for Phase-3
  per-company pipelining.
  """
  @spec process_path(String.t(), Path.t()) :: :indexed | :unchanged | {:skip, term()}
  def process_path(_company, path) do
    process_file(path)
  end

  @doc """
  Run a full reindex pass.

  Options:
    * `:base` — base directory (default: `~/.glorbo`).
  """
  @spec run(keyword()) :: {:ok, result()}
  def run(opts \\ []) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    companies_dir = Path.join(base, "companies")

    if File.dir?(companies_dir) do
      do_run(companies_dir)
    else
      {:ok, %{indexed: 0, skipped: 0, deleted: 0}}
    end
  end

  defp do_run(companies_dir) do
    files = safe_markdown_files(companies_dir)

    # CR-01: Group files by company prefix and skip sub-trees that lack a
    # `company.md`. Otherwise an agent.md without a sibling company.md would
    # be inserted with `company_id: nil`, violating FS-03 ("SQLite fully
    # reconstructible from disk"). Within each company group we still sort
    # so `company.md` is processed BEFORE its nested agents.
    companies_abs = Path.expand(companies_dir)
    by_company = Enum.group_by(files, &company_prefix(&1, companies_abs))

    {indexed, skipped} =
      Enum.reduce(by_company, {0, 0}, fn {co_prefix, paths}, {i, s} ->
        cond do
          co_prefix == nil ->
            # Files not rooted under a company sub-tree — shouldn't happen
            # given the safe_markdown_files filter, but defend anyway.
            {i, s + length(paths)}

          Enum.any?(paths, &String.ends_with?(&1, "/company.md")) ->
            ordered = Enum.sort_by(paths, &{path_kind(&1), &1})
            Enum.reduce(ordered, {i, s}, &accumulate_result/2)

          true ->
            Logger.warning(
              "reindex skipped orphan agents: no company.md under #{co_prefix} (#{length(paths)} file(s))"
            )

            {i, s + length(paths)}
        end
      end)

    deleted = cleanup_vanished(files)

    {:ok, %{indexed: indexed, skipped: skipped, deleted: deleted}}
  end

  # Returns the absolute path to the immediate child of `companies_dir` that
  # contains `path`, or nil when the path is not nested under one.
  defp company_prefix(path, companies_abs) do
    expanded = Path.expand(path)

    case String.split(expanded, companies_abs <> "/", parts: 2) do
      [_, rest] ->
        case String.split(rest, "/", parts: 2) do
          [co | _] when co != "" -> Path.join(companies_abs, co)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp accumulate_result(path, {idx, skp}) do
    case process_file(path) do
      :indexed ->
        {idx + 1, skp}

      :unchanged ->
        {idx, skp}

      {:skip, reason} ->
        Logger.warning("reindex skipped #{path}: #{inspect(reason)}")
        {idx, skp + 1}
    end
  end

  # Collect *.md under companies_dir; reject any path whose realpath escapes
  # companies_dir (symlink-escape defence per T-2-03).
  defp safe_markdown_files(companies_dir) do
    companies_abs = Path.expand(companies_dir)

    companies_dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      expanded = Path.expand(path)

      if String.starts_with?(expanded, companies_abs <> "/") or expanded == companies_abs do
        true
      else
        Logger.warning("reindex rejected path (escapes companies_dir): #{path}")
        false
      end
    end)
  end

  # Ordering key: 0 = company.md (parent), 1 = AGENT.md / agent.md (child),
  # 2 = other. Ensures parents are inserted before children so company_id
  # resolves.
  defp path_kind(path) do
    cond do
      String.ends_with?(path, "/company.md") -> 0
      Regex.match?(~r{/agents/[^/]+/(?:AGENT|agent)\.md$}, path) -> 1
      true -> 2
    end
  end

  # B4 CONTRACT: process_file/1 is PRIVATE. Plan 04 will wrap it via a
  # public process_path/2 — do NOT promote this to `def`.
  defp process_file(path) do
    # Threatmodel wave 6: watcher-delivered paths are untrusted filesystem
    # inputs. `File.stat/1` follows the final symlink, so a symlinked
    # `company.md` or `agent.md` would be read and hashed as if it were a
    # real in-tree markdown file. Reject non-regular leaves at the outer seam.
    #
    # WR-14: lstat-check first so an oversize file never gets slurped into
    # memory. Frontmatter.parse/1 has its own cap but only after the full
    # read. Streaming the MD5 for under-cap files keeps memory bounded.
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} when type != :regular ->
        # Watcher fires on directory creation too (e.g. workspace/.glorbo-run/
        # scaffolding). Reindex is a markdown indexer — anything that isn't
        # a regular file is a no-op, not a crash.
        {:skip, {:not_regular_file, type}}

      {:ok, %File.Stat{size: size}} when size > @max_file_bytes ->
        {:skip, :too_large}

      {:ok, _stat} ->
        content = File.read!(path)
        digest = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

        case Repo.get(ReindexState, path) do
          %ReindexState{md5: ^digest} ->
            :unchanged

          _ ->
            case Frontmatter.parse(content) do
              {:ok, meta, _body} ->
                upsert_domain_row(path, meta)
                upsert_reindex_state(path, digest)
                :indexed

              {:error, reason} ->
                {:skip, reason}
            end
        end

      {:error, reason} ->
        {:skip, {:stat_failed, reason}}
    end
  end

  defp upsert_reindex_state(path, digest) do
    stat = File.stat!(path, time: :universal)

    mtime =
      case stat.mtime do
        {{_, _, _}, {_, _, _}} = erl -> NaiveDateTime.from_erl!(erl)
        _ -> NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      end

    Repo.insert!(
      %ReindexState{
        file_path: path,
        md5: digest,
        size: stat.size,
        mtime: mtime
      },
      on_conflict: {:replace, [:md5, :size, :mtime, :updated_at]},
      conflict_target: :file_path
    )
  end

  defp upsert_domain_row(path, meta) do
    cond do
      String.ends_with?(path, "/company.md") ->
        upsert_company(path, meta)

      Regex.match?(~r{/agents/[^/]+/(?:AGENT|agent)\.md$}, path) ->
        upsert_agent(path, meta)

      true ->
        :ok
    end
  end

  defp upsert_company(path, meta) do
    name = meta["name"] || infer_company_name(path)
    mission = meta["mission"]

    Repo.insert!(
      %Company{name: name, mission: mission, file_path: path},
      on_conflict: {:replace, [:name, :mission, :updated_at]},
      conflict_target: :file_path
    )
  end

  defp upsert_agent(path, meta) do
    name = meta["name"] || infer_agent_name(path)
    role = meta["role"]
    provider = meta["provider"]
    model = meta["model"]
    company_name = infer_company_name_from_agent_path(path)
    company_id = Repo.get_by(Company, name: company_name) |> maybe_id()

    Repo.insert!(
      %Agent{
        name: name,
        role: role,
        provider: provider,
        model: model,
        file_path: path,
        company_id: company_id
      },
      on_conflict: {:replace, [:name, :role, :provider, :model, :company_id, :updated_at]},
      conflict_target: :file_path
    )
  end

  defp maybe_id(nil), do: nil
  defp maybe_id(%{id: id}), do: id

  # Given .../companies/<co>/company.md → "<co>"
  defp infer_company_name(path) do
    path |> Path.split() |> Enum.reverse() |> Enum.at(1)
  end

  # Given .../companies/<co>/agents/<name>/agent.md → "<name>"
  defp infer_agent_name(path) do
    path |> Path.split() |> Enum.reverse() |> Enum.at(1)
  end

  # Given .../companies/<co>/agents/<name>/agent.md → "<co>"
  defp infer_company_name_from_agent_path(path) do
    segments = Path.split(path)

    case Enum.reverse(segments) do
      [_agent_md, _agent_name, "agents", co | _] -> co
      _ -> nil
    end
  end

  defp cleanup_vanished(seen_files) do
    seen = MapSet.new(seen_files)

    # Stream file_paths from the ReindexState table so we don't hold
    # every row in memory for databases with millions of entries. Must
    # run inside a transaction (Ecto requirement for Repo.stream/2).
    # (TODO.md Important #10)
    {:ok, vanished} =
      Repo.transaction(fn ->
        Repo.stream(from(r in ReindexState, select: r.file_path))
        |> Stream.reject(&MapSet.member?(seen, &1))
        |> Enum.to_list()
      end)

    # WR-03: batch the three deletes with a single `where ... in ^list` each
    # instead of 3N queries. Company's `on_delete: :delete_all` FK means the
    # Agent delete is redundant when company.md itself vanished, but issuing
    # it for stray agent.md vanishings is still correct and cheap.
    if vanished != [] do
      Repo.delete_all(from r in ReindexState, where: r.file_path in ^vanished)
      Repo.delete_all(from c in Company, where: c.file_path in ^vanished)
      Repo.delete_all(from a in Agent, where: a.file_path in ^vanished)
    end

    length(vanished)
  end
end
