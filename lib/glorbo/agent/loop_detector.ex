defmodule Glorbo.Agent.LoopDetector do
  @moduledoc """
  Detects agent dispatch loops — N consecutive failures on the same
  task — and escalates them to the director via a sentinel file.

  Inspired by the MeisnerDan/mission-control pattern ("auto-detects
  agents stuck in failure loops; after 3 attempts, escalates to a
  user decision"). Fits Glorbo's filesystem-first invariant: no new
  in-memory state; detection reads the already-append-only audit
  JSONL, sentinel is just another markdown file under `state/`.

  ## Failure definition

  An `agent.complete` audit entry counts as a failure if EITHER:

    * `detail.exit_status` is not `"0"` / `0`, OR
    * `detail.exit_status` is `"0"` / `0` but `detail.reply_preview`
      is empty/nil (the model exited clean but produced nothing — a
      behaviour opencode shows when it hits tool-use refusals or
      model-side budget limits).

  ## Trigger

  `check/3` is meant to be called from `Agent.Dispatch` right after
  `emit_complete_audit/6`. It:

    1. Reads the current month's audit JSONL.
    2. Filters to this agent's `agent.complete` entries, newest-
       first, bounded to the last `@scan_limit`.
    3. Walks newest → oldest while `task_path` matches and all
       entries are failures. A non-failure break resets the chain.
    4. If the consecutive-failure chain length ≥ threshold, writes
       the stuck sentinel (idempotent — same filename, `:sync`
       write) and emits `agent.loop_detected` audit.

  ## Sentinel shape

  Path: `<base>/companies/<co>/agents/<slug>/state/stuck-on-<task-id>.md`

  Frontmatter:

      ---
      kind: loop_detected
      agent: <slug>
      task_id: <id>
      task_path: <path>
      failure_count: <n>
      first_failure_ts: <iso8601>
      last_failure_ts: <iso8601>
      ---
      Agent has failed <n> consecutive dispatches on this task.

  The director resolves by writing one of three siblings:

    * `resolved-retry-<task-id>.md` — clear sentinel, keep retrying
    * `resolved-skip-<task-id>.md`  — clear sentinel, reassign to director
    * `resolved-stop-<task-id>.md`  — clear sentinel, set task to `denied`

  (Resolution handlers live in InboxLive — this module only
  produces the sentinel; it does not read or act on resolutions.)

  ## Dependency injection

  `:fs_fun` replaces filesystem ops; `:audit_fun` replaces the
  audit log writer. Both are exposed so tests can verify behaviour
  without touching disk.
  """
  require Logger

  alias Glorbo.Company.AuditLog

  @default_threshold 3
  # Bound scanning to the last N entries to keep worst-case O(1) in
  # log size. Directors manually rotate audit files monthly (or the
  # month boundary does it); 500 is plenty for detection purposes.
  @scan_limit 500

  @type check_opts :: [
          base: Path.t(),
          threshold: pos_integer(),
          audit_reader: (Path.t(), String.t() -> [map()]),
          fs_fun: map(),
          audit_fun: (String.t(), map() -> any()),
          now_fun: (-> DateTime.t())
        ]

  @doc """
  Check if the given agent has a failure loop on any task, and if
  so, write the stuck sentinel + emit `agent.loop_detected`.

  Returns `{:stuck, task_path, count}` when a sentinel was written,
  `:ok` otherwise (no loop, or loop already flagged).
  """
  @spec check(String.t(), String.t(), check_opts()) ::
          {:stuck, String.t(), pos_integer()} | :ok
  def check(company, agent_slug, opts \\ [])
      when is_binary(company) and is_binary(agent_slug) and is_list(opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    now_fun = Keyword.get(opts, :now_fun, fn -> DateTime.utc_now() end)
    audit_reader = Keyword.get(opts, :audit_reader, &read_month_audit/2)
    fs_fun = Keyword.get(opts, :fs_fun, default_fs_fun())
    audit_fun = Keyword.get_lazy(opts, :audit_fun, fn -> default_audit_fun() end)

    ym = now_fun.() |> DateTime.to_date() |> to_year_month()

    entries =
      audit_reader.(base, company)
      |> filter_agent_complete(agent_slug)
      |> Enum.take(@scan_limit)

    case detect_loop(entries, threshold) do
      {:loop, task_path, chain} ->
        task_id = task_path |> Path.basename() |> Path.rootname()

        sentinel_path =
          Path.join([
            base,
            "companies",
            company,
            "agents",
            agent_slug,
            "state",
            "stuck-on-#{task_id}.md"
          ])

        if fs_fun.exists?.(sentinel_path) do
          # Already flagged — don't double-escalate. The director
          # hasn't resolved yet; the follow-up dispatch that
          # produced the Nth+1 failure is additional signal but
          # the inbox already shows it.
          :ok
        else
          write_sentinel(sentinel_path, agent_slug, task_id, task_path, chain, ym, fs_fun)
          emit_loop_audit(audit_fun, company, agent_slug, task_path, length(chain))
          {:stuck, task_path, length(chain)}
        end

      :no_loop ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "loop_detector: check failed for #{company}/#{agent_slug}: #{Exception.message(e)}"
      )

      :ok
  end

  @doc """
  Pure detector — given a newest-first list of parsed audit entries
  already filtered to one agent's `agent.complete` events, return
  either `:no_loop` or `{:loop, task_path, failure_chain}`.

  Exposed so tests can verify the chaining logic without disk IO.
  """
  @spec detect_loop([map()], pos_integer()) ::
          :no_loop | {:loop, String.t(), [map()]}
  def detect_loop(entries, threshold) when is_list(entries) and threshold >= 1 do
    case entries do
      [] ->
        :no_loop

      [head | _] = all ->
        task_path = head["target"] || get_in(head, ["detail", "task_path"]) || ""

        if task_path == "" do
          :no_loop
        else
          chain = take_failure_chain(all, task_path)

          if length(chain) >= threshold,
            do: {:loop, task_path, chain},
            else: :no_loop
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp filter_agent_complete(entries, agent_slug) do
    Enum.filter(entries, fn entry ->
      Map.get(entry, "action") == "agent.complete" and
        (Map.get(entry, "actor") == agent_slug or
           get_in(entry, ["detail", "agent"]) == agent_slug or
           Map.get(entry, "agent") == agent_slug)
    end)
  end

  # Walk newest → oldest while task_path matches AND entry is a
  # failure. First mismatch (different task, or successful completion)
  # ends the chain.
  defp take_failure_chain(entries, task_path) do
    Enum.reduce_while(entries, [], fn entry, acc ->
      entry_task = entry["target"] || get_in(entry, ["detail", "task_path"]) || ""

      cond do
        entry_task != task_path -> {:halt, acc}
        not failure?(entry) -> {:halt, acc}
        true -> {:cont, [entry | acc]}
      end
    end)
    # Reverse so the chain is oldest → newest — nicer for debugging
    # reports. Length is the same either way.
    |> Enum.reverse()
  end

  defp failure?(entry) do
    detail = Map.get(entry, "detail") || %{}
    exit_status = detail["exit_status"] || entry["exit_status"]
    reply_preview = detail["reply_preview"] || entry["reply_preview"]

    case exit_status do
      "0" -> blank?(reply_preview)
      0 -> blank?(reply_preview)
      nil -> blank?(reply_preview)
      _ -> true
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp read_month_audit(base, company) do
    now = DateTime.utc_now()
    ym = now |> DateTime.to_date() |> to_year_month()
    path = Path.join([base, "companies", company, "audit", "#{ym}.jsonl"])

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        # Newest-first so the chain walker can stop early.
        |> Enum.reverse()
        |> Enum.flat_map(&decode_line/1)

      _ ->
        []
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, map} -> [map]
      _ -> []
    end
  end

  defp to_year_month(%Date{year: y, month: m}) do
    :io_lib.format("~4..0B-~2..0B", [y, m]) |> IO.iodata_to_binary()
  end

  defp write_sentinel(path, agent_slug, task_id, task_path, chain, ym, fs_fun) do
    first = List.first(chain)
    last = List.last(chain)

    first_ts = (first && first["ts"]) || ""
    last_ts = (last && last["ts"]) || ""

    body = """
    ---
    kind: loop_detected
    agent: #{agent_slug}
    task_id: #{task_id}
    task_path: #{task_path}
    failure_count: #{length(chain)}
    first_failure_ts: #{first_ts}
    last_failure_ts: #{last_ts}
    audit_month: #{ym}
    ---
    Agent `@#{agent_slug}` has failed #{length(chain)} consecutive
    dispatches on task `#{task_id}` (`#{task_path}`).

    Director action required. Write one of:

    - `resolved-retry-#{task_id}.md` in this directory to keep retrying.
    - `resolved-skip-#{task_id}.md`  to reassign the task to the director.
    - `resolved-stop-#{task_id}.md`  to mark the task as `denied`.

    Reading this sentinel from InboxLive (`/companies/<co>/inbox`)
    shows three action buttons matching the above.
    """

    dir = Path.dirname(path)
    fs_fun.mkdir_p!.(dir)
    fs_fun.write!.(path, body)
    :ok
  end

  defp emit_loop_audit(audit_fun, company, agent_slug, task_path, count) do
    audit_fun.(company, %{
      action: "agent.loop_detected",
      actor: "system",
      agent: agent_slug,
      target: task_path,
      failure_count: count
    })

    :ok
  rescue
    _ -> :ok
  end

  defp default_fs_fun do
    %{
      mkdir_p!: &File.mkdir_p!/1,
      write!: &File.write!/2,
      exists?: &File.exists?/1
    }
  end

  defp default_audit_fun,
    do: fn company, entry ->
      AuditLog.append(Map.put(entry, :company, company))
    end
end
