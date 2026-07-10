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
  Create a new file in an agent-writable tree using one exclusive open.

  Existing regular files and symlinks are both refused with `:eexist`; parent
  symlinks are rejected before and after directory creation. This closes the
  common `lstat` then `File.write` race for host-generated outbox envelopes.
  """
  @spec create_exclusive(Path.t(), iodata()) :: :ok | {:error, term()}
  def create_exclusive(path, content) when is_binary(path) do
    parent = Path.dirname(path)

    if any_symlink_in_path?(parent) do
      {:error, :symlinked_ancestor}
    else
      with :ok <- File.mkdir_p(parent),
           false <- any_symlink_in_path?(parent),
           :ok <- File.write(path, content, [:exclusive, :sync]) do
        :ok
      else
        true -> {:error, :symlinked_ancestor}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Threatmodel wave 23: every agent-RW read has the same OOM
  # vector (a planted 1 GB regular file). The default cap is 10 MiB
  # — generous for the largest legitimate task / channel files
  # we've ever observed. Use `read_bounded/2` for caller-specified
  # caps where 10 MiB is too generous.
  @default_max_bytes 10 * 1_048_576

  @doc """
  Read `path` after enforcing the lstat guard + a 10 MiB byte cap.
  A bare `File.read/1` on a path in an agent-writable tree follows
  symlinks AND has no size limit; this helper refuses any non-regular
  shape AND oversized files before reading.

  Use `read_bounded/2` when 10 MiB is too generous (e.g. memory body
  reads where 1 MiB is the right ceiling).
  """
  @spec read(Path.t()) ::
          {:ok, binary()}
          | {:error,
             {:not_regular_file, stat_type()}
             | :enoent
             | {:stat_failed, term()}
             | {:read_failed, term()}
             | {:file_too_large, non_neg_integer(), pos_integer()}}
  def read(path) when is_binary(path) do
    read_bounded(path, @default_max_bytes)
  end

  @doc """
  Like `read/1` but caps file size BEFORE reading via `:file.read_link_info`.
  Refuses files larger than `max_bytes` with
  `{:error, {:file_too_large, size, max}}` rather than slurping into RAM.

  Use this from any read site where the caller doesn't already enforce
  a size cap downstream — agent-controlled task / project / channel
  files where an attacker could plant a 1 GB body to OOM the BEAM.

  The `file_info` record element layout is:
  `{:file_info, size, type, access, atime, mtime, ctime, mode, ...}`.
  """
  @spec read_bounded(Path.t(), pos_integer()) ::
          {:ok, binary()}
          | {:error,
             {:not_regular_file, stat_type()}
             | :enoent
             | {:stat_failed, term()}
             | {:read_failed, term()}
             | {:file_too_large, non_neg_integer(), pos_integer()}}
  def read_bounded(path, max_bytes)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    case :file.read_link_info(path) do
      {:ok, info} ->
        case {elem(info, 2), elem(info, 1)} do
          {:regular, size} when size > max_bytes ->
            {:error, {:file_too_large, size, max_bytes}}

          {:regular, _size} ->
            case File.read(path) do
              {:ok, _} = ok -> ok
              {:error, reason} -> {:error, {:read_failed, reason}}
            end

          {other, _} ->
            {:error, {:not_regular_file, other}}
        end

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, {:stat_failed, reason}}
    end
  end

  @doc """
  Read at most the LAST `max_bytes` of a regular file.

  Gates on `File.lstat` (rejects symlinks — TOCTOU defense) before
  `:file.pread`-ing the tail window, so an agent-writable log/transcript
  can be tailed for the UI without slurping an attacker-grown body into
  RAM. Returns `{:ok, binary}` (possibly `""`), `:error` for a missing /
  non-regular / symlinked path, or the underlying `{:error, reason}`.
  """
  @spec read_tail(Path.t(), pos_integer()) :: {:ok, binary()} | :error | {:error, term()}
  def read_tail(path, max_bytes)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path, time: :posix),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path) do
      offset = max(size - max_bytes, 0)

      case :file.open(path, [:read, :binary]) do
        {:ok, io} ->
          result =
            case :file.pread(io, offset, max_bytes) do
              {:ok, data} -> {:ok, data}
              :eof -> {:ok, ""}
              other -> other
            end

          _ = :file.close(io)
          result

        {:error, _} = err ->
          err
      end
    else
      _ -> :error
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
