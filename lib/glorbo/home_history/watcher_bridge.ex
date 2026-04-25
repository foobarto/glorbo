defmodule Glorbo.HomeHistory.WatcherBridge do
  @moduledoc """
  GEP-33 Phase 3 — bridge filesystem-watcher events into history
  commits as `External` (manual edit) provenance.

  Marked transactions (`Tx.with_tx`) cover paths the host-side
  writers know about. Anything else that mutates a tracked-scope
  path — Director hand-edit, an external `git apply`, a script
  that drops a file in `companies/<co>/braindump/` — flows
  through this bridge.

  ## Pipeline

    1. `Glorbo.Filesystem.Watcher` calls `observe/3` from its
       `inline_dispatch/5` for every path event with a
       potentially-tracked classification.
    2. `observe/3` runs `HomeHistory.tracked?/2` against the
       per-company `companies/<co>/<rel>` join. Paths that fail
       the predicate are dropped.
    3. Tracked paths land in a debounce buffer keyed on
       `{company, rel_path}`. Each new event resets the
       per-key 500 ms inactivity timer.
    4. When the timer fires, `commit_marked/3` runs with
       `actor: :external`, action `external.edit`,
       target = the path. The path was already on disk
       (the writer that authored it landed it before the
       watcher fired), so the existence + diff filters in
       `commit_marked/3` decide whether a commit lands or
       it's a no-op.

  ## Why `commit_marked/3` directly, not `Tx.with_tx`

  `Tx.with_tx` is for **logical operations** that touch
  multiple paths atomically. A manual edit is one path,
  observed independently, with no "transaction" to coalesce.
  Calling `commit_marked/3` directly is simpler and avoids
  the begin/cancel cycle. Multi-path edits (e.g., a Director
  saves three files in a hand-edit burst) coalesce naturally
  because each path opens its own debounce timer; if they
  fire close together, the resulting commits are still
  correct, just split.

  ## "Already covered by a marked tx?"

  A marked tx (`Tx.with_tx`) writes a path; the watcher then
  fires for the same path. Without coordination the bridge
  would re-commit the same change as `External`. Two factors
  make this safe in practice:

    * The marked tx debounce (500 ms) and the bridge debounce
      (also 500 ms) run independently; the marked tx's
      `commit_marked/3` typically lands first because it's
      synchronous from the writer's perspective. By the time
      the bridge fires its debounce, HEAD already contains
      the change → the bridge's `commit_marked/3` sees no
      diff and returns `{:ok, %{committed: 0}}`.
    * If timing flips and the bridge fires first, the
      External commit lands; the marked tx then runs against
      the now-updated HEAD and sees no diff. Either way,
      provenance is honest about who got there first.

  Properly distinguishing "this path was just marked by a tx,
  skip the External commit" requires sharing tx state with
  the bridge — out of scope for the minimal Phase 3. The
  diff-as-arbiter approach above is sufficient because the
  no-diff branch in `commit_marked/3` is a clean no-op.
  """

  use GenServer
  require Logger

  alias Glorbo.HomeHistory

  @default_debounce_ms 500

  # Public API ---------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Watcher-side entry point. `company` is the slug; `rel_path` is
  relative to `companies/<company>/`. Cast — fire-and-forget.
  """
  @spec observe(String.t(), Path.t(), keyword()) :: :ok
  def observe(company, rel_path, opts \\ [])
      when is_binary(company) and is_binary(rel_path) do
    GenServer.cast(server(opts), {:observe, company, rel_path})
  catch
    :error, :badarg -> :ok
    :exit, _ -> :ok
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  # GenServer ----------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      base: Keyword.get(opts, :base),
      debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms),
      # Map of {company, rel_path} → timer_ref
      timers: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:observe, company, rel_path}, state) do
    base = state.base || HomeHistory.default_base!()
    abs_path = Path.join([base, "companies", company, rel_path])

    if HomeHistory.tracked?(abs_path, base) do
      key = {company, rel_path}
      maybe_cancel(state.timers[key])

      ref =
        Process.send_after(
          self(),
          {:fire, company, rel_path, abs_path},
          state.debounce_ms
        )

      {:noreply, %{state | timers: Map.put(state.timers, key, ref)}}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:fire, company, rel_path, abs_path}, state) do
    key = {company, rel_path}
    state = %{state | timers: Map.delete(state.timers, key)}

    meta = %{
      actor: :external,
      action: "external.edit",
      target: "companies/#{company}/#{rel_path}",
      source: "watcher"
    }

    base_opt = if state.base, do: [base: state.base], else: []

    case HomeHistory.commit_marked([abs_path], meta, base_opt) do
      {:ok, %{sha: sha, committed: n}} when sha != "" ->
        Logger.debug(
          "home_history.watcher: external commit company=#{company} path=#{rel_path} sha=#{sha} n=#{n}"
        )

      {:ok, %{committed: 0}} ->
        :ok

      {:error, :not_initialised} ->
        :ok

      {:error, err} ->
        Logger.warning(
          "home_history.watcher: commit failed company=#{company} path=#{rel_path} err=#{inspect(err)}"
        )
    end

    {:noreply, state}
  end

  defp maybe_cancel(nil), do: :ok
  defp maybe_cancel(ref), do: Process.cancel_timer(ref)
end
