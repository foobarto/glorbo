defmodule Glorbo.Filesystem.Watcher do
  @moduledoc """
  Per-company inotify watcher (D-30). Debounces (100ms, D-32), routes by
  path prefix (D-33). Started under `Glorbo.Company.Supervisor`.

  Message flow:

      FileSystem.subscribe/1
        → handle_info({:file_event, _, {path, evs}})
        → if evs ⊆ [:created, :modified, :deleted, :removed]:
            Process.send_after(self(), {:flush, path}, 100ms)
        → handle_info({:flush, path})
        → dispatch_by_prefix/5

  Route table (D-33):

    * `agents/<name>/inbox/*`   → Phase 3 Router/Agent.Server target + PubSub broadcast
    * `agents/<name>/outbox/*`  → Phase 3 Router target + PubSub broadcast
    * `audit/*`                 → audit-observer (logged only — AuditLog is the sole writer, D-24)
    * `channels/*`              → Phase 4 channel consumer + PubSub broadcast
    * `projects/*`              → Phase 3 Approvals.Gate target + PubSub broadcast + Reindex
    * everything else           → `Glorbo.Filesystem.Reindex.mark_dirty/2`

  ## Plan 03-05 PubSub extension

  After the inline dispatch (Reindex / Logger), the watcher additionally
  broadcasts `{:file_event, rel_path, events}` on `Phoenix.PubSub` topics
  scoped to the company:

    * `"company:<co>:inbox"`    for `agents/*/inbox/*` paths
    * `"company:<co>:outbox"`   for `agents/*/outbox/*` paths
    * `"company:<co>:projects"` for `projects/**/*.md` paths
    * `"company:<co>:channels"` for `channels/*` paths

  `audit/*` paths are NOT broadcast — the sole writer of audit files is
  `Glorbo.Company.AuditLog`, and broadcasting would risk self-feedback
  loops from audit-writing subscribers.

  The broadcast is ADDITIVE: existing inline dispatch (Reindex.mark_dirty,
  Logger.debug) is preserved unchanged so Phase 2's D-33 contract is not
  broken. Router subscribes to `company:<co>:outbox` (and other paths as
  needed); Gate subscribes to `company:<co>:projects`; Agent.Server wake
  hooks subscribe to `company:<co>:inbox`.

  Crash isolation (CLAUDE.md invariant): each company has exactly one
  Watcher process; a crash restarts only that watcher.
  """
  use GenServer
  require Logger

  alias Glorbo.Filesystem.Reindex

  @debounce_ms 100
  @interesting_events [:created, :modified, :deleted, :removed]
  # WR-07: cap the debounce map so a buggy/malicious actor writing N
  # distinct paths can't unboundedly grow state.pending.
  @max_pending 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    company = Keyword.fetch!(opts, :company)
    name = Keyword.get(opts, :name, via(company))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Process registration name for the watcher of `company`."
  @spec via(String.t()) :: {:global, {:glorbo_watcher, String.t()}}
  def via(company), do: {:global, {:glorbo_watcher, company}}

  @impl GenServer
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    company_dir = Path.join([base, "companies", company])
    File.mkdir_p!(company_dir)

    {:ok, pid} = FileSystem.start_link(dirs: [company_dir], recursive: true)
    FileSystem.subscribe(pid)
    # WR-15: monitor the inotify subprocess so we stop (not silently idle)
    # when it dies — e.g. when fs.inotify.max_user_watches is exceeded.
    fs_ref = Process.monitor(pid)

    {:ok,
     %{
       company: company,
       base: base,
       dir: company_dir,
       fs_pid: pid,
       fs_ref: fs_ref,
       pending: %{},
       pubsub: Keyword.get(opts, :pubsub, Glorbo.PubSub),
       reindex_fun: Keyword.get(opts, :reindex_fun, &Reindex.mark_dirty/2)
     }}
  end

  @impl GenServer
  def handle_info({:file_event, _pid, {path, events}}, state) do
    cond do
      not Enum.any?(events, &(&1 in @interesting_events)) ->
        {:noreply, state}

      # WR-07: cap the pending map. If the cap is already reached AND this
      # path isn't already tracked, drop the event with a warning rather
      # than growing state unboundedly.
      map_size(state.pending) >= @max_pending and not Map.has_key?(state.pending, path) ->
        Logger.warning(
          "[watcher/#{state.company}] pending map at cap (#{@max_pending}); dropping event for #{path}"
        )

        {:noreply, state}

      true ->
        # Cancel prior timer for the same path (coalesce bursts, D-32).
        case Map.get(state.pending, path) do
          nil -> :ok
          {ref, _prev_events} -> Process.cancel_timer(ref)
        end

        ref = Process.send_after(self(), {:flush, path}, @debounce_ms)
        {:noreply, put_in(state.pending[path], {ref, events})}
    end
  end

  def handle_info({:flush, path}, state) do
    events =
      case Map.get(state.pending, path) do
        {_ref, evs} -> evs
        _ -> []
      end

    dispatch_by_prefix(state.company, state.dir, path, events, state)
    {:noreply, update_in(state.pending, &Map.delete(&1, path))}
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    Logger.warning("FileWatcher for #{state.company} received :stop")
    {:stop, :normal, state}
  end

  # WR-15: treat FileSystem subprocess DOWN as fatal — we'd otherwise sit
  # happily while events never arrive (e.g. inotify watch-limit hit).
  def handle_info({:DOWN, ref, :process, pid, reason}, %{fs_ref: ref, fs_pid: pid} = state) do
    Logger.error("[watcher/#{state.company}] FileSystem process died: #{inspect(reason)}")

    {:stop, {:filesystem_down, reason}, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # D-33: path-prefix routing + Plan 03-05 PubSub broadcast (additive).
  defp dispatch_by_prefix(company, base_dir, path, events, state) do
    rel = Path.relative_to(path, base_dir)

    inline_dispatch(classify(rel), company, path, rel, state)
    maybe_broadcast(pubsub_topic_for(rel), company, rel, events, state)
  end

  defp classify(rel) do
    cond do
      String.starts_with?(rel, "agents/") and String.contains?(rel, "/inbox/") -> :inbox
      String.starts_with?(rel, "agents/") and String.contains?(rel, "/outbox/") -> :outbox
      String.starts_with?(rel, "audit/") -> :audit
      String.starts_with?(rel, "channels/") -> :channels
      String.starts_with?(rel, "projects/") -> :projects
      true -> :other
    end
  end

  defp inline_dispatch(:inbox, company, _path, rel, _state),
    do: Logger.debug("[watcher/#{company}] inbox event #{rel} (Phase 3 routing target)")

  defp inline_dispatch(:outbox, company, _path, rel, _state),
    do: Logger.debug("[watcher/#{company}] outbox event #{rel} (Phase 3 routing target)")

  defp inline_dispatch(:audit, company, _path, rel, _state),
    do: Logger.debug("[watcher/#{company}] audit event #{rel} (observed)")

  defp inline_dispatch(:channels, company, _path, rel, _state),
    do: Logger.debug("[watcher/#{company}] channel event #{rel} (Phase 4 target)")

  defp inline_dispatch(:projects, company, path, _rel, state),
    do: state.reindex_fun.(company, path)

  defp inline_dispatch(:other, company, path, _rel, state),
    do: state.reindex_fun.(company, path)

  defp maybe_broadcast(nil, _company, _rel, _events, _state), do: :ok

  defp maybe_broadcast(topic, company, rel, events, state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      "company:#{company}:#{topic}",
      {:file_event, rel, events}
    )
  end

  # Map a relative path to a PubSub topic suffix or `nil` for no-broadcast.
  defp pubsub_topic_for(rel) do
    cond do
      String.starts_with?(rel, "audit/") -> nil
      String.starts_with?(rel, "agents/") and String.contains?(rel, "/inbox/") -> "inbox"
      String.starts_with?(rel, "agents/") and String.contains?(rel, "/outbox/") -> "outbox"
      String.starts_with?(rel, "projects/") -> "projects"
      String.starts_with?(rel, "channels/") -> "channels"
      true -> nil
    end
  end
end
