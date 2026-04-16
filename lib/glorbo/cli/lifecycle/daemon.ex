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

  require Logger

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
    case System.find_executable("setsid") do
      nil ->
        {:error, :setsid_not_found}

      setsid ->
        do_spawn(setsid, binary_path, env)
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
  test-only override) and finally raises a descriptive error when
  neither is available (dev / mix-test runs that don't stub this).
  """
  @spec self_binary() :: Path.t()
  def self_binary do
    System.get_env("__BURRITO_BIN_PATH") ||
      System.get_env("GLORBO_BINARY_PATH") ||
      raise "Cannot locate Glorbo binary; set __BURRITO_BIN_PATH (Burrito) or GLORBO_BINARY_PATH (test)."
  end
end
