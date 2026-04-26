defmodule Glorbo.Filesystem.Reindex do
  @moduledoc """
  MD5-incremental reindex engine (D-26, D-27).

  Walks `companies/` under the given base, MD5-hashes every `.md` file,
  compares against `reindex_state`, and upserts the `companies` / `agents`
  domain rows when frontmatter changed. Deletes state rows for files that
  vanished from disk. GEP-32 phase 3 also rebuilds the derived
  `provider_models` table from `cache/providers/*.json`.

  GEP-34 / wave-29: `audit_events` IS rebuilt from disk now —
  `companies/<co>/audit/YYYY-MM.jsonl` is streamed line-by-line into
  the SQLite mirror so `glorbo reindex` produces a fully-derivable
  `audit_events` table. JSONL remains the source of truth; SQLite is
  re-derived from it. `_system` events at `<base>/audit/*.jsonl` are
  imported under company `"_system"`.

  GEP-34 Phase 2: `tasks_approval_state` is rebuilt by folding the
  per-company `approval.requested` / `approval.granted` /
  `approval.denied` audit lines chronologically per `task_path`. The
  final fold-state per task is bulk-inserted; awaiting-but-never-
  resolved tasks land as `status: "awaiting"`, resolved tasks land as
  `approved` / `denied` with the original `requested_at` and the
  resolution timestamp. Audit JSONL is the only source — the
  resolved-approval sentinel files written by the gate are deleted
  post-resolution and never consulted here.

  GEP-34 Phase 3: `budgets` is rebuilt by summing `budget.usage`
  audit lines per `{company, agent, year_month}` (year_month is
  derived from each line's `ts` via `Budget.Ledger.month_bucket/1`,
  matching the writer). The `alerts_fired` MapSet that
  `Company.BudgetTracker` carries in GenServer state is NOT in the
  `budgets` schema and stays untouched — it rehydrates on tracker
  startup by scanning `alerts/*.md` (per its moduledoc), so
  reindex doesn't need to reconstruct it.

  GEP-34 is fully Implemented as of Phase 3.

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

  alias Glorbo.{Agent, AuditEvent, Budget, Company, Repo, TasksApprovalState}
  alias Glorbo.Budget.Ledger
  alias Glorbo.Filesystem.{AgentWritableFile, Frontmatter, ReindexState}
  alias Glorbo.Providers.ModelCatalog

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
    :ok = ModelCatalog.rebuild_projection_from_cache(Path.dirname(companies_dir))
    audit_imported = rebuild_audit_events(companies_dir)
    approvals_imported = rebuild_tasks_approval_state(companies_dir)
    budgets_imported = rebuild_budgets(companies_dir)

    {:ok,
     %{
       indexed: indexed,
       skipped: skipped,
       deleted: deleted,
       audit_events: audit_imported,
       tasks_approval_state: approvals_imported,
       budgets: budgets_imported
     }}
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

  # Collect *.md under companies_dir; reject any path whose lexical
  # ancestor escape or whose ancestor chain contains a symlink (T-2-03
  # symlink-escape defence). The lexical check alone was bypassable
  # via a symlinked directory under `companies/<co>/` that points at
  # `/etc`: Path.expand/1 doesn't follow symlinks, so the escape was
  # invisible. Codex + opencode round-3 flagged.
  defp safe_markdown_files(companies_dir) do
    companies_abs = Path.expand(companies_dir)

    companies_dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      expanded = Path.expand(path)

      cond do
        not (String.starts_with?(expanded, companies_abs <> "/") or expanded == companies_abs) ->
          Logger.warning("reindex rejected path (lexical escape of companies_dir): #{path}")
          false

        Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(expanded) ->
          Logger.warning("reindex rejected path (symlinked ancestor segment): #{path}")
          false

        true ->
          true
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
    # Resolve the parent company row by path, NOT by frontmatter `name:`.
    # A prior version looked up `Repo.get_by(Company, name: <slug>)`
    # which cross-wired two companies whenever their `name:` frontmatter
    # matched, and broke after a `name:` rename. The on-disk directory
    # slug IS the company identity (filesystem-as-source-of-truth);
    # derive the company row's file_path from it and look up there.
    company_id = company_id_from_agent_path(path)

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

  # .../companies/<co>/agents/<slug>/AGENT.md → .../companies/<co>/company.md
  defp company_id_from_agent_path(path) do
    company_dir = path |> Path.dirname() |> Path.dirname() |> Path.dirname()
    company_md = Path.join(company_dir, "company.md")
    Repo.get_by(Company, file_path: company_md) |> maybe_id()
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
    #
    # Chunking: SQLite defaults to ~999 bind parameters per query (bump'd
    # to 32k in newer builds but we don't get to assume that). A reindex
    # that vanishes >999 paths at once would fail the query. 500 is safely
    # below every supported SQLite.
    if vanished != [] do
      Enum.chunk_every(vanished, 500)
      |> Enum.each(fn chunk ->
        Repo.delete_all(from r in ReindexState, where: r.file_path in ^chunk)
        Repo.delete_all(from c in Company, where: c.file_path in ^chunk)
        Repo.delete_all(from a in Agent, where: a.file_path in ^chunk)
      end)
    end

    length(vanished)
  end

  # ---------------------------------------------------------------------------
  # GEP-34 / wave-29: audit_events rebuild from JSONL
  # ---------------------------------------------------------------------------

  # Cap each line at this many bytes — JSON-Lines entries beyond this are
  # almost certainly corrupted (the AuditLog writer doesn't emit lines this
  # large) and slurping them into the SQLite `detail` column wastes disk.
  @max_audit_line_bytes 64 * 1024

  # Wave 29 (defense-in-depth, post-v0.12.0): audit-dir walks in all three
  # rebuild paths must refuse symlinked ancestors before iterating. The
  # kernel sandbox already prevents agents from creating these symlinks,
  # but mirroring the `safe_markdown_files/1` discipline at the
  # application layer keeps the two enforcement points in sync — the
  # CLAUDE.md "kernel is policy, application also enforces" invariant.
  defp safe_audit_dir(path) do
    cond do
      not File.dir?(path) ->
        nil

      AgentWritableFile.any_symlink_in_path?(path) ->
        Logger.warning("reindex rejected audit dir (symlinked ancestor segment): #{path}")
        nil

      true ->
        path
    end
  end

  # Wipe the table once, then stream every JSONL file under
  # `companies/<co>/audit/` and `<base>/audit/_system/` (system events) back
  # into the mirror. Returns the count of imported rows. The system path
  # mirrors `Glorbo.Company.AuditLog.jsonl_path/3` — system events live in a
  # `_system/` subdirectory, NOT directly under `<base>/audit/`.
  defp rebuild_audit_events(companies_dir) do
    base = Path.dirname(companies_dir)
    Repo.delete_all(AuditEvent)

    company_count =
      case File.ls(companies_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&File.dir?(Path.join(companies_dir, &1)))
          |> Enum.flat_map(fn co ->
            case safe_audit_dir(Path.join([companies_dir, co, "audit"])) do
              nil -> []
              audit_dir -> [{co, audit_dir}]
            end
          end)
          |> Enum.reduce(0, fn {co, audit_dir}, acc -> acc + import_audit_dir(co, audit_dir) end)

        _ ->
          0
      end

    system_count =
      case safe_audit_dir(Path.join([base, "audit", "_system"])) do
        nil -> 0
        dir -> import_audit_dir("_system", dir)
      end

    company_count + system_count
  end

  defp import_audit_dir(company, audit_dir) do
    case File.ls(audit_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.reduce(0, fn fname, acc ->
          path = Path.join(audit_dir, fname)
          acc + import_audit_file(company, path)
        end)

      _ ->
        0
    end
  end

  defp import_audit_file(company, path) do
    # `:line` stream is byte-bounded by the underlying file driver, but we
    # still cap each decoded line so a single 100MB JSON blob can't OOM the
    # BEAM. Lines that fail to decode or exceed the cap are skipped with a
    # warning; reindex never crashes on a malformed audit entry.
    rows =
      path
      |> File.stream!([], :line)
      |> Stream.chunk_every(500)
      |> Enum.reduce(0, fn lines, acc ->
        decoded =
          lines
          |> Enum.flat_map(&decode_audit_line(&1, company, path))

        if decoded != [] do
          Repo.insert_all(AuditEvent, decoded)
        end

        acc + length(decoded)
      end)

    rows
  rescue
    e ->
      Logger.warning(
        "audit reindex skipped #{path}: #{Exception.message(e)} (JSONL stays authoritative)"
      )

      0
  end

  defp decode_audit_line(line, company, path) do
    line = String.trim_trailing(line, "\n")

    cond do
      line == "" ->
        []

      byte_size(line) > @max_audit_line_bytes ->
        Logger.warning("audit reindex skipped oversized line in #{path} (> 64KiB)")
        []

      true ->
        case Jason.decode(line) do
          {:ok, %{} = entry} -> build_audit_row(entry, company)
          _ -> []
        end
    end
  end

  defp build_audit_row(entry, fallback_company) do
    actor = Map.get(entry, "actor")
    action = Map.get(entry, "action")
    ts = parse_audit_ts(Map.get(entry, "ts"))

    if is_binary(actor) and is_binary(action) and ts != nil do
      detail = Map.drop(entry, ["ts", "company", "actor", "action", "target"])

      [
        %{
          company: stringify_or(Map.get(entry, "company"), fallback_company),
          actor: actor,
          action: action,
          target: stringify_or(Map.get(entry, "target"), nil),
          detail: Jason.encode!(detail),
          ts: ts
        }
      ]
    else
      []
    end
  end

  defp stringify_or(nil, fallback), do: fallback
  defp stringify_or(v, _) when is_binary(v), do: v
  defp stringify_or(v, _), do: to_string(v)

  defp parse_audit_ts(nil), do: nil

  defp parse_audit_ts(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_audit_ts(_), do: nil

  # ---------------------------------------------------------------------------
  # GEP-34 Phase 2: tasks_approval_state rebuild from JSONL
  # ---------------------------------------------------------------------------

  @approval_actions ~w(approval.requested approval.granted approval.denied)

  # Wipe-and-rebuild via chronological audit replay. Per-company only —
  # `_system` audit never carries approval events (the gate runs per-company).
  # Returns the count of inserted rows.
  defp rebuild_tasks_approval_state(companies_dir) do
    Repo.delete_all(TasksApprovalState)

    states =
      case File.ls(companies_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&File.dir?(Path.join(companies_dir, &1)))
          |> Enum.reduce(%{}, fn co, acc ->
            case safe_audit_dir(Path.join([companies_dir, co, "audit"])) do
              nil -> acc
              audit_dir -> fold_approval_dir(audit_dir, acc)
            end
          end)

        _ ->
          %{}
      end

    insert_approval_rows(states)
  end

  defp fold_approval_dir(audit_dir, acc) do
    case File.ls(audit_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        # YYYY-MM.jsonl filenames sort chronologically; lines within a file
        # are append-order. Together this gives a global chronological fold.
        |> Enum.sort()
        |> Enum.reduce(acc, fn fname, a ->
          fold_approval_file(Path.join(audit_dir, fname), a)
        end)

      _ ->
        acc
    end
  end

  defp fold_approval_file(path, acc) do
    path
    |> File.stream!([], :line)
    |> Enum.reduce(acc, &fold_approval_line(&1, path, &2))
  rescue
    e ->
      Logger.warning(
        "approval reindex skipped #{path}: #{Exception.message(e)} (JSONL stays authoritative)"
      )

      acc
  end

  defp fold_approval_line(line, path, acc) do
    line = String.trim_trailing(line, "\n")

    cond do
      line == "" ->
        acc

      byte_size(line) > @max_audit_line_bytes ->
        Logger.warning("approval reindex skipped oversized line in #{path} (> 64KiB)")
        acc

      true ->
        case Jason.decode(line) do
          {:ok, %{"action" => action} = entry} when action in @approval_actions ->
            apply_approval_event(action, entry, acc)

          _ ->
            acc
        end
    end
  end

  defp apply_approval_event("approval.requested", entry, acc) do
    task_path = entry["target"]
    agent = entry["agent"] || entry["actor"]
    ts = parse_audit_ts(entry["ts"])

    if is_binary(task_path) and is_binary(agent) and ts != nil do
      Map.put(acc, task_path, %{
        task_path: task_path,
        agent_slug: agent,
        status: "awaiting",
        requested_at: ts,
        resolved_at: nil,
        reason: nil
      })
    else
      acc
    end
  end

  defp apply_approval_event("approval.granted", entry, acc) do
    update_resolution(entry, acc, "approved", entry["approved_at"], nil)
  end

  defp apply_approval_event("approval.denied", entry, acc) do
    update_resolution(entry, acc, "denied", entry["denied_at"], entry["denial_reason"])
  end

  # Fold a resolution event over the existing fold-state. If we never saw the
  # matching `approval.requested` (audit log truncated, retention policy, etc.)
  # we synthesize a row from the resolution event so the table still reflects
  # what's known. The resolution timestamp prefers the action-specific field
  # (`approved_at`/`denied_at`) and falls back to the entry-level `ts`.
  defp update_resolution(entry, acc, status, resolution_ts_field, reason) do
    task_path = entry["target"]
    ts = parse_audit_ts(resolution_ts_field) || parse_audit_ts(entry["ts"])

    if is_binary(task_path) and ts != nil do
      reason_str = if is_binary(reason), do: reason, else: nil

      case Map.get(acc, task_path) do
        nil ->
          agent = entry["agent"]

          if is_binary(agent) do
            Map.put(acc, task_path, %{
              task_path: task_path,
              agent_slug: agent,
              status: status,
              requested_at: ts,
              resolved_at: ts,
              reason: reason_str
            })
          else
            acc
          end

        existing ->
          Map.put(acc, task_path, %{
            existing
            | status: status,
              resolved_at: ts,
              reason: reason_str
          })
      end
    else
      acc
    end
  end

  defp insert_approval_rows(states) when map_size(states) == 0, do: 0

  defp insert_approval_rows(states) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      states
      |> Map.values()
      |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))

    rows
    # SQLite ~999 bind parameters per query; 7 columns × 142 rows = ~994.
    # Chunk at 100 to stay comfortably under every supported SQLite.
    |> Enum.chunk_every(100)
    |> Enum.reduce(0, fn chunk, acc ->
      {n, _} = Repo.insert_all(TasksApprovalState, chunk)
      acc + n
    end)
  end

  # ---------------------------------------------------------------------------
  # GEP-34 Phase 3: budgets rebuild from JSONL
  # ---------------------------------------------------------------------------

  # Wipe-and-rebuild via per-company audit replay. Sums `budget.usage` lines
  # into `{company, agent, year_month}` aggregates (year_month derived from
  # each line's `ts`, matching the writer's `month_bucket`). `alerts_fired`
  # bitmap is GenServer-only state — rehydrated by tracker boot from
  # `alerts/*.md`, not in this schema. Returns the count of inserted rows.
  defp rebuild_budgets(companies_dir) do
    Repo.delete_all(Budget)

    sums =
      case File.ls(companies_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&File.dir?(Path.join(companies_dir, &1)))
          |> Enum.reduce(%{}, fn co, acc ->
            case safe_audit_dir(Path.join([companies_dir, co, "audit"])) do
              nil -> acc
              audit_dir -> sum_budget_dir(co, audit_dir, acc)
            end
          end)

        _ ->
          %{}
      end

    insert_budget_rows(sums)
  end

  defp sum_budget_dir(company, audit_dir, acc) do
    case File.ls(audit_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.reduce(acc, fn fname, a ->
          sum_budget_file(company, Path.join(audit_dir, fname), a)
        end)

      _ ->
        acc
    end
  end

  defp sum_budget_file(company, path, acc) do
    path
    |> File.stream!([], :line)
    |> Enum.reduce(acc, &sum_budget_line(&1, company, path, &2))
  rescue
    e ->
      Logger.warning(
        "budget reindex skipped #{path}: #{Exception.message(e)} (JSONL stays authoritative)"
      )

      acc
  end

  defp sum_budget_line(line, company, path, acc) do
    line = String.trim_trailing(line, "\n")

    cond do
      line == "" ->
        acc

      byte_size(line) > @max_audit_line_bytes ->
        Logger.warning("budget reindex skipped oversized line in #{path} (> 64KiB)")
        acc

      true ->
        case Jason.decode(line) do
          {:ok, %{"action" => "budget.usage"} = entry} ->
            apply_budget_usage(entry, company, acc)

          _ ->
            acc
        end
    end
  end

  defp apply_budget_usage(entry, fallback_company, acc) do
    co = stringify_or(Map.get(entry, "company"), fallback_company)
    agent = entry["agent"] || entry["actor"]
    ts = parse_audit_ts(entry["ts"])
    prompt = non_neg_int(entry["prompt_tokens"])
    completion = non_neg_int(entry["completion_tokens"])
    cost = non_neg_int(entry["cost_usd_cents"])

    if is_binary(co) and is_binary(agent) and ts != nil do
      year_month = Ledger.month_bucket(ts)
      key = {co, agent, year_month}

      Map.update(
        acc,
        key,
        %{prompt_tokens: prompt, completion_tokens: completion, cost_usd_cents: cost},
        fn existing ->
          %{
            prompt_tokens: existing.prompt_tokens + prompt,
            completion_tokens: existing.completion_tokens + completion,
            cost_usd_cents: existing.cost_usd_cents + cost
          }
        end
      )
    else
      acc
    end
  end

  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_), do: 0

  defp insert_budget_rows(sums) when map_size(sums) == 0, do: 0

  defp insert_budget_rows(sums) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(sums, fn {{co, agent, ym}, totals} ->
        %{
          company_slug: co,
          agent_slug: agent,
          year_month: ym,
          prompt_tokens: totals.prompt_tokens,
          completion_tokens: totals.completion_tokens,
          cost_usd_cents: totals.cost_usd_cents,
          inserted_at: now,
          updated_at: now
        }
      end)

    rows
    # 8 cols × 100 rows = 800 binds, well under SQLite's 999 ceiling.
    |> Enum.chunk_every(100)
    |> Enum.reduce(0, fn chunk, acc ->
      {n, _} = Repo.insert_all(Budget, chunk)
      acc + n
    end)
  end
end
