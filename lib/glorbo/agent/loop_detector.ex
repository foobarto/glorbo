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
      kind: sentinel-stuck/v1
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
    kind: sentinel-stuck/v1
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

    Director action required. Two equivalent ways to resolve:

    * Click one of the three buttons in InboxLive
      (`/companies/<co>/inbox`) or on the task page.
    * Drop a file next to this sentinel in the same directory:
      - `resolved-retry-#{task_id}.md` → clear sentinel, keep retrying.
      - `resolved-skip-#{task_id}.md`  → reassign task to the director.
      - `resolved-stop-#{task_id}.md`  → mark task as `denied`.

    Both paths apply the same mutation and emit a single
    `agent.loop_resolved` audit entry. File-drop resolutions are
    picked up on the next InboxLive / TaskLive render; resolution
    files are deleted after being applied.
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

  # ---------------------------------------------------------------------------
  # Resolution API (R21)
  #
  # Unifies InboxLive + TaskLive button handlers with the file-drop
  # protocol documented in the sentinel body. One code path:
  #
  #   * Button click → writes resolved-<decision>-<task-id>.md next
  #     to the sentinel, then `apply_resolution/4` picks it up.
  #   * Agent or CLI drop → same resolved-*.md file; scan_resolutions
  #     picks it up on the next InboxLive mount or render.
  #   * Both flows emit exactly one `agent.loop_resolved` audit row.
  # ---------------------------------------------------------------------------

  @resolution_decisions ~w(retry skip stop)a

  @doc """
  Apply a resolution decision to a stuck sentinel.

  * Mutates the task (skip → reassign to director; stop → status
    denied; retry → no-op)
  * Deletes the sentinel
  * Emits `agent.loop_resolved` audit with `{actor, decision,
    agent, task_path, task_id}`

  Called from InboxLive/TaskLive button handlers and from
  `apply_resolution_files/3` when a resolved-*.md file is
  observed on disk.
  """
  @spec resolve(Path.t(), :retry | :skip | :stop, Path.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def resolve(abs_sentinel, decision, base, company, opts \\ [])
      when decision in @resolution_decisions do
    actor = Keyword.get(opts, :actor, "director")
    # Codex round-3 review of PR #35 d5ba9b5: the corroboration
    # check used the FRONTMATTER `agent` and `audit_month` to scope
    # the audit query — both are agent-controlled. Agent A under
    # `/agents/A/state/` could drop a sentinel with `agent: B,
    # audit_month: 2024-01` and inherit any legit B-corroboration
    # row from January. `apply_resolution_files/3` derives the real
    # agent from the state-dir PATH and now passes it as
    # `:path_agent`; here we enforce that the frontmatter agent
    # matches AND we use the path-derived value for the
    # corroboration query.
    path_agent = Keyword.get(opts, :path_agent)

    # Coerce a nil `:audit_fun` to the default: get_lazy only fires
    # when the key is ABSENT, and apply_one_resolution forwards the
    # key whether or not the caller provided one. Without this,
    # button-driven resolutions silently miss the audit row. (R23
    # UAT found this.)
    audit_fun =
      case Keyword.get(opts, :audit_fun) do
        nil -> default_audit_fun()
        fun when is_function(fun, 2) -> fun
      end

    with {:ok, content} <- File.read(abs_sentinel),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      task_path = to_string(fm["task_path"] || "")
      fm_agent_slug = to_string(fm["agent"] || "")
      task_id = to_string(fm["task_id"] || Path.basename(task_path, ".md"))

      # When `:path_agent` is provided (the agent-origin file-drop
      # path), it wins for the corroboration key; the frontmatter
      # value is only used to refuse a forged-agent sentinel via
      # `check_agent_binding/2`. Director-origin resolutions
      # (button-click via InboxLive/TaskLive) pass no `:path_agent`,
      # which is fine because corroboration is skipped for them.
      bound_agent_slug = path_agent || fm_agent_slug

      # threatmodel M02/M11: the sentinel file lives under
      # `agents/<slug>/state/` which is agent-writable. A malicious
      # agent can drop `task_path: ../../otherco/projects/…` and
      # have the director-initiated resolution write (via
      # apply_task_mutation) escape the company. Confine the path
      # to `projects/<slug>/tasks/<id>.md` within this company.
      #
      # Gemini round-3 finding (PR #35): even with `task_path`
      # confined to the company, the AGENT owns both the
      # `stuck-on-X.md` sentinel and the `resolved-*-X.md`
      # resolution file under its own `agents/<slug>/state/` dir.
      # A malicious agent can forge BOTH for any task in the
      # company (any project) and on the next `apply_resolution_files`
      # scan the director's InboxLive render will silently mutate
      # the task (`:stop` → `status: denied`; `:skip` → reassign
      # to director) — bypassing the `projects:write` ACL
      # entirely. Require a corroborating system-emitted
      # `agent.loop_detected` audit entry before honoring
      # agent-origin resolutions. The corroboration check is
      # skipped for the director-origin path (button click in
      # InboxLive/TaskLive) where the operator is authoritative.
      with :ok <- validate_sentinel_task_path(task_path),
           :ok <- check_agent_binding(path_agent, fm_agent_slug),
           :ok <-
             require_system_corroboration(
               actor,
               base,
               company,
               bound_agent_slug,
               task_path
             ),
           abs_task = Path.join([base, "companies", company, task_path]),
           :ok <- apply_task_mutation(decision, abs_task) do
        _ = File.rm(abs_sentinel)

        emit_resolved_audit(audit_fun, company, %{
          actor: actor,
          decision: to_string(decision),
          agent: bound_agent_slug,
          task_path: task_path,
          task_id: task_id
        })

        :ok
      end
    else
      err -> err
    end
  end

  @doc """
  Scan a company's agent state dirs for `resolved-<decision>-<task>.md`
  files. For each resolution file that has a matching
  `stuck-on-<task>.md` sibling, apply it and remove the resolution
  file. Actor defaults to `"agent:<slug>"` since director-origin
  resolutions pass through `resolve/5` directly.

  Returns `[{decision, task_id, result}]` for observability; the
  caller (InboxLive) ignores this and just re-reads the sentinel
  list afterwards.
  """
  @spec apply_resolution_files(Path.t(), String.t(), keyword()) ::
          [{atom(), String.t(), :ok | {:error, term()}}]
  def apply_resolution_files(base, company, opts \\ []) do
    co_dir = Path.join([base, "companies", company])

    co_dir
    |> Path.join("agents/*/state/resolved-*-*.md")
    |> Path.wildcard()
    |> Enum.map(&apply_one_resolution(&1, base, company, opts))
    |> Enum.reject(&is_nil/1)
  end

  defp apply_one_resolution(res_path, base, company, opts) do
    filename = Path.basename(res_path, ".md")

    with [_, decision, task_id] when decision in ["retry", "skip", "stop"] and task_id != "" <-
           Regex.run(~r/^resolved-(retry|skip|stop)-(.+)$/, filename),
         sentinel_path = Path.join(Path.dirname(res_path), "stuck-on-#{task_id}.md"),
         true <- File.exists?(sentinel_path) do
      agent_slug = agent_slug_from_state_path(res_path)
      actor = Keyword.get(opts, :actor, "agent:#{agent_slug}")

      decision_atom = String.to_existing_atom(decision)

      result =
        resolve(sentinel_path, decision_atom, base, company,
          actor: actor,
          audit_fun: Keyword.get(opts, :audit_fun),
          # Codex round-3 review of PR #35: bind the corroboration
          # query to the PATH-derived agent, not the
          # frontmatter-supplied one. Without this, agent A could
          # plant `agent: B` in its own state dir's sentinel and
          # inherit B's legit `agent.loop_detected` audit row.
          path_agent: agent_slug
        )

      _ = File.rm(res_path)
      {decision_atom, task_id, result}
    else
      _ ->
        # Orphan resolution file (no matching sentinel) — remove so
        # it doesn't accumulate. This happens if the director clicks
        # a button while an agent has already dropped a file.
        _ = File.rm(res_path)
        nil
    end
  end

  defp agent_slug_from_state_path(path) do
    path
    |> Path.split()
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value("unknown", fn
      ["agents", slug, "state"] -> slug
      _ -> false
    end)
  end

  # threatmodel M02/M11: sentinel files are agent-writable, so
  # task_path must be validated before we construct
  # `companies/<co>/<task_path>` or hand it to TaskDefinition.write.
  # Restrict to `projects/<slug>/tasks/<id>.md` — matches the only
  # shape legitimate agent telemetry can produce.
  @sentinel_task_path_re ~r{\Aprojects/[a-z0-9][a-z0-9-]*/tasks/[a-z0-9][a-z0-9._-]*\.md\z}
  defp validate_sentinel_task_path(path) when is_binary(path) do
    segments = Path.split(path)

    cond do
      path == "" -> {:error, :sentinel_empty_task_path}
      String.contains?(path, <<0>>) -> {:error, :sentinel_invalid_task_path}
      Path.type(path) != :relative -> {:error, :sentinel_invalid_task_path}
      ".." in segments -> {:error, :sentinel_invalid_task_path}
      not Regex.match?(@sentinel_task_path_re, path) -> {:error, :sentinel_invalid_task_path}
      true -> :ok
    end
  end

  defp validate_sentinel_task_path(_), do: {:error, :sentinel_invalid_task_path}

  # Skip corroboration entirely for director-origin resolutions:
  # the operator clicked a button (or a CLI tool acting on behalf
  # of the operator) and that is authoritative by design.
  defp require_system_corroboration("director", _base, _co, _slug, _task_path), do: :ok

  defp require_system_corroboration(_actor, _base, _co, _slug, ""),
    do: {:error, :sentinel_corroboration_missing_task_path}

  defp require_system_corroboration(_actor, _base, _co, "", _task_path),
    do: {:error, :sentinel_corroboration_missing_agent}

  # Window the system-emitted `agent.loop_detected` corroboration
  # must fall within. Codex round-3 review of PR #35 raised this:
  # without a freshness bound, agent A could replay any historical
  # legit `agent.loop_detected` row (from weeks/months ago) to
  # authorise a freshly-dropped resolution today. 24h is long
  # enough to cover monthly audit-file rotation gap + slow operator
  # reaction, and short enough to make replay attacks uninteresting.
  @corroboration_window_secs 24 * 3_600

  defp require_system_corroboration(actor, base, company, agent_slug, task_path) do
    # Codex round-3 review of PR #35 also closed the
    # frontmatter-driven `audit_month` opt: the agent could point
    # the corroboration scan at any historical month containing a
    # legit row. The corroboration query now scans the current UTC
    # month + the previous one (covers the month-boundary race
    # where detection landed in month N and resolution lands in
    # N+1) — no agent input is honored.
    now = DateTime.utc_now()
    threshold = DateTime.add(now, -@corroboration_window_secs, :second)

    months = corroboration_months(now)

    corroborated? =
      Enum.any?(months, fn month ->
        base
        |> Glorbo.Audit.Query.for_task(company, task_path, limit: 100, month: month)
        |> Enum.any?(&matches_system_loop?(&1, agent_slug, threshold))
      end)

    if corroborated? do
      :ok
    else
      Logger.warning(
        "loop_detector: refusing #{actor}-origin resolution for #{task_path} " <>
          "(agent=#{agent_slug}) — no corroborating system-emitted " <>
          "agent.loop_detected audit entry found within #{@corroboration_window_secs}s window"
      )

      {:error, :sentinel_not_corroborated}
    end
  end

  @doc false
  # Current + previous UTC month — covers the rotation boundary
  # where the system-emitted `agent.loop_detected` row landed in
  # month N and the resolution arrives in N+1.
  #
  # Codex P1 review on PR #35: the previous `DateTime.add(-32d)`
  # math lands in month N-2 when called from the FIRST day of
  # month N (e.g. March 1 minus 32d = January 28 → "01"), so the
  # immediately-previous month gets skipped at the boundary. Use
  # calendar arithmetic instead: roll the day to 1, then subtract
  # one day → guaranteed last day of the prior month.
  #
  # Public for the boundary-correctness regression test.
  def corroboration_months(%DateTime{} = now) do
    cur_date = DateTime.to_date(now)
    cur = to_year_month(cur_date)

    prev_date =
      cur_date
      |> Date.beginning_of_month()
      |> Date.add(-1)

    prev = to_year_month(prev_date)
    Enum.uniq([cur, prev])
  end

  defp matches_system_loop?(entry, agent_slug, threshold) do
    entry["action"] == "agent.loop_detected" and
      entry["actor"] == "system" and
      (entry["agent"] == agent_slug or
         get_in(entry, ["detail", "agent"]) == agent_slug) and
      within_corroboration_window?(entry["ts"], threshold)
  end

  defp within_corroboration_window?(ts, threshold) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.compare(dt, threshold) != :lt
      _ -> false
    end
  end

  defp within_corroboration_window?(_ts, _threshold), do: false

  # When the file-drop scan supplies the PATH-derived agent
  # (`:path_agent` opt), refuse if the frontmatter `agent` field
  # disagrees — it means the agent tried to assert ownership of a
  # different agent's sentinel from inside its own state dir.
  # Director-origin resolutions don't pass `:path_agent` and are
  # skipped.
  defp check_agent_binding(nil, _fm_agent), do: :ok
  defp check_agent_binding(path_agent, fm_agent) when path_agent == fm_agent, do: :ok

  defp check_agent_binding(_path_agent, _fm_agent),
    do: {:error, :sentinel_agent_mismatch}

  defp apply_task_mutation(:retry, _abs_task), do: :ok

  defp apply_task_mutation(:skip, abs_task),
    do: Glorbo.TaskDefinition.write(abs_task, %{assigned_to: "director"})

  defp apply_task_mutation(:stop, abs_task),
    do: Glorbo.TaskDefinition.write(abs_task, %{status: "denied"})

  defp emit_resolved_audit(audit_fun, company, detail) do
    audit_fun.(company, %{
      action: "agent.loop_resolved",
      actor: detail.actor,
      agent: detail.agent,
      target: detail.task_path,
      decision: detail.decision,
      task_id: detail.task_id
    })

    :ok
  rescue
    _ -> :ok
  catch
    # `GenServer.call` to a non-existent named process raises an
    # `:exit`, not an exception — `rescue` wouldn't catch it. Audit
    # logging failing should never propagate: the sentinel is
    # already cleared, and forcing a retry on an audit-only error
    # would create a resolution loop.
    :exit, _ -> :ok
  end

  defp default_fs_fun do
    %{
      mkdir_p!: &File.mkdir_p!/1,
      write!: &File.write!/2,
      exists?: &File.exists?/1
    }
  end

  # AuditLog is per-company under Glorbo.Agent.Registry —
  # not a global singleton. Resolve the {:via, Registry, ...} name
  # from the company slug, falling back to the bare module name
  # (the `_system` audit log, if one is running). Same pattern as
  # `Glorbo.Agent.Dispatch.default_audit_fun/2`.
  defp default_audit_fun,
    do: fn company, entry ->
      server =
        case Elixir.Registry.lookup(
               Glorbo.Agent.Registry,
               {:company_child, company, :audit_log}
             ) do
          [{_pid, _}] ->
            {:via, Elixir.Registry,
             {Glorbo.Agent.Registry, {:company_child, company, :audit_log}}}

          _ ->
            AuditLog
        end

      AuditLog.append(server, Map.put(entry, :company, company))
    end
end
