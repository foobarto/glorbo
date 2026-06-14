defmodule Glorbo.Ollama.Daemon do
  @moduledoc """
  Lifecycle manager for the local Ollama daemon (GEP-67, Phase 2).

  A supervised singleton GenServer (GEP-67 D8) owning a small state
  machine over three modes:

    * `:external` — a daemon Glorbo did NOT start is answering on
      `:11434` (systemd `--user`, a manual `ollama serve`, or a prior
      run). Glorbo adopts and observes it; it will never stop or restart
      it (D2 — "never stop what we didn't start").
    * `:managed` — Glorbo started `ollama serve` itself, as a
      `MuonTrap.Daemon` child whose process group is bound to the BEAM,
      so it dies when glorbo exits (D3). Stop/Restart act only here.
    * `:down` — nothing running (or a managed daemon that exhausted its
      restart budget; reason surfaced).

  **Adopt-if-running, start-if-not (D2).** `ensure_running/1` probes
  first: an external daemon is adopted; only when none answers does
  Glorbo spawn its own. An adopted external daemon that vanishes
  mid-session re-probes to `:down` and is NOT auto-replaced (that would
  fight a service the user controls).

  Nothing is probed or spawned at `init` — the manager is inert until the
  Director acts (the `/providers` panel), honouring GEP-8 D13's caution
  against boot-time host probes. The probe and spawn are injectable
  (`:probe_fun`, `:spawn_fun`, `:stop_fun`) so the state machine is fully
  testable without a real Ollama or a real spawned process.
  """

  use GenServer

  require Logger

  alias Glorbo.Ollama.Detect

  # Bounded restart budget for a crashing managed daemon (D2). After this
  # many consecutive respawns the manager parks at `:down` rather than
  # hot-looping; the Director restarts it explicitly.
  @max_restarts 3

  @type mode :: :down | :external | :managed
  @type status :: %{
          mode: mode(),
          reachable?: boolean(),
          reason: term() | nil,
          restarts: non_neg_integer()
        }

  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Current daemon mode + reachability (re-probes unless we own a managed daemon)."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Ensure a daemon is available: adopt an external one if running, else
  spawn a managed one. Returns the resulting mode. Never spawns over an
  external daemon.
  """
  @spec ensure_running(GenServer.server()) :: {:ok, mode()} | {:error, term()}
  def ensure_running(server \\ __MODULE__), do: GenServer.call(server, :ensure_running)

  @doc "Stop the managed daemon. Refused (`{:error, :not_managed}`) for an external/absent one."
  @spec stop(GenServer.server()) :: {:ok, :down} | {:error, :not_managed}
  def stop(server \\ __MODULE__), do: GenServer.call(server, :stop)

  @doc "Restart the managed daemon. Refused for an external/absent one."
  @spec restart(GenServer.server()) :: {:ok, mode()} | {:error, term()}
  def restart(server \\ __MODULE__), do: GenServer.call(server, :restart)

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      mode: :down,
      reason: nil,
      child_pid: nil,
      child_ref: nil,
      restarts: 0,
      probe_fun: Keyword.get(opts, :probe_fun, &Detect.daemon_reachable?/0),
      spawn_fun: Keyword.get(opts, :spawn_fun, &default_spawn/0),
      stop_fun: Keyword.get(opts, :stop_fun, &default_stop/1)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    # We trust our own managed child's mode; for :external/:down re-probe
    # so an externally-(dis)appearing daemon is reflected live.
    state = if state.mode == :managed, do: state, else: reconcile_external(state)
    {:reply, snapshot(state), state}
  end

  def handle_call(:ensure_running, _from, %{mode: :managed} = state) do
    {:reply, {:ok, :managed}, state}
  end

  def handle_call(:ensure_running, _from, state) do
    if probe(state) do
      {:reply, {:ok, :external}, %{state | mode: :external, reason: nil}}
    else
      case spawn_managed(state) do
        {:ok, state} -> {:reply, {:ok, :managed}, state}
        {:error, reason, state} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:stop, _from, %{mode: :managed} = state) do
    {:reply, {:ok, :down}, teardown_child(state, nil)}
  end

  def handle_call(:stop, _from, state), do: {:reply, {:error, :not_managed}, state}

  def handle_call(:restart, _from, %{mode: :managed} = state) do
    state = teardown_child(state, nil)

    case spawn_managed(%{state | restarts: 0}) do
      {:ok, state} -> {:reply, {:ok, :managed}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:restart, _from, state), do: {:reply, {:error, :not_managed}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{child_ref: ref, mode: :managed} = state) do
    # Our managed daemon exited. Bounded respawn, then park at :down with
    # the reason surfaced — never a hot restart loop.
    state = %{state | child_pid: nil, child_ref: nil}

    if state.restarts < @max_restarts do
      Logger.warning(
        "ollama daemon exited (#{inspect(reason)}); respawn #{state.restarts + 1}/#{@max_restarts}"
      )

      case spawn_managed(%{state | restarts: state.restarts + 1}) do
        {:ok, state} -> {:noreply, state}
        {:error, _reason, state} -> {:noreply, state}
      end
    else
      Logger.error("ollama daemon exhausted its restart budget; parking at :down")
      {:noreply, %{state | mode: :down, reason: {:restart_budget_exhausted, reason}}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{mode: :managed, child_pid: pid} = state) when is_pid(pid) do
    # On glorbo shutdown, stop the daemon we started (MuonTrap also binds
    # the process group to the BEAM, but stopping cleanly avoids relying
    # solely on the group kill).
    state.stop_fun.(pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp probe(state), do: state.probe_fun.() == true

  # For :external/:down, reflect the live daemon: reachable → :external,
  # else → :down (the external-vanished case; never auto-respawn).
  defp reconcile_external(state) do
    if probe(state) do
      %{state | mode: :external, reason: nil}
    else
      %{state | mode: :down, reason: nil}
    end
  end

  defp spawn_managed(state) do
    case state.spawn_fun.() do
      {:ok, pid} when is_pid(pid) ->
        ref = Process.monitor(pid)
        {:ok, %{state | mode: :managed, reason: nil, child_pid: pid, child_ref: ref}}

      {:error, reason} ->
        {:error, reason, %{state | mode: :down, reason: reason, child_pid: nil, child_ref: nil}}
    end
  end

  # Tear down the managed child intentionally: drop the monitor (flushing
  # any pending :DOWN so it can't trigger a respawn), stop it, go :down.
  defp teardown_child(%{child_ref: ref, child_pid: pid} = state, reason) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])
    if is_pid(pid), do: state.stop_fun.(pid)
    %{state | mode: :down, reason: reason, child_pid: nil, child_ref: nil, restarts: 0}
  end

  defp snapshot(state) do
    %{
      mode: state.mode,
      reachable?: state.mode in [:external, :managed],
      reason: state.reason,
      restarts: state.restarts
    }
  end

  # Real spawn: `ollama serve` as a MuonTrap.Daemon child. MuonTrap binds
  # the process group to the BEAM, so the daemon dies when glorbo exits
  # (D3). `ollama` is run by name off PATH (the user's install); argv is
  # discrete (no shell).
  defp default_spawn do
    case Detect.binary_path() do
      path when is_binary(path) ->
        MuonTrap.Daemon.start_link(path, ["serve"], stderr_to_stdout: true)

      _ ->
        {:error, :not_installed}
    end
  end

  defp default_stop(pid), do: GenServer.stop(pid, :normal, 5_000)
end
