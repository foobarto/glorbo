defmodule Glorbo.Sandbox.SymlinkGuard do
  @moduledoc """
  Refuse host paths whose ancestor segments contain symlinks.

  Round-3 codex finding (PR #35): `Glorbo.Sandbox.PermissionMapper`
  emitted `--bind` / `--ro-bind` flags for per-agent permission
  mounts without checking the host source's components. An agent
  holding `projects:write:foo` could plant a symlink at
  `<co>/projects/foo/tasks` → `~/.ssh`, then a sibling dispatch
  with `tasks:update:foo` would have bwrap resolve that symlink
  HOST-SIDE before the namespace switch, mounting `~/.ssh` rw
  inside the second sandbox at `/projects/foo/tasks`.

  The same check has existed for GEP-27 external grants since the
  codex deep-dive (`Glorbo.Sandbox.Bwrap.approved_path_flags/1`)
  — this module hoists it out so both call sites use one canonical
  implementation. Behavioural contract:

    * Walk every ancestor of `path` from `/` down.
    * Refuse (raise `ArgumentError`) if any intermediate is a symlink.
    * Allow non-existent trailing segments — the operator may have
      approved (or the mount source may be) a path the dispatch is
      about to create.
    * Fail closed on EVERY other `lstat` error (`:eacces`, `:eloop`,
      `:enotdir`, …): we cannot prove the path is symlink-free, so
      refuse rather than silently skip.

  `label` is folded into the error message so the operator can tell
  WHICH call site refused (e.g. `"host_path"` from approved-path
  flags, `"permission mount source"` from `PermissionMapper`).
  """

  @doc """
  Raise `ArgumentError` if any ancestor segment of `path` is a
  symlink, or if any segment's `lstat` fails for a reason other
  than `:enoent`.

  `label` is included verbatim in the error message; pass something
  meaningful for the call site (e.g. `"permission mount source"`).
  """
  @spec assert_no_symlink_segment!(Path.t(), String.t()) :: :ok
  def assert_no_symlink_segment!(path, label \\ "path") when is_binary(path) do
    path
    |> Path.split()
    |> Enum.reduce_while([], fn
      "/", _acc ->
        {:cont, ["/"]}

      seg, [] ->
        {:cont, [seg]}

      seg, [head | _] = acc ->
        candidate = Path.join(head, seg)

        case File.lstat(candidate) do
          {:ok, %File.Stat{type: :symlink}} ->
            {:halt, {:symlink, candidate}}

          {:ok, _other_type} ->
            {:cont, [candidate | acc]}

          # Not-yet-existing trailing segment is allowed (operator
          # may have approved a path the agent intends to create;
          # the per-permission mount source may name an inbox dir
          # that gets `mkdir_p!`d later in dispatch).
          {:error, :enoent} ->
            {:cont, [candidate | acc]}

          # Fail closed on every other lstat error. Treating these
          # as "no symlink" would silently skip the check when we
          # can't actually verify — that was the original `_ ->`
          # branch the Copilot PR #31 review flagged.
          {:error, reason} ->
            {:halt, {:stat_failed, candidate, reason}}
        end
    end)
    |> case do
      {:symlink, where} ->
        raise ArgumentError,
              "#{label}: refusing because path crosses a symlinked component, " <>
                "got #{inspect(where)} (full path: #{inspect(path)})"

      {:stat_failed, where, reason} ->
        raise ArgumentError,
              "#{label}: lstat failed at #{inspect(where)} " <>
                "(reason=#{inspect(reason)}; full path=#{inspect(path)}); refusing — " <>
                "cannot verify the path is symlink-free"

      _ ->
        :ok
    end
  end
end
