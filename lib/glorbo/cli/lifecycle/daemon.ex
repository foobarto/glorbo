defmodule Glorbo.CLI.Lifecycle.Daemon do
  @moduledoc """
  Spawns a detached child process that outlives the calling BEAM (Plan 05-02).

  Uses `/usr/bin/setsid` (available on every Linux target per DESIGN.md
  §13) to put the child in its own session so SIGHUP from the caller's
  controlling terminal doesn't propagate. Returns the child's OS pid.

  Per RESEARCH.md §Open Question #1, `setsid` is preferred over `nohup`
  because it creates a new session AND a new process group — the BEAM
  spawned by the child is guaranteed to survive the parent exiting,
  regardless of how the parent's shell is configured.

  ## Contract

    * `spawn_detached/2` runs a Burrito (or any other) binary detached
      from the current controlling terminal.
    * Returns the OS pid of the **setsid** process (which is the BEAM
      in practice, since setsid exec's into its argv[1] without forking
      in the default invocation).
    * The caller is expected to `Pidfile.write!/2` this pid so `status`
      and `down` can later locate the daemon.
  """

  @type env_entry :: {charlist(), charlist()}

  @doc """
  Spawn `binary_path` under `setsid` with `env` merged into the child's
  environment, detached from the current BEAM.

  The child is invoked as `setsid <binary_path> serve` — `serve` is the
  foreground verb that starts the full supervision tree and blocks until
  SIGTERM, which is exactly what a daemon should do.

  Returns `{:ok, os_pid}` on success or `{:error, reason}` on failure to
  locate `setsid` or open the Port.
  """
  @spec spawn_detached(Path.t(), [env_entry()]) :: {:ok, integer()} | {:error, term()}
  def spawn_detached(binary_path, env) when is_binary(binary_path) and is_list(env) do
    with :ok <- validate_binary(binary_path),
         {:ok, setsid} <- find_setsid() do
      do_spawn(setsid, binary_path, env)
    end
  end

  # WR-05: Port.open/{:spawn_executable, setsid} hands argv[1] through to
  # setsid's execve unchecked — a non-existent or non-executable binary
  # exec-fails silently, but Port.info still returns the short-lived
  # setsid pid which would then be recorded in the pidfile. Guard at
  # entry so callers see {:error, :binary_not_found | :binary_not_executable}
  # instead of a phantom pid.
  defp validate_binary(path) do
    cond do
      not File.exists?(path) ->
        {:error, :binary_not_found}

      not executable?(path) ->
        {:error, :binary_not_executable}

      true ->
        :ok
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode, type: :regular}} ->
        # Any-user execute bit set. File.stat returns POSIX mode; mask
        # against 0o111 (owner+group+other exec) to match the behaviour
        # of stdlib `System.find_executable/1`.
        Bitwise.band(mode, 0o111) != 0

      _ ->
        false
    end
  end

  defp find_setsid do
    case System.find_executable("setsid") do
      nil -> {:error, :setsid_not_found}
      setsid -> {:ok, setsid}
    end
  end

  defp do_spawn(setsid, binary_path, env) do
    port =
      Port.open(
        {:spawn_executable, setsid},
        [
          :binary,
          :exit_status,
          :hide,
          args: [binary_path, "serve"],
          env: env
        ]
      )

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        # Close our end of the Port immediately so the child detaches
        # cleanly from the parent BEAM. Our caller (`glorbo up`) exits
        # a moment later; the child persists because setsid has already
        # moved it to its own session/pgroup.
        Port.close(port)
        {:ok, os_pid}

      nil ->
        {:error, :no_os_pid}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Discover the path to the currently-running Burrito binary. Reads
  `__BURRITO_BIN_PATH` when set; falls back to `GLORBO_BINARY_PATH` (a
  test-only override), then a local `./glorbo` build-local symlink, then
  a PATH lookup, and finally raises a descriptive error when none of
  those are available.
  """
  @spec self_binary() :: Path.t()
  def self_binary do
    System.get_env("__BURRITO_BIN_PATH") ||
      System.get_env("GLORBO_BINARY_PATH") ||
      local_glorbo_binary() ||
      System.find_executable("glorbo") ||
      raise "Cannot locate Glorbo binary; set __BURRITO_BIN_PATH, GLORBO_BINARY_PATH, build ./glorbo, or install glorbo on PATH."
  end

  defp local_glorbo_binary do
    path = Path.expand("glorbo", File.cwd!())

    if executable?(path), do: path, else: nil
  end
end
