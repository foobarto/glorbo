defmodule Glorbo.Chat.Rotation do
  @moduledoc """
  Rolling-log rotation for chat channel files (#238).

  Channel files (`channels/<name>.md`) are append-only from the app's
  perspective. Over months of ops they grow unboundedly — one
  director-heavy company in testing reached 4 MB on `general.md`.
  That slows every render, every search, and every agent's context
  when the channel is mounted.

  This module provides `maybe_rotate/2`, called AFTER each successful
  append. When the file exceeds either byte or line threshold,
  rotation:

    1. Reads the full file.
    2. Splits at the Nth-from-end `## <ts> | <author>` header so
       the tail contains complete messages, not a half-message.
    3. Writes `channels/archive/<channel>/<YYYY-MM-DD-HHMMSS>.md`
       (the portion that will be trimmed), fsyncing before the swap.
    4. Atomically replaces the live file with the tail via tmp+rename.

  Invariants preserved:

    * Append-only semantics for *messages* (not bytes). Archive files
      are never modified after creation; the live file is only ever
      truncated to a complete-message boundary.
    * No message is lost, duplicated, or reordered across rotation.
    * The live file is readable to a consumer at every instant
      (either the pre-rotation version or the post-rotation tail —
      never a partial state).
    * Sync-safe: archive is flushed to disk before the live file
      is replaced, so a crash between steps 3 and 4 leaves the old
      live file intact and the archive as a duplicate copy (safe).

  The archive directory is created lazily on first rotation.
  """

  require Logger

  @header_regex ~r/^## \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/m

  @type opts :: [
          rotate_after_bytes: non_neg_integer() | nil,
          rotate_after_lines: non_neg_integer() | nil,
          keep_tail_messages: non_neg_integer(),
          now_fun: (-> DateTime.t())
        ]

  @type rotation_result ::
          :noop
          | {:rotated, archive_path :: Path.t(), kept_messages :: non_neg_integer()}
          | {:error, term()}

  @default_rotate_after_bytes 512 * 1024
  @default_rotate_after_lines 1500
  @default_keep_tail_messages 100

  @doc """
  Check `path` and rotate if either size threshold is exceeded.

  Returns `:noop` when the file is under the thresholds (the
  overwhelming common case), `{:rotated, archive_path, kept}` on
  rotation, or `{:error, reason}` if IO fails — the append has
  already succeeded by this point, so a rotation failure is logged
  and does NOT fail the caller.

  Thresholds default to 512 KB / 1500 lines; any `nil` threshold
  disables that dimension. `keep_tail_messages` controls how many
  of the most-recent messages stay in the live file after rotation
  (default 100).
  """
  @spec maybe_rotate(Path.t(), opts()) :: rotation_result()
  def maybe_rotate(path, opts \\ []) when is_binary(path) do
    bytes_limit = Keyword.get(opts, :rotate_after_bytes, @default_rotate_after_bytes)
    lines_limit = Keyword.get(opts, :rotate_after_lines, @default_rotate_after_lines)
    keep_tail = Keyword.get(opts, :keep_tail_messages, @default_keep_tail_messages)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         true <- needs_rotation?(content, bytes_limit, lines_limit) do
      do_rotate(path, content, keep_tail, now_fun.())
    else
      false -> :noop
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp needs_rotation?(content, bytes_limit, lines_limit) do
    over_bytes = is_integer(bytes_limit) and byte_size(content) > bytes_limit

    over_lines =
      is_integer(lines_limit) and
        content |> String.split("\n") |> length() > lines_limit

    over_bytes or over_lines
  end

  defp do_rotate(path, content, keep_tail, now) do
    case split_at_tail_boundary(content, keep_tail) do
      {:ok, archive_part, live_part} ->
        dir = Path.dirname(path)
        channel = Path.basename(path, ".md")
        archive_dir = Path.join([dir, "archive", channel])

        # Wave 27: refuse a pre-planted `archive` or `archive/<chan>`
        # symlink — without this an attacker with write to channels/
        # could redirect the archive write across companies. Same
        # check for the live channel path so a `general.md ->
        # ../../audit/2026-04.jsonl` symlink can't get clobbered.
        if Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(archive_dir) or
             Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(path) do
          {:error, :symlinked_ancestor}
        else
          File.mkdir_p!(archive_dir)
          do_rotate_write(path, archive_dir, channel, archive_part, live_part, now)
        end

      :short_tail ->
        :noop
    end
  rescue
    e ->
      Logger.warning("chat rotation failed for #{path}: #{Exception.message(e)}")
      {:error, {:raised, Exception.message(e)}}
  end

  defp do_rotate_write(path, archive_dir, channel, archive_part, live_part, now) do
    ts = DateTime.truncate(now, :second) |> DateTime.to_iso8601()
    safe_ts = String.replace(ts, [":", ".", "+"], "-") |> String.replace("T", "-")
    archive_path = Path.join(archive_dir, safe_ts <> ".md")

    header = archive_header(channel, ts)

    with :ok <- File.write(archive_path, header <> archive_part, [:sync]),
         :ok <- atomic_replace(path, live_part) do
      kept = count_messages(live_part)
      {:rotated, archive_path, kept}
    else
      {:error, _} = err -> err
    end
  end

  # Split at the Nth-from-end `## <ts> | <author>` header so the
  # tail contains `keep_tail` whole messages. If there are fewer
  # messages than `keep_tail`, rotation is a no-op (nothing to
  # trim beyond what's already there).
  defp split_at_tail_boundary(content, keep_tail) do
    positions = header_positions(content)
    total = length(positions)

    if total <= keep_tail do
      :short_tail
    else
      # Threatmodel: `Regex.scan(:index)` returns byte offsets, but
      # `String.split_at/2` operates on grapheme indices. With
      # multibyte UTF-8 in message bodies, the two diverge and the
      # split lands mid-character — corrupting the archive + live
      # halves. Use `binary_part/3` so the slice is byte-exact, and
      # the `Regex.scan` byte offset is what we want.
      split_offset = Enum.at(positions, total - keep_tail)
      total_bytes = byte_size(content)
      archive_part = binary_part(content, 0, split_offset)
      live_part = binary_part(content, split_offset, total_bytes - split_offset)
      {:ok, archive_part, live_part}
    end
  end

  defp header_positions(content) do
    Regex.scan(@header_regex, content, return: :index)
    |> Enum.map(fn [{start, _len}] -> start end)
  end

  defp count_messages(content) do
    Regex.scan(@header_regex, content) |> length()
  end

  defp archive_header(channel, ts) do
    """
    ---
    kind: channel-log/v1
    channel: #{channel}
    archive_of: #{channel}.md
    rotated_from: #{ts}
    ---
    # #{channel} · archive segment

    Rotated from `channels/#{channel}.md` at #{ts}. Archive files
    are immutable — never modified or deleted.

    """
  end

  defp atomic_replace(path, content) do
    # Wave 27: random-suffix exclusive temp — predictable
    # `<channel>.md.rotate.tmp` was attacker-plantable as a symlink
    # if write to channels/ ever leaked.
    rand = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp = "#{path}.rotate.tmp-#{rand}"

    case :file.open(tmp, [:write, :raw, :exclusive, :binary, :sync]) do
      {:ok, fd} ->
        result = :file.write(fd, content)
        :file.close(fd)

        case result do
          :ok ->
            case File.rename(tmp, path) do
              :ok ->
                :ok

              {:error, _} = err ->
                _ = File.rm(tmp)
                err
            end

          {:error, _} = err ->
            _ = File.rm(tmp)
            err
        end

      {:error, _} = err ->
        err
    end
  end
end
