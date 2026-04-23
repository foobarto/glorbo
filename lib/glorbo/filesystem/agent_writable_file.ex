defmodule Glorbo.Filesystem.AgentWritableFile do
  @moduledoc """
  Host-side read/write helpers for paths in trees the agent can also
  write to. Single seam for the lstat-before-touch policy that every
  host-side path crossing an agent-writable boundary must apply.

  ## Why this module exists

  `~/.glorbo/companies/<co>/agents/<slug>/{outbox,workspace,state}/`
  are bind-mounted `rw` into the agent sandbox. When the host side
  reads or writes inside those trees, a bare `File.read` / `File.write`
  silently follows symlinks. An agent who plants
  `outbox/comments/blog-7.md -> ~/.ssh/id_rsa` (or any other reachable
  path) turns the host-side Router into a confused deputy. The same
  applies to `state/wake-request.md`, approval sentinels, and task
  destination paths inside `projects/<p>/tasks/`.

  Every agent-writable read + write must lstat first. Prior to this
  module there were ~10 private copies of the helper across Router,
  Actions, BrainDump, TaskComments, TaskDefinition, KanbanLive. Each
  had slightly different return shapes, and the round-1/3 sweeps had
  to chase them individually. This module consolidates them.

  ## Semantics

    * `read/1` — lstat + read. Refuses symlinks, FIFOs, sockets,
      character/block devices, and directories.
    * `ensure_writable/1` — lstat + require `:regular` OR `:enoent`.
      Callers use this before `File.write!` / `:append` / atomic
      tmp+rename on a path in an agent-writable tree. Absent paths
      are OK (first write) but every other non-regular type is not.
    * `ensure_regular/1` — lstat + require `:regular` (NO `:enoent`).
      For reads where the file must already exist.

  The three shapes exist because callers split into "read-existing",
  "write-first-or-replace", and "refuse-anything-weird-but-absent-ok".
  All callers used to name these subtly differently; having them in
  one module with one naming scheme removes the naming drift.

  ## Error shapes

  All three functions return either `:ok` / `{:ok, binary()}` on
  success, or `{:error, reason}` where `reason` is one of:

    * `{:not_regular_file, :symlink | :directory | :device | :other}`
    * `{:stat_failed, posix_error}`
    * `:enoent` — only from `ensure_regular/1`
    * `{:read_failed, posix_error}` — only from `read/1`
  """

  @type stat_type :: :regular | :directory | :symlink | :device | :other | :fifo | :undefined

  @doc """
  Stat `path` and return `:ok` when it's a regular file, `:enoent`
  when it does not exist, or `{:error, ...}` for every other shape
  (symlink, dir, FIFO, etc.). Safe to call before a host-side write
  that expects to create-or-replace.
  """
  @spec ensure_writable(Path.t()) ::
          :ok | {:error, {:not_regular_file, stat_type()} | {:stat_failed, term()}}
  def ensure_writable(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular_file, type}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:stat_failed, reason}}
    end
  end

  @doc """
  Like `ensure_writable/1`, but also rejects `:enoent`. Use before a
  host-side READ where the file must already exist.
  """
  @spec ensure_regular(Path.t()) ::
          :ok
          | {:error, {:not_regular_file, stat_type()} | :enoent | {:stat_failed, term()}}
  def ensure_regular(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular_file, type}}
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, {:stat_failed, reason}}
    end
  end

  @doc """
  Read `path` after enforcing the lstat guard. A bare `File.read/1`
  on a path in an agent-writable tree follows symlinks; this helper
  refuses any non-regular shape before reading.
  """
  @spec read(Path.t()) ::
          {:ok, binary()}
          | {:error,
             {:not_regular_file, stat_type()}
             | :enoent
             | {:stat_failed, term()}
             | {:read_failed, term()}}
  def read(path) when is_binary(path) do
    with :ok <- ensure_regular(path),
         {:ok, _} = ok <- File.read(path) do
      ok
    else
      {:error, {:not_regular_file, _}} = err -> err
      {:error, :enoent} = err -> err
      {:error, {:stat_failed, _}} = err -> err
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @doc """
  Return `true` if ANY ancestor segment of `path` (including `path`
  itself) is a symlink. Use to decide whether a path the filesystem
  walker discovered actually lives inside its expected tree or was
  smuggled in via a symlinked directory.

  Rationale: `Path.expand/1` only resolves `..` / `.` lexically, so
  `/real/path/to/x` and `/real/path/to/x` where some mid-segment is
  a symlink out of the tree look identical after expansion. A
  realpath resolver doesn't exist in OTP; walking segments with
  `File.lstat` is the portable approximation.
  """
  @spec any_symlink_in_path?(Path.t()) :: boolean()
  def any_symlink_in_path?(path) when is_binary(path) do
    Enum.any?(ancestor_paths(path), &symlink?/1)
  end

  defp ancestor_paths(path) do
    path
    |> Path.split()
    |> Enum.reduce([], fn
      "/", acc -> ["/" | acc]
      seg, [] -> [seg]
      seg, [head | _] = acc -> [Path.join(head, seg) | acc]
    end)
    |> Enum.reverse()
  end

  defp symlink?(""), do: false

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end
end
