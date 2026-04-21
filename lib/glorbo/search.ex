defmodule Glorbo.Search do
  @moduledoc """
  Content search across a company's filesystem for the Ctrl+K palette
  (#232 T2-B, extended #249).

  Sources (both scanned; results merged + ranked together):

    * **Task titles + IDs** under `projects/*/tasks/*.md`. ETS-cached
      by (path, mtime).
    * **Audit rows** from the current month's
      `audit/YYYY-MM.jsonl` — matches on `actor`, `action`, and
      `target` fields.

  Each result carries a `kind` (`"task"` | `"audit"`), a human-
  readable `label`, and an `href` the caller can navigate to.

  O(n) over task files + audit entries, synchronous. Single-
  director scale is fine; for bigger workloads a proper SQLite FTS
  index lives behind this module's `search/4`.
  """

  @type result :: %{
          kind: String.t(),
          label: String.t(),
          href: String.t(),
          score: integer()
        }

  @doc """
  Search `query` inside company `co` rooted at `base`. Returns up
  to `limit` results ranked by a simple heuristic (title prefix
  match > substring > id match). Empty `query` returns [].
  """
  @spec search(Path.t(), String.t(), String.t(), keyword()) :: [result()]
  def search(base, co, query, opts \\ [])

  def search(_base, _co, "", _opts), do: []
  def search(_base, _co, nil, _opts), do: []

  def search(base, co, query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    normalised = String.downcase(String.trim(query))

    if normalised == "" do
      []
    else
      task_hits =
        base
        |> scan_tasks(co)
        |> Enum.flat_map(&score_task(&1, normalised, co))

      audit_hits =
        base
        |> scan_audit(co)
        |> Enum.flat_map(&score_audit(&1, normalised, co))

      (task_hits ++ audit_hits)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp scan_tasks(base, co) do
    projects_dir = Path.join([base, "companies", co, "projects"])

    case File.ls(projects_dir) do
      {:ok, projects} ->
        Enum.flat_map(projects, fn project ->
          tasks_dir = Path.join([projects_dir, project, "tasks"])

          case File.ls(tasks_dir) do
            {:ok, files} ->
              files
              |> Enum.filter(&String.ends_with?(&1, ".md"))
              |> Enum.flat_map(&read_task(tasks_dir, &1))

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  # ETS cache table name. Public + named so any process can read/write
  # without passing a reference. Created lazily in `ensure_cache/0`.
  @cache_table :glorbo_search_title_cache

  defp read_task(tasks_dir, filename) do
    path = Path.join(tasks_dir, filename)
    task_id = Path.basename(filename, ".md")

    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        title = cached_or_parse_title(path, task_id, mtime)
        [%{task_id: task_id, title: title, path: path}]

      _ ->
        []
    end
  end

  # `mtime` from File.Stat is a `{:erlang.datetime}` tuple (seconds
  # precision). Use it + path as the cache key so a modified task
  # re-parses on the next scan; an unchanged task serves from ETS.
  defp cached_or_parse_title(path, task_id, mtime) do
    ensure_cache()

    case :ets.lookup(@cache_table, path) do
      [{^path, ^mtime, title}] ->
        title

      _ ->
        title = parse_title(path, task_id)
        :ets.insert(@cache_table, {path, mtime, title})
        title
    end
  end

  defp parse_title(path, task_id) do
    case File.read(path) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, fm, _body} -> to_string(fm["title"] || task_id)
          _ -> task_id
        end

      _ ->
        task_id
    end
  end

  defp ensure_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Audit source (#249)
  # ---------------------------------------------------------------------------

  # Scan the last @audit_scan_depth rows from this month's audit
  # JSONL. Reading the whole month file on every keystroke would
  # be wasteful; the tail is overwhelmingly where directors care
  # about recent activity. Fallback to empty list on any IO /
  # decode error — search MUST remain silent on missing data.
  @audit_scan_depth 500

  defp scan_audit(base, co) do
    month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
    path = Path.join([base, "companies", co, "audit", "#{month}.jsonl"])

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.take(@audit_scan_depth)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{} = entry} -> [entry]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  # Score audit entries against the query. Actor and action matches
  # rank higher than target matches (the director usually searches
  # for "what did <agent> do" or "where did <action> happen").
  defp score_audit(entry, query, co) do
    actor = to_string(entry["actor"] || "")
    action = to_string(entry["action"] || "")
    target = to_string(entry["target"] || "")

    score =
      cond do
        String.contains?(String.downcase(actor), query) -> 70
        String.contains?(String.downcase(action), query) -> 65
        String.contains?(String.downcase(target), query) -> 55
        true -> 0
      end

    if score == 0 do
      []
    else
      [
        %{
          kind: "audit",
          label: "#{actor} #{action} — #{short_target(target)}",
          href: "/companies/#{co}/audit",
          score: score
        }
      ]
    end
  end

  defp short_target(""), do: ""
  defp short_target(target) when byte_size(target) <= 40, do: target
  defp short_target(target), do: String.slice(target, -40, 40)

  # ---------------------------------------------------------------------------
  # Task source
  # ---------------------------------------------------------------------------

  # Score each candidate against the query. Higher score = better
  # match. Results with score 0 are dropped.
  defp score_task(%{task_id: id, title: title}, query, co) do
    lid = String.downcase(id)
    ltitle = String.downcase(title)

    score =
      cond do
        String.starts_with?(ltitle, query) -> 100
        String.starts_with?(lid, query) -> 90
        String.contains?(ltitle, query) -> 50
        String.contains?(lid, query) -> 40
        true -> 0
      end

    if score == 0 do
      []
    else
      [
        %{
          kind: "task",
          label: "#{id} · #{title}",
          href: "/companies/#{co}/tasks/#{id}",
          score: score
        }
      ]
    end
  end
end
