defmodule Glorbo.CLI.Lifecycle.Pidfile do
  @moduledoc """
  Atomic pidfile helper for `glorbo up` / `down` / `status` (Plan 05-01).

  Default path: `<base>/run/glorbo.pid`. Writes use temp + rename for
  atomic visibility on the same filesystem; the resulting file is mode
  `0600` so a concurrent reader never sees a partial or wrongly-permissioned
  pidfile (threat T-05-03).

  Status semantics match `systemctl is-active`-style reasoning:

    * `:stopped` — file absent (glorbo is not running here).
    * `:running` — file present, contents parse to an integer, `kill -0`
      reports the pid alive.
    * `:stale` — file present but either unparseable, or references a dead
      pid (caller should `rm/1` it and proceed).
  """

  @type status :: :stopped | :running | :stale

  @spec default_base() :: Path.t()
  def default_base, do: Glorbo.Filesystem.Hierarchy.default_root()

  @spec path(Path.t()) :: Path.t()
  def path(base \\ default_base()), do: Path.join([base, "run", "glorbo.pid"])

  @doc """
  Returns the current status of the pidfile under `base`.
  """
  @spec status(Path.t()) :: status()
  def status(base \\ default_base()) do
    p = path(base)

    case File.read(p) do
      {:error, :enoent} ->
        :stopped

      {:error, _} ->
        :stale

      {:ok, content} ->
        case parse_pid(content) do
          {:ok, pid} -> if alive?(pid), do: :running, else: :stale
          :error -> :stale
        end
    end
  end

  @doc """
  Reads the pid (as an integer) from the pidfile. Raises if the file is
  missing or unparseable.
  """
  @spec read!(Path.t()) :: integer()
  def read!(base \\ default_base()) do
    content = File.read!(path(base))

    case parse_pid(content) do
      {:ok, pid} -> pid
      :error -> raise "unparseable pidfile: #{path(base)}"
    end
  end

  @doc """
  Writes `pid` atomically to the pidfile. Creates the parent `run/`
  directory if missing, writes to a temp file, renames (atomic on same
  filesystem), then chmods the final file to `0600`.
  """
  @spec write!(integer(), Path.t()) :: :ok
  def write!(pid, base \\ default_base()) when is_integer(pid) do
    final = path(base)
    File.mkdir_p!(Path.dirname(final))

    tmp = final <> ".tmp"
    File.write!(tmp, Integer.to_string(pid) <> "\n", [:sync])
    File.rename!(tmp, final)
    File.chmod!(final, 0o600)
    :ok
  end

  @doc """
  Removes the pidfile. Tolerant of ENOENT — returns `:ok` whether or not
  the file existed.
  """
  @spec rm(Path.t()) :: :ok
  def rm(base \\ default_base()) do
    case File.rm(path(base)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise "cannot remove pidfile: #{inspect(reason)}"
    end
  end

  # ------ private ------

  defp parse_pid(content) do
    case content |> String.trim() |> Integer.parse() do
      {pid, ""} when pid > 0 -> {:ok, pid}
      _ -> :error
    end
  end

  # `kill -0 <pid>` is the POSIX-canonical liveness probe: exit 0 means
  # the pid is alive (or a zombie with the same PGID — close enough for
  # the daemon-running check). Exit != 0 means dead / permission denied,
  # both of which we treat as "not reachable by us" = stale.
  defp alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
