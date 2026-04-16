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
        → dispatch_by_prefix/4

  Route table (D-33):

    * `agents/<name>/inbox/*`   → Phase 3 agent-wake target (logged here)
    * `agents/<name>/outbox/*`  → Phase 3 agent-wake target (logged here)
    * `audit/*`                 → audit-observer (logged only — AuditLog is the sole writer, D-24)
    * `channels/*`              → Phase 4 channel-update target (logged here)
    * everything else           → `Glorbo.Filesystem.Reindex.mark_dirty/2`

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
          ref -> Process.cancel_timer(ref)
        end

        ref = Process.send_after(self(), {:flush, path}, @debounce_ms)
        {:noreply, put_in(state.pending[path], ref)}
    end
  end

  def handle_info({:flush, path}, state) do
    dispatch_by_prefix(state.company, state.dir, path, state.reindex_fun)
    {:noreply, update_in(state.pending, &Map.delete(&1, path))}
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    Logger.warning("FileWatcher for #{state.company} received :stop")
    {:stop, :normal, state}
  end

  # WR-15: treat FileSystem subprocess DOWN as fatal — we'd otherwise sit
  # happily while events never arrive (e.g. inotify watch-limit hit).
  def handle_info({:DOWN, ref, :process, pid, reason}, %{fs_ref: ref, fs_pid: pid} = state) do
    Logger.error(
      "[watcher/#{state.company}] FileSystem process died: #{inspect(reason)}"
    )

    {:stop, {:filesystem_down, reason}, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # D-33: path-prefix routing.
  defp dispatch_by_prefix(company, base_dir, path, reindex_fun) do
    rel = Path.relative_to(path, base_dir)

    cond do
      String.starts_with?(rel, "agents/") and String.contains?(rel, "/inbox/") ->
        Logger.debug("[watcher/#{company}] inbox event #{rel} (Phase 3 routing target)")
        :ok

      String.starts_with?(rel, "agents/") and String.contains?(rel, "/outbox/") ->
        Logger.debug("[watcher/#{company}] outbox event #{rel} (Phase 3 routing target)")
        :ok

      String.starts_with?(rel, "audit/") ->
        Logger.debug("[watcher/#{company}] audit event #{rel} (observed)")
        :ok

      String.starts_with?(rel, "channels/") ->
        Logger.debug("[watcher/#{company}] channel event #{rel} (Phase 4 target)")
        :ok

      true ->
        reindex_fun.(company, path)
    end
  end
end
