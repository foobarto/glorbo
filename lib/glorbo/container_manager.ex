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
  """
  @spec ensure_image(String.t()) :: :ok | {:error, term()}
  def ensure_image(image) do
    GenServer.call(__MODULE__, {:ensure_image, image}, 60_000)
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
  @spec start_container(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_container(company, opts) do
    GenServer.call(__MODULE__, {:start_container, company, opts}, 30_000)
  end

  @spec stop_container(String.t()) :: :ok | {:error, term()}
  def stop_container(name) do
    GenServer.call(__MODULE__, {:stop_container, name}, 15_000)
  end

  # ------ GenServer callbacks ------

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

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

    argv =
      Invocation.build_argv(company, agent, mode,
        base: base,
        extra_volumes: extra_volumes
      )

    reply = launch(mode, argv, company, agent)
    {:reply, reply, state}
  end

  def handle_call({:stop_container, name}, _from, state) do
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
  def handle_info(_msg, state), do: {:noreply, state}

  # ------ internals ------

  defp launch(:ephemeral, argv, _company, _agent) do
    case System.cmd(@podman, argv, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:run_failed, code, output}}
    end
  end

  defp launch(:persistent, argv, company, agent) do
    # Supervised by MuonTrap so a podman-daemon crash restarts only this
    # agent (Pattern 5 in the research notes). The caller keeps an opaque
    # handle — the container name — which stop_container/1 can target.
    case MuonTrap.Daemon.start_link(@podman, argv,
           log_output: :info,
           stderr_to_stdout: true
         ) do
      {:ok, _pid} -> {:ok, "glorbo-#{company}-#{agent}"}
      {:error, reason} -> {:error, {:daemon_failed, reason}}
    end
  end
end
