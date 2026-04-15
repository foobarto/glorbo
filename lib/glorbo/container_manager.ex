defmodule Glorbo.ContainerManager do
  @moduledoc """
  Manages the Podman container lifecycle for company runtimes.

  *Phase 1 stub.* Phase 2 implements image building via `podman build`,
  container lifecycle via `podman run/stop`, and auto-download of the static
  podman binary into `~/.glorbo/bin/`.
  """
  use GenServer

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @spec ensure_image(String.t()) :: {:error, :not_implemented}
  def ensure_image(_image_name), do: {:error, :not_implemented}

  # GenServer callbacks

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call(_msg, _from, state), do: {:reply, {:error, :not_implemented}, state}

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
