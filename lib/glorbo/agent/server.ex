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
      inbox_scan_fun: Keyword.get(opts, :inbox_scan_fun, &default_inbox_scan/2),
      dispatch_opts: Keyword.get(opts, :dispatch_opts, []),
      status: :idle,
      current_task: nil,
      current_task_path: nil,
      current_task_trigger: nil,
      current_task_ref: nil,
      pending_wake: nil,
      last_exit_status: nil,
      base: Keyword.get(opts, :base, Path.expand("~/.glorbo"))
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
       pending_wake: state.pending_wake,
       last_exit_status: state.last_exit_status
     }, state}
  end

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

      inbox_event_for_me?(rel_path, state.spec.slug) and inbox_event_write?(events) ->
        handle_inbox_wake(state)

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

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

  defp handle_inbox_wake(%{status: :idle} = state) do
    case call_inbox_scan(state) do
      nil -> {:noreply, state}
      %{} = task -> {:noreply, start_dispatch(state, task)}
    end
  end

  defp handle_inbox_wake(%{status: :busy} = state) do
    # Busy: queue a pending wake (most-recent-wins; at most one slot).
    {:noreply, %{state | pending_wake: {:inbox, DateTime.utc_now()}}}
  end

  # ---------------------------------------------------------------------------
  # Dispatch lifecycle
  # ---------------------------------------------------------------------------

  defp start_dispatch(state, task) do
    task_fn = fn ->
      state.dispatch_fun.(state.spec, task, state.dispatch_opts)
    end

    %Task{ref: ref} = Task.Supervisor.async_nolink(state.task_supervisor, task_fn)

    %{
      state
      | status: :busy,
        current_task: task.task_id,
        current_task_path: Map.get(task, :task_path),
        current_task_trigger: Map.get(task, :trigger),
        current_task_ref: ref,
        pending_wake: nil
    }
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
        last_exit_status: exit_status
    }

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
        last_exit_status: {:crashed, reason}
    }

    pop_pending(new_state)
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
      write_outbox_reply(state, reply, to)
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

      is_binary(from = Map.get(meta, "from")) and from == "director" ->
        {:error, :director_reply_skipped}

      is_binary(from = Map.get(meta, "from")) and from != "" ->
        {:ok, "agent:#{from}"}

      true ->
        {:error, :no_reply_target}
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

  defp resolve_task(state, _trigger, nil) do
    call_inbox_scan(state)
  end

  # Call the inbox-scan fun compatibly with both the historical 1-arity
  # `(spec)` signature (common in existing tests) and the new 2-arity
  # `(spec, base)` signature — state.base replaces the prior
  # hardcoded `Path.expand("~/.glorbo")` call inside default_inbox_scan
  # (TODO.md High #3).
  defp call_inbox_scan(%{inbox_scan_fun: fun, spec: spec, base: base}) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 1} -> fun.(spec)
      {:arity, 2} -> fun.(spec, base)
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
    String.starts_with?(rel_path, "agents/#{slug}/inbox/")
  end

  defp inbox_event_write?(events) when is_list(events),
    do: Enum.any?(events, &(&1 in [:created, :modified]))

  defp inbox_event_write?(_), do: false

  # Default inbox scanner: pick the oldest unread .md file under
  # agents/<slug>/inbox/ and return a task map. Returns nil when the
  # inbox is empty. Directories walked lazily; never reads the whole
  # inbox into memory. Called from resolve_task/3 (explicit wake/3) and
  # from handle_inbox_wake/1 (PubSub :file_event path).
  defp default_inbox_scan(%_{} = spec, base) when is_binary(base) do
    inbox_dir = Path.join([base, "companies", spec.company, "agents", spec.slug, "inbox"])

    with true <- File.dir?(inbox_dir),
         [oldest_path | _] <- list_inbox_md_files(inbox_dir) do
      %{
        task_id: Path.basename(oldest_path, ".md"),
        task_path: Path.relative_to(oldest_path, Path.join([base, "companies", spec.company])),
        prompt: read_or_empty(oldest_path),
        trigger: :inbox
      }
    else
      _ -> nil
    end
  end

  defp list_inbox_md_files(inbox_dir) do
    # Walk top-level + one subdir deep (`from-<sender>/*.md`,
    # `mentions/*.md`, `rejections/*.md`) — Router writes under these.
    direct = md_files_in(inbox_dir)

    sub_dirs_files =
      inbox_dir
      |> File.ls()
      |> case do
        {:ok, entries} -> entries
        _ -> []
      end
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
