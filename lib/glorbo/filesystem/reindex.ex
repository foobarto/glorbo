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

  @doc """
  Run a full reindex pass.

  Options:
    * `:base` — base directory (default: `~/.glorbo`).
  """
  @spec run(keyword()) :: {:ok, result()}
  def run(opts \\ []) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    companies_dir = Path.join(base, "companies")

    if File.dir?(companies_dir) do
      do_run(companies_dir)
    else
      {:ok, %{indexed: 0, skipped: 0, deleted: 0}}
    end
  end

  defp do_run(companies_dir) do
    files = safe_markdown_files(companies_dir)

    # Sort so `company.md` files are processed BEFORE their nested
    # `agents/<n>/agent.md` children. This guarantees the Company row
    # exists when the Agent row tries to resolve `company_id`. Secondary
    # key is the full path for stable ordering.
    ordered = Enum.sort_by(files, &{path_kind(&1), &1})

    {indexed, skipped} = Enum.reduce(ordered, {0, 0}, &accumulate_result/2)
    deleted = cleanup_vanished(files)

    {:ok, %{indexed: indexed, skipped: skipped, deleted: deleted}}
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

  # Ordering key: 0 = company.md (parent), 1 = agent.md (child), 2 = other.
  # Ensures parents are inserted before children so company_id resolves.
  defp path_kind(path) do
    cond do
      String.ends_with?(path, "/company.md") -> 0
      Regex.match?(~r{/agents/[^/]+/agent\.md$}, path) -> 1
      true -> 2
    end
  end

  # B4 CONTRACT: process_file/1 is PRIVATE. Plan 04 will wrap it via a
  # public process_path/2 — do NOT promote this to `def`.
  defp process_file(path) do
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

      Regex.match?(~r{/agents/[^/]+/agent\.md$}, path) ->
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
      on_conflict:
        {:replace, [:name, :role, :provider, :model, :company_id, :updated_at]},
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

    vanished =
      Repo.all(from r in ReindexState, select: r.file_path)
      |> Enum.reject(&MapSet.member?(seen, &1))

    Enum.each(vanished, fn fp ->
      Repo.delete_all(from r in ReindexState, where: r.file_path == ^fp)
      cleanup_domain_row(fp)
    end)

    length(vanished)
  end

  defp cleanup_domain_row(file_path) do
    Repo.delete_all(from c in Company, where: c.file_path == ^file_path)
    Repo.delete_all(from a in Agent, where: a.file_path == ^file_path)
  end
end
