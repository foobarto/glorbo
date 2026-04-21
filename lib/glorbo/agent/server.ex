defmodule Glorbo.Agent.Server do
  @moduledoc """
  Per-agent GenServer with a wake-queue state machine (D-25..D-28; T-03-18;
  AGT-01 crash isolation).

  Under `Glorbo.Company.AgentSupervisor`, each agent gets a small 2-child
  `one_for_all` sub-supervisor with:

    1. `Task.Supervisor` (sibling placement, D-28) — runs the dispatch
       invocation via `Task.Supervisor.async_nolink/3` so a Task crash
       sends `:DOWN` (not `EXIT`) and does NOT cascade to this Server.
    2. This `Agent.Server` — owns the wake-queue + dispatches tasks.

  Crash semantics: killing either child restarts BOTH (clean slate). The
  parent AgentSupervisor is untouched; other agents are unaffected.

  ## Wake triggers (AGT-02)

  Accepted via `wake/2,3`:

    * `:inbox` — inotify inbox event (Plan 03-05 wires Watcher → here)
    * `:heartbeat` — cron-driven (Plan 03-02 Scheduler)
    * `:mention` — Router fans out `@<name>` mentions
    * `:director_approval` — Gate releases sentinel-blocked task
    * `:director_request` — Director-initiated dispatch

  Unknown triggers return `{:error, :unknown_trigger}` (A8).

  ## Wake-queue (D-26 / T-03-18)

  While busy, at most ONE wake is queued. Additional wakes coalesce into
  that single slot with the most-recent trigger winning. Dispatch
  completion pops the queued wake and immediately schedules the next
  invocation. Chatty inotify bursts produce at most one additional
  dispatch per burst.

  ## Dep-injection

    * `:dispatch_fun` — `(spec, task, opts -> dispatch_result)` (default
      `&Glorbo.Agent.Dispatch.execute/3`). Tests supply a fake that sends
      `{:dispatch_done, result}` to a coordinator pid.
    * `:inbox_scan_fun` — `(spec -> task() | nil)`. Real impl scans the
      agent's inbox for the oldest unread message; tests pass a stub.
  """
  use GenServer
  require Logger

  alias Glorbo.Agent.Dispatch

  @valid_triggers ~w(inbox heartbeat mention director_approval director_request)a

  @type trigger :: :inbox | :heartbeat | :mention | :director_approval | :director_request
  @type status :: %{
          state: :idle | :busy,
          current_task: String.t() | nil,
          current_task_path: String.t() | nil,
          current_task_trigger: trigger() | nil,
          current_task_pid: pid() | nil,
          pending_wake: {trigger(), DateTime.t()} | nil,
          last_exit_status: term() | nil
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a per-agent GenServer.

  Required opts:

    * `:spec` — `%Glorbo.Agent.Spec{}` (provides slug, provider, model).
    * `:company` — company slug (must match `spec.company` in production).
    * `:task_supervisor` — name of this agent's `Task.Supervisor`
      (provided by `Glorbo.Company.AgentSupervisor.start_agent/2`).

  Optional:

    * `:registry` — `Glorbo.Agent.Registry` by default.
    * `:name` — `:via` tuple; when absent, derived from
      `Glorbo.Agent.Registry.via(:agent_server, company, spec.slug)`.
    * `:dispatch_fun` — `(spec, task, opts -> dispatch_result)`.
    * `:inbox_scan_fun` — `(spec -> task() | nil)`.
    * `:dispatch_opts` — extra opts passed through to the dispatch fun.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    spec = Keyword.fetch!(opts, :spec)
    company = Keyword.fetch!(opts, :company)

    name =
      Keyword.get_lazy(opts, :name, fn ->
        registry = Keyword.get(opts, :registry, Glorbo.Agent.Registry)
        {:via, Registry, {registry, {:agent_server, company, spec.slug}}}
      end)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueue a wake. Returns `:ok` or `{:error, :unknown_trigger}`.

  The dispatch work is ALWAYS async (Task.Supervisor); this call blocks
  only for the GenServer state update (microseconds).
  """
  @spec wake(GenServer.server(), trigger(), map() | nil) ::
          :ok | {:error, :unknown_trigger}
  def wake(server, trigger, task \\ nil) do
    GenServer.call(server, {:wake, trigger, task})
  end

  @doc """
  Snapshot of the agent's scheduling state.
  """
  @spec status(GenServer.server()) :: status()
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Cancel the in-flight dispatch Task (if any). The agent itself keeps
  running and stays idle; the killed Task's `{:DOWN, ...}` message
  flows through the normal crash path and sets `last_exit_status` to
  a stop marker. No-op when the agent is already idle.
  """
  @spec stop_inflight(GenServer.server()) :: :ok | :idle
  def stop_inflight(server) do
    GenServer.call(server, :stop_inflight)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    spec = Keyword.fetch!(opts, :spec)
    company = Keyword.fetch!(opts, :company)
    task_sup = Keyword.fetch!(opts, :task_supervisor)

    # GAP-3: subscribe to the company-wide inbox PubSub topic so inotify
    # events on agents/<slug>/inbox/*.md trigger a wake when they target
    # THIS agent. Each Agent.Server filters incoming events by its own
    # slug (see handle_info below). `subscribe?: false` bypasses for
    # tests that drive wake/2,3 directly.
    if Keyword.get(opts, :subscribe?, true) do
      pubsub = Keyword.get(opts, :pubsub, Glorbo.PubSub)

      # Inbox events: `company:<co>:inbox` — filtered to this slug in
      # handle_info/2.
      case Phoenix.PubSub.subscribe(pubsub, "company:#{company}:inbox") do
        :ok -> :ok
        {:error, _} -> :ok
      end

      # Director wake-requests: `company:<co>:agents:<slug>:wake` —
      # per-agent topic, no extra slug filter needed. Without this the
      # whole wake-now button path (wake-request.md → inotify →
      # PubSub → AgentServer) never reaches dispatch.
      case Phoenix.PubSub.subscribe(pubsub, "company:#{company}:agents:#{spec.slug}:wake") do
        :ok -> :ok
        {:error, _} -> :ok
      end
    end

    state = %{
      spec: spec,
      company: company,
      task_supervisor: task_sup,
      dispatch_fun: Keyword.get(opts, :dispatch_fun, &default_dispatch_fun/3),
      inbox_scan_fun: Keyword.get(opts, :inbox_scan_fun, &default_inbox_scan/3),
      dispatch_opts: Keyword.get(opts, :dispatch_opts, []),
      status: :idle,
      current_task: nil,
      current_task_path: nil,
      current_task_trigger: nil,
      current_task_ref: nil,
      current_task_pid: nil,
      pending_wake: nil,
      last_exit_status: nil,
      base: Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root()),
      pubsub: Keyword.get(opts, :pubsub, Glorbo.PubSub)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:wake, trigger, _task}, _from, state) when trigger not in @valid_triggers do
    {:reply, {:error, :unknown_trigger}, state}
  end

  def handle_call({:wake, trigger, task}, _from, state) do
    if state.status == :idle do
      handle_wake_idle(state, trigger, task)
    else
      # Busy: queue (or replace) pending wake with most-recent-wins
      # semantics (D-26). At most ONE slot.
      {:reply, :ok, %{state | pending_wake: {trigger, DateTime.utc_now()}}}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       state: state.status,
       current_task: state.current_task,
       current_task_path: state.current_task_path,
       current_task_trigger: state.current_task_trigger,
       current_task_pid: state.current_task_pid,
       pending_wake: state.pending_wake,
       last_exit_status: state.last_exit_status
     }, state}
  end

  def handle_call(:stop_inflight, _from, %{current_task: nil} = state) do
    {:reply, :idle, state}
  end

  def handle_call(:stop_inflight, _from, %{current_task_pid: pid} = state) when is_pid(pid) do
    # Kill the dispatch Task unilaterally. The {:DOWN, ref, ...} message
    # that the monitor would have delivered is converted to :normal by
    # Process.exit(:kill), so we clean state here rather than rely on
    # the handle_info crash path.
    Process.exit(pid, :kill)

    new_state = %{
      state
      | status: :idle,
        current_task: nil,
        current_task_path: nil,
        current_task_trigger: nil,
        current_task_ref: nil,
        current_task_pid: nil,
        last_exit_status: "stopped_by_director"
    }

    # pop_pending/1 returns `{:noreply, state}` — pattern-match to extract
    # the state and form a proper {:reply, :ok, state} tuple for handle_call.
    {:noreply, state_after_pop} = pop_pending(new_state)
    {:reply, :ok, state_after_pop}
  end

  def handle_call(:stop_inflight, _from, state), do: {:reply, :idle, state}

  defp handle_wake_idle(state, trigger, task) do
    case resolve_task(state, trigger, task) do
      nil ->
        # Trigger with no resolvable task — stay idle. Not an error;
        # inbox scan may legitimately find nothing.
        {:reply, :ok, state}

      resolved ->
        {:reply, :ok, start_dispatch(state, resolved)}
    end
  end

  # Dispatch Task completed normally — demonitor + update state + pop pending
  @impl true
  def handle_info({ref, result}, %{current_task_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    finish(state, {:result, result})
  end

  # Dispatch Task crashed — convert to exit-status + update state + pop pending
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current_task_ref: ref} = state
      ) do
    finish(state, {:crashed, reason})
  end

  # GAP-3: PubSub inbox event → :inbox wake for THIS agent.
  # Each Agent.Server subscribes to the company-wide inbox topic; only
  # events under `agents/<this-slug>/inbox/` advance to wake. Inbox
  # payload parsing (which file → task map) lives in inbox_scan_fun, so
  # the server stays lean and the lookup is dep-injectable.
  #
  # `rel_path` is intentionally discarded here — the scanner returns the
  # OLDEST unread .md file, not whichever one happened to fire the event
  # (D-26 FIFO inbox semantics). Using `rel_path` as a hint would violate
  # ordering when multiple files land between handler ticks.
  def handle_info({:file_event, rel_path, events}, state) when is_binary(rel_path) do
    cond do
      wake_request_for_me?(rel_path, state.spec.slug) and inbox_event_write?(events) ->
        handle_director_wake(state)

      mention_event_for_me?(rel_path, state.spec.slug) and inbox_event_write?(events) ->
        handle_inbox_wake(state, :mention)

      inbox_event_for_me?(rel_path, state.spec.slug) and inbox_event_write?(events) ->
        handle_inbox_wake(state, :inbox)

      agent_md_for_me?(rel_path, state.spec.slug) and inbox_event_write?(events) ->
        {:noreply, maybe_reload_spec(state)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # agents/<slug>/AGENT.md or agents/<slug>/agent.md — hot-reload
  # trigger so edits to permissions/network/provider take effect
  # without restarting the whole server.
  defp agent_md_for_me?(rel_path, slug) do
    case Path.split(rel_path) do
      ["agents", ^slug, file] when file in ["AGENT.md", "agent.md"] -> true
      _ -> false
    end
  end

  defp maybe_reload_spec(%{spec: old_spec} = state) do
    path =
      Path.join([state.base, "companies", state.company, "agents", old_spec.slug, "AGENT.md"])

    case Glorbo.Agent.Parser.parse_file(path) do
      {:ok, new_spec} ->
        require Logger
        Logger.info("agent spec reloaded from disk: #{old_spec.slug}@#{state.company}")
        %{state | spec: new_spec}

      {:error, reason} ->
        require Logger

        Logger.warning(
          "agent spec reload failed for #{old_spec.slug}@#{state.company}: #{inspect(reason)}"
        )

        state
    end
  end

  # agents/<slug>/state/wake-request.md — matches the shape emitted by
  # Glorbo.Filesystem.Watcher's :wake classification.
  defp wake_request_for_me?(rel_path, slug) do
    case Path.split(rel_path) do
      ["agents", ^slug, "state", filename] ->
        String.starts_with?(filename, "wake-request") and String.ends_with?(filename, ".md")

      _ ->
        false
    end
  end

  defp handle_director_wake(%{status: :idle} = state) do
    # Director wakes without a task — same as an inbox wake, we scan the
    # inbox for the oldest unread item (if any) and dispatch. If nothing's
    # in the inbox, we still dispatch with a synthetic "director_request"
    # task whose prompt comes from wake-request.md's body.
    case call_inbox_scan(state) do
      nil -> {:noreply, start_dispatch(state, director_wake_task(state))}
      %{} = task -> {:noreply, start_dispatch(state, task)}
    end
  end

  defp handle_director_wake(%{status: :busy} = state) do
    {:noreply, %{state | pending_wake: {:director_request, DateTime.utc_now()}}}
  end

  # Build a minimal task for a director wake when the inbox is empty.
  # Reads the wake-request.md body (if present) as the prompt; falls back
  # to a generic prompt if the file's already gone.
  defp director_wake_task(state) do
    path =
      Path.join([
        state.base,
        "companies",
        state.company,
        "agents",
        state.spec.slug,
        "state",
        "wake-request.md"
      ])

    prompt =
      case File.read(path) do
        {:ok, content} -> content
        _ -> "Director wake — no task specified."
      end

    %{
      task_id: "director-wake-#{System.unique_integer([:positive])}",
      prompt: prompt,
      task_path: nil
    }
  end

  defp handle_inbox_wake(%{status: :idle} = state, trigger) do
    case call_inbox_scan(state, trigger) do
      nil -> {:noreply, state}
      %{} = task -> {:noreply, start_dispatch(state, task)}
    end
  end

  defp handle_inbox_wake(%{status: :busy} = state, trigger) do
    # Busy: queue a pending wake (most-recent-wins; at most one slot).
    {:noreply, %{state | pending_wake: {trigger, DateTime.utc_now()}}}
  end

  # ---------------------------------------------------------------------------
  # Dispatch lifecycle
  # ---------------------------------------------------------------------------

  defp start_dispatch(state, task) do
    task_fn = fn ->
      state.dispatch_fun.(state.spec, task, state.dispatch_opts)
    end

    %Task{ref: ref, pid: pid} = Task.Supervisor.async_nolink(state.task_supervisor, task_fn)

    new_state = %{
      state
      | status: :busy,
        current_task: task.task_id,
        current_task_path: Map.get(task, :task_path),
        current_task_trigger: Map.get(task, :trigger),
        current_task_ref: ref,
        current_task_pid: pid,
        pending_wake: nil
    }

    broadcast_status(new_state)
    new_state
  end

  defp finish(state, {:result, result}) do
    exit_status = dispatch_result_to_exit_status(result)
    maybe_route_reply(state, result, exit_status)
    maybe_drain_inbox(state, exit_status)

    new_state = %{
      state
      | status: :idle,
        current_task: nil,
        current_task_path: nil,
        current_task_trigger: nil,
        current_task_ref: nil,
        current_task_pid: nil,
        last_exit_status: exit_status
    }

    broadcast_status(new_state)
    pop_pending(new_state)
  end

  defp finish(state, {:crashed, reason}) do
    new_state = %{
      state
      | status: :idle,
        current_task: nil,
        current_task_path: nil,
        current_task_trigger: nil,
        current_task_ref: nil,
        current_task_pid: nil,
        last_exit_status: {:crashed, reason}
    }

    broadcast_status(new_state)
    pop_pending(new_state)
  end

  # Broadcast a status change to subscribers of `company:<co>:agents:status`.
  # Subscribers (sidebar-hosting LVs) re-assign + re-render so pill dots
  # reflect the live state without waiting for a nav event. Best-effort —
  # PubSub down shouldn't crash the Server.
  #
  # The `:busy` variant carries the current task path so CompanyLive's
  # roster + AgentLive's dashboard can render a "working on: X" line
  # without subscribing to the full dispatch stream (PLAN P1-2).
  defp broadcast_status(state) do
    %{pubsub: pubsub, company: co, spec: spec, status: status} = state

    message =
      case status do
        :busy -> {:agent_status, spec.slug, :busy, state.current_task_path}
        other -> {:agent_status, spec.slug, other, nil}
      end

    Phoenix.PubSub.broadcast(pubsub, "company:#{co}:agents:status", message)
  rescue
    _ -> :ok
  end

  # GEP-16 post-completion reply routing: synthesize a Router-routable
  # outbox envelope from the agent's reply, so inbox/mention-triggered
  # replies flow back to the original sender (or the originating
  # channel for @mentions). Without this, the reply lands at the
  # GEP-8 reply path ({workspace}/.glorbo/outbox/<ts>-<id>.md) which
  # the Router never watches — two-way conversation silently breaks.
  #
  # The synthesized file lives at agents/<slug>/outbox/<ts>-reply-<id>.md
  # with a `to:` header the Router's extract_to/1 accepts:
  #   - agent:<from> for regular inbox replies (`from:` in source)
  #   - chat:<channel> for @mention replies (`channel:` in source)
  # Router's inotify subscription picks it up and routes.
  #
  # Failure modes (all no-ops): no reply in result, source file gone,
  # frontmatter missing `from:`/`channel:`, filesystem error — we log
  # and move on rather than losing the reply entirely (the file still
  # exists at the GEP-8 reply path).
  defp maybe_route_reply(state, result, exit_status) do
    trigger = Map.get(state, :current_task_trigger)
    rel_path = Map.get(state, :current_task_path)

    cond do
      exit_status != 0 -> :ok
      trigger not in [:inbox, :mention] -> :ok
      not is_binary(rel_path) -> :ok
      true -> do_route_reply(state, result, rel_path)
    end
  end

  defp do_route_reply(state, {:ok, %{reply: reply}}, rel_path)
       when is_binary(reply) and reply != "" do
    company_root = Path.join([state.base, "companies", state.spec.company])
    source_abs = Path.join(company_root, rel_path)

    with {:ok, meta} <- read_source_frontmatter(source_abs),
         {:ok, to} <- reply_target(meta) do
      case to do
        {:task_comment, task_id} -> write_task_comment_reply(state, reply, task_id)
        to -> write_outbox_reply(state, reply, to)
      end
    else
      {:error, reason} ->
        require Logger

        Logger.debug(
          "[agent/#{state.spec.slug}] reply routing skipped " <>
            "path=#{rel_path} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp do_route_reply(_state, _result, _rel_path), do: :ok

  defp read_source_frontmatter(path) do
    with {:ok, content} <- File.read(path),
         {:ok, meta, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      {:ok, meta}
    end
  end

  # mention source file carries `channel:`; regular-inbox source
  # carries `from:`. Mention takes priority when both are present.
  #
  # Director isn't a real agent (no `agents/director/` dir) — replies
  # to the Director are surfaced via the audit log + dashboard, not
  # the Router pipeline. Returning :skip here prevents a "Message to
  # `agent:director` was rejected: agents:create:*" rejection cycle
  # observed in 2026-04-18 E2E testing.
  defp reply_target(meta) do
    cond do
      is_binary(channel = Map.get(meta, "channel")) and channel != "" ->
        {:ok, "chat:#{channel}"}

      # Task assignment notifications carry `kind: task_assignment` + the
      # task id. Reply is appended to the task file as a comment (same
      # format as `GlorboWeb.Actions.post_task_comment`). Handled by
      # `write_task_comment_reply/3` instead of the outbox Router path.
      Map.get(meta, "kind") == "task_assignment" and is_binary(Map.get(meta, "task_id")) ->
        {:ok, {:task_comment, Map.get(meta, "task_id")}}

      is_binary(from = Map.get(meta, "from")) and from == "director" ->
        {:error, :director_reply_skipped}

      is_binary(from = Map.get(meta, "from")) and from != "" ->
        {:ok, "agent:#{from}"}

      true ->
        {:error, :no_reply_target}
    end
  end

  # Task-assignment replies: append a `## <ts> | <slug>\n<body>` block to
  # the task file itself (same shape as GlorboWeb.Actions.post_task_comment).
  # Writes go through the filesystem; the kanban overlay's comment thread
  # renders them next to the Director's prompt.
  #
  # Also parses an optional trailing `ACTIONS:` block for structured
  # directives the agent can emit (reassign_to / status). This lets an
  # agent who can't write task frontmatter directly (no projects:write
  # permission) still request state changes via the reply contract.
  defp write_task_comment_reply(state, body, task_id) do
    company_root = Path.join([state.base, "companies", state.spec.company])

    case resolve_task_path(company_root, task_id) do
      {:ok, abs} ->
        {comment_body, actions} = extract_task_actions(body)
        ts = DateTime.utc_now() |> DateTime.to_iso8601()
        entry = "\n## #{ts} | #{state.spec.slug}\n#{String.trim(comment_body)}\n"

        case File.write(abs, entry, [:append, :sync]) do
          :ok ->
            apply_task_actions(abs, actions)
            :ok

          {:error, reason} ->
            require Logger
            Logger.warning("task comment reply write failed: #{inspect(reason)}")
            :ok
        end

      :error ->
        require Logger
        Logger.warning("task comment reply: task_id #{task_id} not found")
        :ok
    end
  end

  # Scan projects/*/tasks/<task_id>.md and return the first match.
  defp resolve_task_path(company_root, task_id) do
    pattern = Path.join([company_root, "projects", "*", "tasks", "#{task_id}.md"])

    case Path.wildcard(pattern) do
      [abs | _] -> {:ok, abs}
      [] -> :error
    end
  end

  # Agents emit optional structured directives at the end of their
  # reply. The block is anchored by `ACTIONS:` on its own line; each
  # action is a `- key: value` list item. Unknown keys are ignored.
  #
  # Supported:
  #   - reassign_to: <slug>   # change assigned_to
  #   - status: <status>      # change status (todo/in-progress/done/...)
  #
  # Parser is deliberately narrow — structured actions shouldn't get
  # triggered by prose that happens to contain "status:".
  defp extract_task_actions(body) do
    case String.split(body, ~r/^\s*ACTIONS:\s*$/m, parts: 2) do
      [comment, actions_block] ->
        {String.trim_trailing(comment), parse_task_actions(actions_block)}

      [comment] ->
        {comment, []}
    end
  end

  @task_action_re ~r/^\s*-\s*(?<key>reassign_to|status)\s*:\s*(?<val>[^\s#][^\n]*?)\s*$/m

  defp parse_task_actions(block) do
    @task_action_re
    |> Regex.scan(block, capture: :all_names)
    |> Enum.map(fn [key, val] -> {key, val} end)
  end

  defp apply_task_actions(_abs, []), do: :ok

  defp apply_task_actions(abs, actions) do
    updates =
      Enum.reduce(actions, %{}, fn
        {"reassign_to", slug}, acc -> Map.put(acc, "assigned_to", slug)
        {"status", status}, acc -> Map.put(acc, "status", status)
        _, acc -> acc
      end)

    if updates == %{} do
      :ok
    else
      # TaskDefinition.write_frontmatter replaces the whole frontmatter
      # with whatever map it receives — keys it knows about, wiping the
      # rest. Merge the updates into the existing frontmatter first so
      # title/priority/severity/requires_approval survive a partial
      # mutation (regression: UAT 2026-04-20 test II-6 caught this).
      existing = read_existing_frontmatter(abs)
      merged = Map.merge(existing, updates)

      case Glorbo.TaskDefinition.write_frontmatter(abs, merged) do
        :ok ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("task action apply failed: #{inspect(reason)}")
          :ok
      end
    end
  end

  defp read_existing_frontmatter(abs) do
    with {:ok, content} <- File.read(abs),
         {:ok, meta, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      meta
      |> Map.new(fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
    else
      _ -> %{}
    end
  end

  defp write_outbox_reply(state, body, to) do
    ts = System.system_time(:millisecond)
    msg_id = "reply-#{ts}"

    outbox_dir =
      Path.join([
        state.base,
        "companies",
        state.spec.company,
        "agents",
        state.spec.slug,
        "outbox"
      ])

    path = Path.join(outbox_dir, "#{ts}-#{msg_id}.md")

    content = """
    ---
    to: "#{to}"
    msg_id: "#{msg_id}"
    ---

    #{String.trim(body)}
    """

    try do
      File.mkdir_p!(outbox_dir)
      File.write!(path, content)
      :ok
    rescue
      e ->
        require Logger
        Logger.warning("reply outbox write failed: #{Exception.message(e)}")
        :ok
    end
  end

  # GEP-16 post-completion drain: move the inbox file the agent just
  # processed into `history/processed/<ts>-<basename>` so the next wake
  # doesn't re-pick it. Without this, default_inbox_scan returns the
  # same oldest file forever and the agent loops at O(seconds) on every
  # fresh PubSub event — observed in E2E testing 2026-04-18, burned 6
  # redundant claude-code dispatches on a single stuck inbox file.
  #
  # Scope of the drain:
  #   - only on exit_status 0 (don't lose the file on a crash)
  #   - only for :inbox and :mention triggers (heartbeat + director_request
  #     don't own the inbox file that woke them; their task_path may be nil
  #     or point to a file that must stay in place)
  #   - task_path must be relative to companies/<co>/ (the shape
  #     default_inbox_scan returns); absolute paths or nil → no-op
  defp maybe_drain_inbox(state, exit_status) do
    trigger = Map.get(state, :current_task_trigger)
    rel_path = Map.get(state, :current_task_path)

    cond do
      exit_status != 0 ->
        :ok

      trigger not in [:inbox, :mention] ->
        :ok

      not is_binary(rel_path) ->
        :ok

      not String.starts_with?(rel_path, "agents/#{state.spec.slug}/inbox/") ->
        :ok

      true ->
        do_drain_inbox(state, rel_path)
    end
  end

  defp do_drain_inbox(state, rel_path) do
    company_root = Path.join([state.base, "companies", state.spec.company])
    src = Path.join(company_root, rel_path)

    # Strip the `agents/<slug>/inbox/` prefix so the destination path
    # keeps any subdirectory structure (mentions/, from-<sender>/, etc.)
    # inside history/processed.
    prefix = "agents/#{state.spec.slug}/inbox/"

    suffix =
      case String.split(rel_path, prefix, parts: 2) do
        [_, rest] -> rest
        _ -> Path.basename(rel_path)
      end

    ts = System.system_time(:millisecond)

    dst =
      Path.join([
        company_root,
        "agents",
        state.spec.slug,
        "history",
        "processed",
        "#{ts}-#{Path.basename(suffix)}"
      ])

    try do
      File.mkdir_p!(Path.dirname(dst))
      File.rename!(src, dst)
    rescue
      e ->
        require Logger
        Logger.warning("inbox drain failed for #{rel_path}: #{Exception.message(e)}")
    end

    :ok
  end

  defp pop_pending(%{pending_wake: nil} = state), do: {:noreply, state}

  defp pop_pending(%{pending_wake: {trigger, _ts}} = state) do
    case resolve_task(state, trigger, nil) do
      nil ->
        {:noreply, %{state | pending_wake: nil}}

      resolved ->
        {:noreply, start_dispatch(%{state | pending_wake: nil}, resolved)}
    end
  end

  defp resolve_task(_state, _trigger, %{} = explicit_task), do: explicit_task

  defp resolve_task(state, trigger, nil) do
    case call_inbox_scan(state, trigger) do
      nil when trigger == :heartbeat ->
        heartbeat_task(state)

      task ->
        task
    end
  end

  # GEP-14: when inbox is empty on a heartbeat wake, synthesise a minimal
  # task so the agent still dispatches.  HEARTBEAT.md lives in the system
  # prompt (read_system_prompt), not the task body.
  defp heartbeat_task(state) do
    %{spec: spec, base: base} = state
    company_root = Path.join([base, "companies", spec.company])
    hb_path = Path.join([company_root, "agents", spec.slug, "HEARTBEAT.md"])

    if File.exists?(hb_path) do
      %{
        task_id: "heartbeat",
        task_path: nil,
        prompt: compose_prompt(spec, base, nil, :heartbeat),
        trigger: :heartbeat
      }
    end
  end

  # Call the inbox-scan fun compatibly with three signatures:
  #
  #   - 1-arity `(spec)` — historical; most existing tests.
  #   - 2-arity `(spec, base)` — adds base dir injection (TODO.md High #3).
  #   - 3-arity `(spec, base, trigger)` — new; lets the scanner pick
  #     trigger-appropriate files. `:mention` wakes should prefer
  #     files in `inbox/mentions/` over whatever oldest-by-mtime
  #     returns from the top-level (task #125).
  defp call_inbox_scan(state, trigger \\ nil) do
    %{inbox_scan_fun: fun, spec: spec, base: base} = state

    case :erlang.fun_info(fun, :arity) do
      {:arity, 1} -> fun.(spec)
      {:arity, 2} -> fun.(spec, base)
      {:arity, 3} -> fun.(spec, base, trigger)
      _ -> fun.(spec)
    end
  end

  defp dispatch_result_to_exit_status({:ok, %{exit_status: s}}), do: s
  defp dispatch_result_to_exit_status({:stopped, :budget_hard_stop}), do: "budget_hard_stop"
  defp dispatch_result_to_exit_status({:error, reason}), do: {:error, reason}
  defp dispatch_result_to_exit_status(other), do: {:unexpected, other}

  defp default_dispatch_fun(spec, task, opts) do
    Dispatch.execute(spec, task, opts)
  end

  # ---------------------------------------------------------------------------
  # Inbox PubSub helpers (GAP-3)
  # ---------------------------------------------------------------------------

  # Is the relative path scoped to THIS agent's inbox? Match the prefix
  # `agents/<slug>/inbox/`. Doesn't match agents/<other>/inbox/ so each
  # Agent.Server only wakes on its own events.
  defp inbox_event_for_me?(rel_path, slug) do
    # Rejection notices are an inbox write but not a task; matching
    # them here would fire a wake that dispatches on the rejection
    # itself, producing another rejection, ad infinitum (task #130).
    String.starts_with?(rel_path, "agents/#{slug}/inbox/") and
      not String.starts_with?(rel_path, "agents/#{slug}/inbox/rejections/")
  end

  defp mention_event_for_me?(rel_path, slug) do
    String.starts_with?(rel_path, "agents/#{slug}/inbox/mentions/")
  end

  defp inbox_event_write?(events) when is_list(events),
    do: Enum.any?(events, &(&1 in [:created, :modified]))

  defp inbox_event_write?(_), do: false

  # Default inbox scanner: pick the oldest unread .md file under
  # agents/<slug>/inbox/ and return a task map. Returns nil when the
  # inbox is empty. Directories walked lazily; never reads the whole
  # inbox into memory. Called from resolve_task/3 (explicit wake/3) and
  # from handle_inbox_wake/1 (PubSub :file_event path).
  #
  # 3-arity variant (trigger-aware): for `:mention` wakes, scan
  # `inbox/mentions/` FIRST — the file that caused the wake is in there
  # and should be processed before any unrelated stale top-level files
  # (task #125). Falls back to the 2-arity behaviour if nothing in
  # mentions/.
  defp default_inbox_scan(%_{} = spec, base, trigger) when is_binary(base) do
    inbox_dir = Path.join([base, "companies", spec.company, "agents", spec.slug, "inbox"])
    company_root = Path.join([base, "companies", spec.company])

    if File.dir?(inbox_dir) do
      pick_inbox_file(inbox_dir, trigger)
      |> case do
        nil ->
          nil

        path ->
          %{
            task_id: Path.basename(path, ".md"),
            task_path: Path.relative_to(path, company_root),
            prompt: compose_prompt(spec, base, path, trigger),
            trigger: trigger || :inbox
          }
      end
    end
  end

  # Stitch the agent's AGENT.md system prompt in front of the inbox body
  # so the CLI invocation has the persona/permissions context. Without
  # this, the agent only sees the raw inbox body ("Please respond to
  # chat!") with zero context about who it is or what it can do.
  defp compose_prompt(spec, base, inbox_path, trigger) do
    body = if inbox_path, do: read_or_empty(inbox_path), else: ""
    system = read_system_prompt(spec, base)

    source_rel =
      if inbox_path,
        do: Path.relative_to(inbox_path, Path.join([base, "companies", spec.company])),
        else: "heartbeat"

    reply_hint =
      if inbox_path,
        do: reply_routing_hint(inbox_path),
        else: "Reply lands wherever the triggering message specifies."

    memory = compose_memory_section(spec, base)

    """
    #{system}

    ---

    ## Runtime context (#{trigger || :inbox})

    You are running inside a bwrap sandbox. Glorbo enforces all
    permissions at the kernel layer (mount namespaces + ACLs), so file
    ops in the mounted paths below ARE allowed — you do NOT need to ask
    the user to approve each write.

    - Your slug: `#{spec.slug}`
    - Company: `#{spec.company}`
    - cwd: `/workspace` (rw — your scratch area; this is your $HOME too)
    - Inbox: `/inbox` (ro — your inbox; same as `$GLORBO_INBOX`)
    - Outbox: `/outbox` (rw — for artefacts, attachments, side-effects)
    - Skills: `/workspace/.glorbo-run/$GLORBO_TASK_ID/.glorbo-skills/`
      (ro). **Start every run by reading `INDEX.md` in that dir.** If a
      `glorbo.md` skill is listed, read it first — it documents the
      runtime contract (env vars, ACTIONS DSL, outbox routing for
      messages / comments / task filing / hire requests). Other
      skills listed there are role-specific capabilities you may
      use.
    - Permission-driven mounts visible to you this run:
    #{permission_mount_summary(spec)}
    #{memory}

    ## How to reply

    **Your FINAL text response (what you print to stdout) IS the reply.**
    #{reply_hint}

    Keep it terse and conversational. Do NOT describe the files you
    wrote, the paths you used, or the steps you took. Do NOT say
    "Done!" or "I've completed the task". Just write what you want
    the reader to see.

    Example good reply to "ping":
    > pong

    Example bad reply to "ping":
    > Done! I've replied "pong" to your ping message in
    > `/outbox/1776633822974-reply-1776633822974.md`.

    Use tools (Write, Edit, Bash) to do work on disk, but your final
    conversational response must be your last assistant message.

    ## Triggering message

    Source: `#{source_rel}`

    #{body}
    """
  end

  # GEP-21 / #281 — compose the agent's memory section from
  # `agents/<slug>/memory/` if present. Returns empty string when
  # there's no memory dir or every read fails. Rendered as a
  # `## Memory` section following the permission mount summary.
  defp compose_memory_section(spec, base) do
    case Glorbo.Agent.Memory.compose(base, spec.company, spec.slug) do
      {:ok, ""} -> ""
      {:ok, content} -> "\n## Memory\n\n#{content}"
    end
  end

  # Tell the agent in one line where their stdout text will land, based
  # on what kind of inbox file triggered them. Mentions route back to
  # the channel; task-assignment notifications route as a task comment;
  # inter-agent messages route to the sender's inbox.
  defp reply_routing_hint(inbox_path) do
    case File.read(inbox_path) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, meta, _body} -> format_reply_hint(meta)
          _ -> "Reply lands wherever the triggering message specifies."
        end

      _ ->
        "Reply lands wherever the triggering message specifies."
    end
  end

  # Summarise the agent's permissions as a bullet list of the
  # mount paths the sandbox will expose. Agents need to know about
  # `/projects/<name>` etc explicitly — running models ignore AGENT.md
  # body if the Glorbo-composed system prompt doesn't name these
  # paths alongside /workspace, /inbox, /outbox.
  #
  # Public `@doc false` so tests can exercise it without faking the
  # whole compose_prompt pipeline.
  @doc false
  def permission_mount_summary(spec) do
    entries =
      spec.permissions
      |> Enum.map(&permission_to_bullet/1)
      |> Enum.reject(&is_nil/1)

    case entries do
      [] -> "      (none — only /workspace /inbox /outbox /skills are mounted)"
      list -> Enum.map_join(list, "\n", &("      " <> &1))
    end
  end

  defp permission_to_bullet({"projects", "read", "*"}),
    do: "- `/projects/` (ro) — all projects in this company"

  defp permission_to_bullet({"projects", "read", name}),
    do: "- `/projects/#{name}/` (ro) — only this project visible"

  defp permission_to_bullet({"projects", "write", "*"}),
    do: "- `/projects/` (rw) — full projects tree writable"

  defp permission_to_bullet({"projects", "write", name}),
    do: "- `/projects/#{name}/` (rw) — only this project writable"

  defp permission_to_bullet({"chat", "read", _}),
    do: "- `/chat/` (ro) — company channel logs"

  defp permission_to_bullet({"chat", "write", _}),
    do: "- `/chat/` (rw) — can post to channel logs via outbox routing"

  defp permission_to_bullet({"tasks", "read", _}),
    do: "- `/tasks/` (ro) — company task files"

  defp permission_to_bullet({"tasks", "write", _}),
    do: "- `/tasks/` (rw) — can mutate task files via outbox routing"

  defp permission_to_bullet({"agents", "read", _}),
    do: "- `/agents/` (ro) — sibling agents' public identity"

  defp permission_to_bullet({"proposals", "read", _}),
    do: "- `/proposals/` (ro) — structural proposals visible to this agent (GEP-28)"

  defp permission_to_bullet({"proposals", "write", _}),
    do:
      "- `/proposals/` (rw) — write `proposals/<id>.md` to request hiring/firing/budget/project changes (GEP-28)"

  defp permission_to_bullet(_), do: nil

  defp format_reply_hint(%{"channel" => ch}) when is_binary(ch) and ch != "" do
    "Your reply posts to the `##{ch}` channel as a message."
  end

  defp format_reply_hint(%{"kind" => "task_assignment", "task_id" => tid}) when is_binary(tid) do
    """
    Your reply appends as a comment on task `#{tid}` — the Director sees it in the task detail overlay.

    To change the task state, append an `ACTIONS:` block at the very end
    of your reply. Supported:

        ACTIONS:
        - reassign_to: <slug>   # change the assignee
        - status: <status>      # one of: todo, in-progress, pending, done

    Example — read the task, add a short note, hand back to the Director:

    > Got it, reviewed. Handing back.
    >
    > ACTIONS:
    > - reassign_to: director
    > - status: todo

    Omit the ACTIONS block if no state change is needed.
    """
  end

  defp format_reply_hint(%{"from" => from}) when is_binary(from) and from != "director" do
    "Your reply goes to `@#{from}`'s inbox as an inter-agent message."
  end

  defp format_reply_hint(_), do: "Reply lands wherever the triggering message specifies."

  defp read_system_prompt(spec, base) do
    agent_dir = Path.join([base, "companies", spec.company, "agents", spec.slug])

    agent_md =
      Path.join(agent_dir, "AGENT.md")
      |> File.read()
      |> case do
        {:ok, content} -> strip_frontmatter(content)
        _ -> "You are `#{spec.slug}` in company `#{spec.company}`."
      end

    soul_md =
      Path.join(agent_dir, "SOUL.md")
      |> File.read()
      |> case do
        {:ok, content} -> "\n\n---\n\n## Voice / character\n\n" <> strip_frontmatter(content)
        _ -> ""
      end

    heartbeat_md =
      Path.join(agent_dir, "HEARTBEAT.md")
      |> File.read()
      |> case do
        {:ok, content} -> "\n\n---\n\n## Heartbeat checklist\n\n" <> strip_frontmatter(content)
        _ -> ""
      end

    agent_md <> soul_md <> heartbeat_md
  end

  defp strip_frontmatter(content) do
    case String.split(content, ~r/\A---\r?\n.*?\r?\n---\r?\n/s, parts: 2) do
      [_fm, body] -> String.trim_leading(body)
      [body] -> body
    end
  end

  # `:mention` → prefer the oldest file in `mentions/`; fall through
  # to the canonical oldest-across-all-dirs scan if that subdir is
  # empty. Any other trigger uses the canonical scan.
  defp pick_inbox_file(inbox_dir, :mention) do
    mentions_dir = Path.join(inbox_dir, "mentions")

    case md_files_in(mentions_dir) |> Enum.sort_by(&file_mtime/1) do
      [first | _] -> first
      [] -> pick_inbox_file(inbox_dir, nil)
    end
  end

  defp pick_inbox_file(inbox_dir, _trigger) do
    case list_inbox_md_files(inbox_dir) do
      [first | _] -> first
      [] -> nil
    end
  end

  # Subdirs of inbox/ that carry actionable tasks. `rejections/` is
  # deliberately excluded: rejection notices from the Router are
  # notifications, not new work — scanning them creates a self-wake
  # loop where every rejected reply spawns a fresh dispatch that
  # produces yet another rejection (task #130).
  @non_actionable_inbox_subdirs ~w(rejections)

  defp list_inbox_md_files(inbox_dir) do
    # Walk top-level + one subdir deep (`from-<sender>/*.md`,
    # `mentions/*.md`) — Router writes under these.
    direct = md_files_in(inbox_dir)

    sub_dirs_files =
      inbox_dir
      |> File.ls()
      |> case do
        {:ok, entries} -> entries
        _ -> []
      end
      |> Enum.reject(&(&1 in @non_actionable_inbox_subdirs))
      |> Enum.map(&Path.join(inbox_dir, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&md_files_in/1)

    (direct ++ sub_dirs_files)
    |> Enum.sort_by(&file_mtime/1)
  end

  defp md_files_in(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(fn p -> File.regular?(p) and String.ends_with?(p, ".md") end)

      _ ->
        []
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat.mtime
      _ -> 0
    end
  end

  # Cap inbox-file reads at the prompt size limit. A pathologically large
  # inbox file would block the Agent.Server mailbox during
  # default_inbox_scan → read_or_empty on its way to dispatch — which
  # would then reject the prompt as :prompt_too_large anyway. Short-circuit
  # here so the GenServer doesn't spend milliseconds reading multi-GB
  # junk (TODO.md Important #2).
  @inbox_read_cap 5 * 1024 * 1024

  defp read_or_empty(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @inbox_read_cap ->
        ""

      {:ok, _} ->
        case File.read(path) do
          {:ok, bytes} -> bytes
          _ -> ""
        end

      _ ->
        ""
    end
  end
end
