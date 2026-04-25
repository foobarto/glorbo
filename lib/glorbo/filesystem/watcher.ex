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
    * `"company:<co>:channels"` for `channels/*` paths (roll-up kept for
      Phase 3 compat + CompanyLive's channel-list surface)

  `audit/*` paths are NOT broadcast — the sole writer of audit files is
  `Glorbo.Company.AuditLog`, and broadcasting would risk self-feedback
  loops from audit-writing subscribers.

  The broadcast is ADDITIVE: existing inline dispatch (Reindex.mark_dirty,
  Logger.debug) is preserved unchanged so Phase 2's D-33 contract is not
  broken. Router subscribes to `company:<co>:outbox` (and other paths as
  needed); Gate subscribes to `company:<co>:projects`; Agent.Server wake
  hooks subscribe to `company:<co>:inbox`.

  ## Phase 4 Wave 0 topic additions (Plan 04-01)

  In addition to the Plan 03-05 topics above, the watcher now emits:

    * `"company:<co>:agents:<slug>:stdout"` for `agents/<slug>/stdout.log`
      (StdoutStreamer subscribers read this — but StdoutStreamer polls
      the file directly since inotify carries no bytes; this topic is
      primarily for downstream observers that want "a new line landed").
    * `"company:<co>:agents:<slug>:wake"` for `agents/<slug>/state/wake-request.md`
      (Agent.Server's 4th wake trigger — Director-initiated wake via
      `GlorboWeb.Actions.wake_agent/3`).
    * `"company:<co>:channels:<slug>"` per-channel topic for
      `channels/<slug>.md` — ChannelLive subscribes to exactly one
      channel-slug topic per mount. Emitted IN ADDITION TO the
      generic `"company:<co>:channels"` roll-up (dual-broadcast is
      cheap and preserves Phase 3's W5 test contract).

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

  @doc """
  `:via` tuple for this watcher's registered name.

  Keyed under `Glorbo.Agent.Registry` with `{:company_child, company, :file_watcher}`
  — same shape as every other per-company child (GEP-12). Prior
  implementation used `{:global, {:glorbo_watcher, company}}`; switched
  to the project-wide Registry convention for consistency.
  """
  @spec via(String.t()) ::
          {:via, Registry, {module(), {:company_child, String.t(), :file_watcher}}}
  def via(company) when is_binary(company) do
    {:via, Registry, {Glorbo.Agent.Registry, {:company_child, company, :file_watcher}}}
  end

  @impl GenServer
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    company_dir = Path.join([base, "companies", company])
    File.mkdir_p!(company_dir)

    {pid, backend} = start_backend(company_dir)
    FileSystem.subscribe(pid)
    # WR-15: monitor the inotify subprocess so we stop (not silently idle)
    # when it dies — e.g. when fs.inotify.max_user_watches is exceeded.
    fs_ref = Process.monitor(pid)

    if backend == :fs_poll do
      Logger.warning(
        "[watcher/#{company}] inotifywait not found — falling back to polling (~2s). " <>
          "Performance hit on large trees; install inotify-tools for realtime updates."
      )
    end

    {:ok,
     %{
       company: company,
       base: base,
       dir: company_dir,
       fs_pid: pid,
       fs_ref: fs_ref,
       backend: backend,
       pending: %{},
       pubsub: Keyword.get(opts, :pubsub, Glorbo.PubSub),
       reindex_fun: Keyword.get(opts, :reindex_fun, &Reindex.mark_dirty/2)
     }}
  end

  # Try the platform default (inotify on Linux). If that fails (no
  # inotifywait on PATH, or non-Linux dev with no supported backend),
  # fall back to the always-available FSPoll. Users on broken kernels
  # or minimal containers get a slower, noisier but functional path.
  defp start_backend(company_dir) do
    case FileSystem.start_link(dirs: [company_dir], recursive: true) do
      {:ok, pid} ->
        {pid, default_backend()}

      {:error, _reason} ->
        {:ok, pid} =
          FileSystem.start_link(
            dirs: [company_dir],
            recursive: true,
            backend: :fs_poll,
            backend_opts: [interval: 2_000]
          )

        {pid, :fs_poll}
    end
  end

  defp default_backend do
    case :os.type() do
      {:unix, :linux} -> :fs_inotify
      {:unix, :darwin} -> :fs_mac
      {:win32, _} -> :fs_windows
      _ -> :fs_poll
    end
  end

  @doc """
  Return the Watcher's active backend for UI hints. Cheap GenServer
  call — used by the statusbar to flag "polling" mode.
  """
  @spec backend(GenServer.server()) :: atom()
  def backend(server), do: GenServer.call(server, :backend)

  @impl GenServer
  def handle_call(:backend, _from, state) do
    {:reply, state.backend, state}
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
    # GEP-33 Phase 3: feed manual-edit events into the history
    # watcher-bridge. The bridge's own tracked? predicate filters
    # out scope-excluded paths, so we don't gate on classify here.
    # Cast — fire-and-forget; the bridge handles a missing
    # registered name silently.
    Glorbo.HomeHistory.WatcherBridge.observe(company, rel)
  end

  defp classify(rel) do
    cond do
      # Phase 4 Wave 0: stdout and wake-request classifications must come
      # BEFORE the generic inbox/outbox checks because the same "agents/"
      # prefix applies — `cond` matches top-down.
      String.starts_with?(rel, "agents/") and String.ends_with?(rel, "/stdout.log") ->
        :stdout

      String.starts_with?(rel, "agents/") and String.contains?(rel, "/state/wake-request") ->
        :wake

      String.starts_with?(rel, "agents/") and String.contains?(rel, "/inbox/") ->
        :inbox

      String.starts_with?(rel, "agents/") and String.contains?(rel, "/outbox/") ->
        :outbox

      # Workspace is the agent's scratchpad — CLI caches, build artifacts,
      # work-in-progress files. None of it belongs in the SQLite reindex
      # (FS-03: SQLite mirrors markdown-under-projects + agent/company
      # identity, not workspace bytes). Classify as :ignore so we don't
      # fire `mark_dirty` for every jsonl claude-code writes to its
      # .cache dir. Matches both the workspace dir itself and anything
      # beneath it.
      String.starts_with?(rel, "agents/") and
          (String.ends_with?(rel, "/workspace") or String.contains?(rel, "/workspace/")) ->
        :ignore

      String.starts_with?(rel, "audit/") ->
        :audit

      String.starts_with?(rel, "channels/") ->
        :channels

      String.starts_with?(rel, "projects/") ->
        :projects

      # GEP-28: `proposals/<id>.md` — direct children only, matching
      # `FileSpec.ProposalMd`'s `/proposals/[^/]+\\.md\\z` path spec. Nested
      # paths (e.g. `proposals/archive/foo.md`) stay on `:other` so they
      # don't masquerade as proposals in PubSub.
      proposals_direct_child?(rel) ->
        :proposals

      true ->
        :other
    end
  end

  defp proposals_direct_child?(rel) do
    case Path.split(rel) do
      ["proposals", file] -> String.ends_with?(file, ".md")
      _ -> false
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

  defp inline_dispatch(:stdout, company, _path, rel, _state),
    do: Logger.debug("[watcher/#{company}] stdout event #{rel} (Phase 4 target)")

  defp inline_dispatch(:wake, company, _path, rel, _state),
    do: Logger.debug("[watcher/#{company}] wake-request event #{rel} (Phase 4 target)")

  defp inline_dispatch(:projects, company, path, _rel, state),
    do: state.reindex_fun.(company, path)

  defp inline_dispatch(:proposals, company, path, _rel, state),
    do: state.reindex_fun.(company, path)

  defp inline_dispatch(:ignore, _company, _path, _rel, _state), do: :ok

  defp inline_dispatch(:other, company, path, _rel, state),
    do: state.reindex_fun.(company, path)

  # Broadcasts to one topic (single string) or multiple topics (list).
  # Dual-broadcast is used for channels/ so the Phase 3 generic topic
  # and the Phase 4 per-slug topic both fire from the same event.
  defp maybe_broadcast(nil, _company, _rel, _events, _state), do: :ok

  defp maybe_broadcast(topics, company, rel, events, state) when is_list(topics) do
    Enum.each(topics, &maybe_broadcast(&1, company, rel, events, state))
  end

  defp maybe_broadcast(topic, company, rel, events, state) when is_binary(topic) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      "company:#{company}:#{topic}",
      {:file_event, rel, events}
    )
  end

  # Map a relative path to a PubSub topic suffix (string), a list of
  # suffixes (dual-broadcast), or `nil` for no-broadcast.
  defp pubsub_topic_for(rel) do
    cond do
      String.starts_with?(rel, "audit/") -> nil
      String.starts_with?(rel, "agents/") -> agents_topic_for(rel)
      String.starts_with?(rel, "projects/") -> "projects"
      String.starts_with?(rel, "channels/") -> channels_topic_for(rel)
      proposals_direct_child?(rel) -> "proposals"
      true -> nil
    end
  end

  # `agents/...` path → topic string/nil. Split out of pubsub_topic_for/1
  # to keep credo's cyclomatic complexity budget.
  defp agents_topic_for(rel) do
    cond do
      # agents/<slug>/stdout.log → per-agent stdout topic.
      String.ends_with?(rel, "/stdout.log") ->
        case Path.split(rel) do
          ["agents", slug, "stdout.log"] -> "agents:#{slug}:stdout"
          _ -> nil
        end

      # agents/<slug>/state/wake-request.md → Director wake trigger.
      String.contains?(rel, "/state/wake-request") ->
        case Path.split(rel) do
          ["agents", slug, "state", _file] -> "agents:#{slug}:wake"
          _ -> nil
        end

      # agents/<slug>/AGENT.md or agent.md → hot-reload spec. Re-broadcast
      # on `inbox` so the existing Agent.Server subscription picks it up
      # and re-parses the spec from disk.
      String.ends_with?(rel, "/AGENT.md") or String.ends_with?(rel, "/agent.md") ->
        "inbox"

      String.contains?(rel, "/inbox/") ->
        "inbox"

      String.contains?(rel, "/outbox/") ->
        "outbox"

      true ->
        nil
    end
  end

  # Phase 4 Wave 0: dual-broadcast on channels/ — per-slug topic for
  # ChannelLive (new) + generic `channels` topic preserved from Phase 3
  # (W5 regression safety). Per-slug string first so subscribers are
  # ordered deterministically but order is not contractually observable.
  defp channels_topic_for(rel) do
    case Path.split(rel) do
      ["channels", file] -> ["channels:#{Path.basename(file, ".md")}", "channels"]
      _ -> "channels"
    end
  end
end
