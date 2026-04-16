defmodule Glorbo.ContainerManager do
  @moduledoc """
  Manages the Podman container lifecycle for company runtimes.

  Phase 2 Plan 03 replaces the Phase-1 stub body with:

    * `ensure_image/1` — idempotent `podman pull` (no-op when the image
      already exists locally). Satisfies RT-02.
    * `start_container/2` — calls `Glorbo.Container.Invocation.build_argv/4`
      + `Glorbo.Container.Socket.ensure_dir!/2` + cleans stale sockets, then
      launches via `System.cmd` (ephemeral, RT-05) or `MuonTrap.Daemon`
      (persistent, D-13).
    * `stop_container/1` — `podman stop` wrapper.

  The `start_link/1` signature is preserved from Phase 1; the supervision
  tree keeps working without any change in `Glorbo.Application`.
  """
  use GenServer

  require Logger

  alias Glorbo.Container.{Invocation, Socket}

  @podman "podman"

  # ------ Public API ------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Ensure the named image is present locally. `podman pull`s it if not.
  Returns `:ok` or `{:error, term}`. Idempotent (D-19).

  CR-06: accepts an explicit `server` so alternate registrations (e.g. named
  test processes) can be reached. Defaults to the module-registered name.
  """
  @spec ensure_image(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def ensure_image(server \\ __MODULE__, image) do
    GenServer.call(server, {:ensure_image, image}, 60_000)
  end

  @doc """
  Launch a container for `(company, agent)`.

  Required opts:
    * `:agent` — agent name (Linux-user-safe identifier)

  Optional opts:
    * `:mode` — `:ephemeral` (default) or `:persistent`
    * `:base` — Glorbo home root (default `~/.glorbo`)

  Returns `{:ok, id_or_name}` / `{:error, term}`.
  """
  @spec start_container(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start_container(server \\ __MODULE__, company, opts) do
    GenServer.call(server, {:start_container, company, opts}, 30_000)
  end

  @spec stop_container(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def stop_container(server \\ __MODULE__, name) do
    GenServer.call(server, {:stop_container, name}, 15_000)
  end

  # ------ GenServer callbacks ------

  @impl GenServer
  def init(opts) do
    supervisor = Keyword.get(opts, :daemon_supervisor, Glorbo.Container.DaemonSupervisor)
    {:ok, %{daemons: %{}, daemon_supervisor: supervisor}}
  end

  @impl GenServer
  def handle_call({:ensure_image, image}, _from, state) do
    reply =
      case System.cmd(@podman, ["image", "exists", image], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {_, _} ->
          case System.cmd(@podman, ["pull", image], stderr_to_stdout: true) do
            {_, 0} -> :ok
            {output, code} -> {:error, {:pull_failed, code, output}}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:start_container, company, opts}, _from, state) do
    agent = Keyword.fetch!(opts, :agent)
    mode = Keyword.get(opts, :mode, :ephemeral)
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    extra_volumes = Keyword.get(opts, :extra_volumes, [])

    Socket.ensure_dir!(base, company)
    Socket.cleanup_stale(base, company, agent)
    # CR-03: best-effort remove any stale Podman container with the target
    # name so a SIGKILLed prior launch doesn't block the new one.
    pre_clean_container(company, agent)

    argv =
      Invocation.build_argv(company, agent, mode,
        base: base,
        extra_volumes: extra_volumes
      )

    {reply, state} = launch(mode, argv, company, agent, state)
    {:reply, reply, state}
  end

  def handle_call({:stop_container, name}, _from, state) do
    # CR-04: if a Daemon was registered for this container, terminate it
    # cleanly via the DynamicSupervisor so the linked podman process exits
    # without propagating via ContainerManager's link.
    state = stop_daemon(name, state)

    reply =
      case System.cmd(@podman, ["stop", name], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, code} -> {:error, {:stop_failed, code, output}}
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # CR-04: a tracked Daemon exited — forget the mapping so a subsequent
    # start_container can register a fresh one without a stale entry.
    daemons = for {n, {p, r}} <- state.daemons, p != pid, into: %{}, do: {n, {p, r}}
    {:noreply, %{state | daemons: daemons}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ------ internals ------

  defp launch(:ephemeral, argv, _company, _agent, state) do
    reply =
      case System.cmd(@podman, argv, stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.trim(output)}
        {output, code} -> {:error, {:run_failed, code, output}}
      end

    {reply, state}
  end

  defp launch(:persistent, argv, company, agent, state) do
    # CR-04: start the Daemon under a DynamicSupervisor instead of linking
    # directly to ContainerManager. A crashed podman no longer tears down
    # ALL container management — it only affects this one agent's entry.
    # We monitor (not link) the Daemon pid so :DOWN events clear our map.
    name = "glorbo-#{company}-#{agent}"

    spec = %{
      id: name,
      start:
        {MuonTrap.Daemon, :start_link,
         [@podman, argv, [log_output: :info, stderr_to_stdout: true]]},
      restart: :transient,
      shutdown: 5_000
    }

    case DynamicSupervisor.start_child(state.daemon_supervisor, spec) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        daemons = Map.put(state.daemons, name, {pid, ref})
        {{:ok, name}, %{state | daemons: daemons}}

      {:error, {:already_started, pid}} ->
        ref = Process.monitor(pid)
        daemons = Map.put(state.daemons, name, {pid, ref})
        {{:ok, name}, %{state | daemons: daemons}}

      {:error, reason} ->
        {{:error, {:daemon_failed, reason}}, state}
    end
  end

  defp stop_daemon(name, state) do
    case Map.pop(state.daemons, name) do
      {nil, daemons} ->
        %{state | daemons: daemons}

      {{pid, ref}, daemons} ->
        Process.demonitor(ref, [:flush])
        _ = DynamicSupervisor.terminate_child(state.daemon_supervisor, pid)
        %{state | daemons: daemons}
    end
  end

  # CR-03: best-effort rm of a stale Podman container matching the target
  # name. Ignores errors — if there's nothing to remove, `rm -f` exits
  # non-zero and we proceed to launch normally.
  defp pre_clean_container(company, agent) do
    name = "glorbo-#{company}-#{agent}"
    _ = System.cmd(@podman, ["rm", "-f", name], stderr_to_stdout: true)
    :ok
  end
end
