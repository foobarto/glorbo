defmodule Glorbo.HomeHistory.Tx do
  @moduledoc """
  Phase 2b — `begin/mark_path/flush/cancel` GenServer that buffers
  one logical operation's path mutations into a single
  `Glorbo.HomeHistory.commit_marked/3` call under the GEP-33 §6.1
  debounce window.

  Phase 2a-1 shipped the synchronous primitive; this server wraps
  it so a logical Glorbo operation that touches multiple files
  (task approval = task file + audit append, channel send = chat
  log + audit append, etc.) lands as one commit instead of one
  per inode event.

  Lifecycle of one tx:

      {:ok, tx_id} = Tx.begin(meta)
      :ok = Tx.mark_path(tx_id, "companies/acme/tasks/foo.md")
      :ok = Tx.mark_path(tx_id, "companies/acme/audit/2026-04.jsonl")
      {:ok, %{sha: _, committed: 2}} = Tx.flush(tx_id)

  Or — letting auto-flush handle it:

      {:ok, tx_id} = Tx.begin(meta)
      :ok = Tx.mark_path(tx_id, path1)
      :ok = Tx.mark_path(tx_id, path2)
      # No call. After §6.1 inactivity window the server flushes
      # automatically; the caller is fire-and-forget.

  ## Debounce semantics (§6.1)

    * **Inactivity window** — default 500 ms. Each `mark_path/2`
      resets it. When the window elapses without a new mark, the
      tx auto-flushes.
    * **Hard cap** — default 2 000 ms from `begin/1`. A long
      sequence of `mark_path/2` calls still flushes at the cap so
      "half-open transactions" stay bounded.
    * Explicit `flush/1` short-circuits both timers and commits
      synchronously.
    * `cancel/1` drops the tx without committing.

  Both windows are configurable via `start_link/1` options
  (`:debounce_ms`, `:hard_cap_ms`) so tests can run faster than
  real time without changing production thresholds.

  ## Failure mode (§12.3)

  Auto-flush is fire-and-forget: a commit failure logs a warning
  and drops the tx; the caller's authoritative file write already
  succeeded so the working tree remains correct. Explicit
  `flush/1` returns the underlying `{:error, _}` so the caller
  can decide what to do.

  ## "History disabled" path

  If `.git/` is absent at flush time (history not initialised),
  the server treats the flush as a clean no-op:
  `{:ok, %{sha: "", committed: 0, skipped: <paths>}}`. The
  `commit_marked/3` strict-mode `{:error, :not_initialised}` is
  translated here so Phase 2c callers can ignore the result
  uniformly.
  """

  use GenServer
  require Logger

  alias Glorbo.HomeHistory

  @default_debounce_ms 500
  @default_hard_cap_ms 2_000

  # Public API ---------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Open a new tx with the given `meta`. Returns the assigned
  `tx_id` (auto-generated if absent in `meta`). The hard-cap
  timer starts now.
  """
  @spec begin(HomeHistory.tx_meta(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def begin(meta, opts \\ []) when is_map(meta) do
    GenServer.call(server(opts), {:begin, meta})
  end

  @doc """
  Add a path to an open tx and reset the inactivity debounce
  timer. The path is staged + filtered against `tracked?/2` only
  at flush time, so callers don't need to pre-classify.
  """
  @spec mark_path(String.t(), Path.t(), keyword()) :: :ok
  def mark_path(tx_id, path, opts \\ []) when is_binary(tx_id) and is_binary(path) do
    GenServer.cast(server(opts), {:mark_path, tx_id, path})
  catch
    # Cast to an unregistered name raises ArgumentError; treat
    # missing Tx as feature-disabled and drop silently.
    :error, :badarg -> :ok
    :exit, _ -> :ok
  end

  @doc """
  Flush an open tx now: commit_marked is invoked synchronously
  with all paths accumulated so far. Tx is dropped from state
  whether the commit succeeded, failed, or was a no-op.
  """
  @spec flush(String.t(), keyword()) ::
          {:ok, HomeHistory.commit_result()} | {:error, term()}
  def flush(tx_id, opts \\ []) when is_binary(tx_id) do
    GenServer.call(server(opts), {:flush, tx_id})
  end

  @doc """
  Drop an open tx without committing. Safe to call on an
  unknown tx_id — returns `:ok` either way (idempotent).
  """
  @spec cancel(String.t(), keyword()) :: :ok
  def cancel(tx_id, opts \\ []) when is_binary(tx_id) do
    GenServer.cast(server(opts), {:cancel, tx_id})
  end

  @doc """
  Convenience: open a tx, run `fun`, and let the caller decide
  the outcome by what `fun` returns:

    * `{:ok, result}` — leave the tx open so the §6.1 debounce
      window auto-flushes after the caller stops marking paths.
      Returns `{:ok, result, tx_id}` so the caller can still
      `mark_path/2` or explicit-flush later if needed.
    * `{:error, _} = err` — `cancel/1` the tx and return `err`
      unchanged. Nothing reaches git. The caller's
      authoritative file write already may or may not have
      landed; the tx layer doesn't second-guess that.
    * Any other return — treated as `{:ok, value}`.
    * Raised exception — `cancel/1` then re-raise.

  This is the canonical Phase 2c entry point: writers wrap
  their `with`-chain in `with_tx/3` instead of hand-rolling the
  begin/cancel/leave-debounce-running plumbing.

  ## Resilience to missing Tx server

  If the Tx server is not registered (test envs that opt out,
  production homes where the supervisor child failed to boot,
  etc.), `with_tx/3` runs `fun` with a sentinel `tx_id` and
  treats all `mark_path/cancel/flush` calls as silent no-ops.
  This matches GEP-33 §12.3: a missing history layer must not
  turn writer success into writer failure.
  """
  @spec with_tx(HomeHistory.tx_meta(), (String.t() -> result), keyword()) :: result
        when result: term()
  def with_tx(meta, fun, opts \\ []) when is_map(meta) and is_function(fun, 1) do
    tx_id =
      case safe_begin(meta, opts) do
        {:ok, id} -> id
        {:disabled, sentinel} -> sentinel
      end

    try do
      case fun.(tx_id) do
        {:error, _} = err ->
          safe_cancel(tx_id, opts)
          err

        {:ok, result} ->
          {:ok, result, tx_id}

        other ->
          {:ok, other, tx_id}
      end
    catch
      kind, reason ->
        safe_cancel(tx_id, opts)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp safe_begin(meta, opts) do
    begin(meta, opts)
  catch
    :exit, {:noproc, _} -> {:disabled, "history-disabled-" <> sentinel_suffix()}
    :exit, :noproc -> {:disabled, "history-disabled-" <> sentinel_suffix()}
  end

  defp safe_cancel(tx_id, opts) do
    cancel(tx_id, opts)
  catch
    :exit, _ -> :ok
  end

  defp sentinel_suffix do
    :crypto.strong_rand_bytes(6) |> Base.encode32(case: :lower, padding: false)
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  # GenServer ----------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      base: Keyword.get(opts, :base),
      debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms),
      hard_cap_ms: Keyword.get(opts, :hard_cap_ms, @default_hard_cap_ms),
      txs: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:begin, meta}, _from, state) do
    tx_id = ensure_tx_id(meta)
    hard_ref = Process.send_after(self(), {:hard_cap_timeout, tx_id}, state.hard_cap_ms)

    tx = %{
      paths: MapSet.new(),
      meta: Map.put(meta, :tx_id, tx_id),
      debounce_ref: nil,
      hard_cap_ref: hard_ref
    }

    {:reply, {:ok, tx_id}, put_tx(state, tx_id, tx)}
  end

  def handle_call({:flush, tx_id}, _from, state) do
    case Map.fetch(state.txs, tx_id) do
      {:ok, tx} ->
        cancel_timers(tx)
        result = do_commit(tx, state)
        {:reply, result, drop_tx(state, tx_id)}

      :error ->
        {:reply, {:error, :unknown_tx}, state}
    end
  end

  @impl GenServer
  def handle_cast({:mark_path, tx_id, path}, state) do
    case Map.fetch(state.txs, tx_id) do
      {:ok, tx} ->
        if tx.debounce_ref, do: Process.cancel_timer(tx.debounce_ref)

        debounce_ref =
          Process.send_after(self(), {:debounce_timeout, tx_id}, state.debounce_ms)

        tx = %{tx | paths: MapSet.put(tx.paths, path), debounce_ref: debounce_ref}
        {:noreply, put_tx(state, tx_id, tx)}

      :error ->
        Logger.debug("home_history.tx: mark on unknown tx_id=#{inspect(tx_id)}")
        {:noreply, state}
    end
  end

  def handle_cast({:cancel, tx_id}, state) do
    case Map.fetch(state.txs, tx_id) do
      {:ok, tx} ->
        cancel_timers(tx)
        {:noreply, drop_tx(state, tx_id)}

      :error ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:debounce_timeout, tx_id}, state) do
    auto_flush(tx_id, :debounce, state)
  end

  def handle_info({:hard_cap_timeout, tx_id}, state) do
    auto_flush(tx_id, :hard_cap, state)
  end

  # Internals ----------------------------------------------------

  defp put_tx(state, tx_id, tx), do: %{state | txs: Map.put(state.txs, tx_id, tx)}
  defp drop_tx(state, tx_id), do: %{state | txs: Map.delete(state.txs, tx_id)}

  defp cancel_timers(tx) do
    if tx.debounce_ref, do: Process.cancel_timer(tx.debounce_ref)
    if tx.hard_cap_ref, do: Process.cancel_timer(tx.hard_cap_ref)
    :ok
  end

  defp auto_flush(tx_id, reason, state) do
    case Map.fetch(state.txs, tx_id) do
      {:ok, tx} ->
        cancel_timers(tx)

        case do_commit(tx, state) do
          {:ok, %{sha: sha, committed: n}} when sha != "" ->
            Logger.debug(
              "home_history.tx: auto-flushed tx_id=#{tx_id} reason=#{reason} sha=#{sha} committed=#{n}"
            )

          {:ok, %{committed: 0}} ->
            :ok

          {:error, err} ->
            Logger.warning(
              "home_history.tx: auto-flush failed tx_id=#{tx_id} reason=#{reason} err=#{inspect(err)}"
            )
        end

        {:noreply, drop_tx(state, tx_id)}

      :error ->
        # Already flushed/cancelled before the timer arrived.
        {:noreply, state}
    end
  end

  defp do_commit(tx, state) do
    paths = MapSet.to_list(tx.paths)
    opts = if state.base, do: [base: state.base], else: []

    case HomeHistory.commit_marked(paths, tx.meta, opts) do
      {:ok, _} = ok -> ok
      # Translate "history disabled" into a no-op so Phase 2c
      # callers can ignore the result without distinguishing
      # "feature off" from "actually nothing changed."
      {:error, :not_initialised} -> {:ok, %{sha: "", committed: 0, skipped: paths}}
      {:error, _} = err -> err
    end
  end

  defp ensure_tx_id(meta) do
    case Map.get(meta, :tx_id) do
      v when is_binary(v) and byte_size(v) > 0 ->
        v

      _ ->
        "history-" <>
          (:crypto.strong_rand_bytes(10) |> Base.encode32(case: :lower, padding: false))
    end
  end
end
