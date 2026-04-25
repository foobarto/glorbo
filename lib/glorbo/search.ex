defmodule Glorbo.Search do
  @moduledoc """
  Content search across a company's filesystem for the Ctrl+K palette
  (#232 T2-B, extended #249).

  Sources (both scanned; results merged + ranked together):

    * **Task titles + IDs + schedule tags** under
      `projects/*/tasks/*.md`. ETS-cached by (path, mtime). The
      task's `schedule:` frontmatter value (e.g. `every day`,
      `daily`, `0 9 * * 1-5`) is searchable as a substring, so a
      query like `daily` surfaces every daily-scheduled task
      without having to hunt through audit.
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
  @cache_cap 1_000
  @title_max_bytes 512
  @truncated_suffix "... [truncated]"

  defp read_task(tasks_dir, filename) do
    path = Path.join(tasks_dir, filename)
    task_id = Path.basename(filename, ".md")

    # Threatmodel: agents have RW on their own task files. Use lstat
    # rather than stat so a planted symlink doesn't pull cross-
    # company task content into Ctrl+K search results, and refuse
    # oversized files (a 1 GB task body would block the indexer).
    # Threatmodel: agents have RW on their own task files. Use lstat
    # rather than stat so a planted symlink doesn't pull cross-
    # company task content into Ctrl+K search results, and refuse
    # oversized files (a 1 GB task body would block the indexer).
    # The `file_info` record element layout is:
    #   {:file_info, size, type, access, atime, mtime, ctime, mode, ...}
    case :file.read_link_info(path) do
      {:ok, info}
      when elem(info, 2) == :regular and elem(info, 1) <= 1_048_576 ->
        mtime = elem(info, 5)
        {title, schedule} = cached_or_parse_fields(path, task_id, mtime)
        [%{task_id: task_id, title: title, schedule: schedule, path: path}]

      _ ->
        []
    end
  end

  # `mtime` from File.Stat is a `{:erlang.datetime}` tuple (seconds
  # precision). Use it + path as the cache key so a modified task
  # re-parses on the next scan; an unchanged task serves from ETS.
  #
  # The cache tuple is `{path, mtime, {title, schedule}}`. The
  # schedule string is kept lowercase-normalised ready for
  # substring scoring — parsing is expensive enough that we want
  # both fields memoised together.
  defp cached_or_parse_fields(path, task_id, mtime) do
    ensure_cache()

    case :ets.lookup(@cache_table, path) do
      [{^path, ^mtime, {title, schedule}}] ->
        {title, schedule}

      _ ->
        fields = parse_fields(path, task_id)
        maybe_cache_fields(path, mtime, fields)
        fields
    end
  end

  defp parse_fields(path, task_id) do
    case File.read(path) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, fm, _body} ->
            # Threatmodel wave 24: title / schedule may be agent-
            # authored YAML maps or lists; `to_string/1` on those
            # crashes Ctrl+K + /api/search. Coerce only scalars.
            title = truncate_title(safe_scalar(fm["title"], task_id))
            schedule = safe_scalar(fm["schedule"], "")
            {title, schedule}

          _ ->
            {truncate_title(task_id), ""}
        end

      _ ->
        {truncate_title(task_id), ""}
    end
  end

  defp maybe_cache_fields(path, mtime, fields) do
    if :ets.member(@cache_table, path) or cache_room?() do
      :ets.insert(@cache_table, {path, mtime, fields})
    end
  end

  defp cache_room? do
    case :ets.info(@cache_table, :size) do
      size when is_integer(size) -> size < @cache_cap
      _ -> false
    end
  end

  defp truncate_title(title) when byte_size(title) <= @title_max_bytes, do: title

  defp truncate_title(title) do
    keep = max(@title_max_bytes - byte_size(@truncated_suffix), 0)
    valid_utf8_prefix(title, keep) <> @truncated_suffix
  end

  defp valid_utf8_prefix(_title, max_bytes) when max_bytes <= 0, do: ""

  defp valid_utf8_prefix(title, max_bytes) do
    size = min(byte_size(title), max_bytes)
    prefix = :binary.part(title, 0, size)

    if String.valid?(prefix) do
      prefix
    else
      trim_invalid_utf8_suffix(prefix)
    end
  end

  defp trim_invalid_utf8_suffix(prefix) do
    size = byte_size(prefix)

    Enum.find_value(0..3, "", fn drop ->
      candidate = :binary.part(prefix, 0, max(size - drop, 0))
      if String.valid?(candidate), do: candidate
    end)
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

    # Wave 27: stream the JSONL with a rolling window of size
    # @audit_scan_depth — keeps memory bounded by the window
    # rather than the file size. Earlier `File.read + String.split
    # + Enum.reverse` slurped the whole month into BEAM memory on
    # every command-palette keystroke.
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        path
        |> File.stream!([], :line)
        |> Enum.reduce([], fn line, acc -> push_audit_line(line, acc) end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp push_audit_line(line, acc) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = entry} ->
        # Bounded LIFO: keep the most-recent N entries, dropping
        # oldest from the tail.
        if length(acc) >= @audit_scan_depth do
          [entry | Enum.take(acc, @audit_scan_depth - 1)]
        else
          [entry | acc]
        end

      _ ->
        acc
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
  #
  # The `schedule` field scores below id/title because the director
  # is usually looking for a specific task by name; schedule
  # matches are a useful fallback ("show me all daily tasks") but
  # shouldn't outrank a literal title match.
  defp score_task(%{task_id: id, title: title, schedule: schedule}, query, co) do
    lid = String.downcase(id)
    ltitle = String.downcase(title)
    lschedule = String.downcase(schedule)

    score =
      cond do
        String.starts_with?(ltitle, query) -> 100
        String.starts_with?(lid, query) -> 90
        String.contains?(ltitle, query) -> 50
        String.contains?(lid, query) -> 40
        lschedule != "" and String.contains?(lschedule, query) -> 35
        true -> 0
      end

    if score == 0 do
      []
    else
      [
        %{
          kind: "task",
          label: task_label(id, title, schedule),
          href: "/companies/#{co}/tasks/#{id}",
          score: score
        }
      ]
    end
  end

  # Schedule tag decorates the label when present, so the
  # director sees *why* a result surfaced on a `schedule:`-style
  # query without having to open the task.
  defp task_label(id, title, ""), do: "#{id} · #{title}"
  defp task_label(id, title, schedule), do: "#{id} · #{title} (#{schedule})"

  defp safe_scalar(v, _default) when is_binary(v), do: v
  defp safe_scalar(v, _default) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp safe_scalar(v, _default) when is_number(v), do: to_string(v)
  defp safe_scalar(_, default), do: default
end
