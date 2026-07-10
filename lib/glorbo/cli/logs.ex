defmodule Glorbo.CLI.Logs do
  @moduledoc """
  `glorbo logs <company> [agent]` — D-14/D-15: tail audit JSONL or agent
  stdout.

  Two routing forms:

    * `glorbo logs <co>` — tails `<base>/companies/<co>/audit/<YYYY-MM>.jsonl`,
      pretty-printing each JSON line as `<ts> <actor> <action> <target>
      <detail>`.
    * `glorbo logs <co> <agent>` — tails `<base>/companies/<co>/agents/<ag>/stdout.log`
      verbatim (stdout is user-facing text, not JSON).

  Flags:

    * `--lines N` — backfill count (default 50).
    * `--follow` — inotify-driven tail-forever. Falls back to 1s poll
      when `inotifywait` is unavailable, with a stderr warning
      (graceful degradation, D-14).

  Month-rollover handling (D-14): when the current audit JSONL file
  disappears under an inotify `:closed` event, the watcher re-resolves
  the month via `Calendar.strftime("%Y-%m")` and continues on the new
  file; emits a stderr warning.
  """

  @switches [lines: :integer, follow: :boolean, raw: :boolean, help: :boolean]
  @default_lines 50
  @poll_interval_ms 1000

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(argv) do
    {opts, positional, _invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      opts[:help] -> {:logs, 0, help_text()}
      positional == [] -> usage()
      true -> do_run(positional, opts)
    end
  end

  # Gemini round-6 finding (PR #38, LOW): the previous shape passed
  # `company` / `agent` straight from positional argv into
  # `Path.join` with no slug validation. Absolute paths don't
  # actually bypass `Path.join` (Elixir strips leading `/` on
  # later segments), but `..` traversal IS permitted; combined
  # with the `.log` / `.jsonl` suffix requirement the real risk
  # is narrow (operator-CLI surface, attacker would need write
  # access to the user's home for it to matter). Defense-in-depth:
  # gate on the canonical `Glorbo.Slug.valid?/1` regex so this
  # path is consistent with `glorbo new company` and the rest of
  # the CLI surface (both Copilot + codex P2 review flagged the
  # initial stricter-than-canonical regex as a regression).
  defp do_run([company], opts) do
    if Glorbo.Slug.valid?(company) do
      tail_audit(company, opts)
    else
      {:logs, 1, "Invalid company slug: #{company}\n"}
    end
  end

  defp do_run([company, agent], opts) do
    cond do
      not Glorbo.Slug.valid?(company) ->
        {:logs, 1, "Invalid company slug: #{company}\n"}

      not Glorbo.Slug.valid?(agent, :agent) ->
        {:logs, 1, "Invalid agent slug: #{agent}\n"}

      true ->
        tail_stdout(company, agent, opts)
    end
  end

  defp do_run(_, _), do: usage()

  # ---------------------------------------------------------------------
  # Audit JSONL tail
  # ---------------------------------------------------------------------

  defp tail_audit(company, opts) do
    base = glorbo_home()
    path = audit_path(base, company)

    if File.exists?(path) do
      lines = opts[:lines] || @default_lines

      output =
        path
        |> read_last_lines(lines)
        |> Enum.map_join("\n", &format_audit_line/1)

      output = if output == "", do: "", else: output <> "\n"

      if opts[:follow] do
        # --follow: emit backfill now, then stream further events live.
        IO.write(output)
        follow(path, :audit)
      else
        {:logs, 0, output}
      end
    else
      {:logs, 1, "No audit log found at #{path}. Check company name.\n"}
    end
  end

  # ---------------------------------------------------------------------
  # Raw stdout tail
  # ---------------------------------------------------------------------

  defp tail_stdout(company, agent, opts) do
    base = glorbo_home()
    path = Path.join([base, "companies", company, "agents", agent, "stdout.log"])

    if File.exists?(path) do
      lines = opts[:lines] || @default_lines

      raw? = opts[:raw] == true

      output =
        path
        |> read_last_lines(lines)
        |> Enum.join("")
        |> render_stdout(raw?)

      if opts[:follow] do
        # --follow: emit backfill now, then stream further events live.
        IO.write(output)
        follow(path, {:stdout, raw?})
      else
        {:logs, 0, output}
      end
    else
      {:logs, 1, "No stdout log found at #{path}. Check company/agent names.\n"}
    end
  end

  # ---------------------------------------------------------------------
  # --follow: inotify + poll fallback
  # ---------------------------------------------------------------------

  defp follow(path, kind) do
    if inotify_available?() do
      follow_inotify(path, kind)
    else
      IO.puts(:stderr, "inotifywait not available; falling back to 1s poll")
      follow_poll(path, kind)
    end
  end

  defp inotify_available?, do: System.find_executable("inotifywait") != nil

  defp follow_inotify(path, kind) do
    # WR-02: the file_system library emits absolute paths in its events
    # regardless of whether the caller subscribed with relative ones. If
    # GLORBO_HOME is relative (e.g., `./.glorbo` in dev), `path` would be
    # relative and the `^path` pattern match in `listen_loop/3` would
    # never fire. Normalize up front.
    abs_path = Path.expand(path)
    {:ok, watcher} = FileSystem.start_link(dirs: [Path.dirname(abs_path)])
    FileSystem.subscribe(watcher)
    initial_size = File.stat!(abs_path).size
    listen_loop(abs_path, kind, initial_size)
  end

  defp listen_loop(path, kind, last_size) do
    receive do
      {:file_event, _pid, {^path, events}} ->
        cond do
          :modified in events ->
            handle_modification(path, kind, last_size)

          :closed in events or :deleted in events or :removed in events ->
            # Possible month rollover — re-resolve.
            new_path = resolve_audit_path_for_follow(path, kind)

            if new_path != path do
              IO.puts(:stderr, "log file rotated; resuming on #{new_path}")
            end

            listen_loop(new_path, kind, 0)

          true ->
            listen_loop(path, kind, last_size)
        end

      {:file_event, _pid, :stop} ->
        {:logs, 0, ""}
    end
  end

  defp handle_modification(path, kind, last_size) do
    # WR-03: guard both stat calls. Under inotify coalescing, a
    # [:modified, :closed] pair arrives in one tick — the file may have
    # rotated (month rollover) between the two calls. Treat :enoent as
    # rotation and re-resolve the target path before looping.
    case read_follow_chunk(path, last_size) do
      {:ok, new_bytes, next_offset} ->
        IO.write(render_chunk(kind, new_bytes))
        listen_loop(path, kind, next_offset)

      {:error, :enoent} ->
        handle_rotation(path, kind)

      {:error, _reason} ->
        listen_loop(path, kind, last_size)
    end
  end

  @doc false
  @spec read_follow_chunk(Path.t(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def read_follow_chunk(path, last_size) do
    case File.stat(path) do
      # In-place truncation starts a new stream at byte zero. Keeping the old
      # offset would hide every append until the file grew past its prior size.
      {:ok, %File.Stat{size: size}} when size < last_size ->
        read_incremental(path, 0)

      {:ok, %File.Stat{size: size}} when size > last_size ->
        read_incremental(path, last_size)

      {:ok, %File.Stat{size: size}} ->
        {:ok, "", size}

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # WR-03: shared helper — file vanished between stat calls, try to
  # re-resolve (audit: recompute month bucket; stdout: same path, should
  # only enoent on deletion).
  defp handle_rotation(path, kind) do
    new_path = resolve_audit_path_for_follow(path, kind)

    if new_path != path do
      IO.puts(:stderr, "log file rotated; resuming on #{new_path}")
    end

    listen_loop(new_path, kind, 0)
  end

  # 1s-tick poll fallback. No exit condition in the loop — the caller
  # hits Ctrl-C (SIGINT) to stop. For tests, use a TTL option.
  defp follow_poll(path, kind) do
    follow_poll_loop(path, kind, File.stat!(path).size)
  end

  defp follow_poll_loop(path, kind, last_size) do
    Process.sleep(@poll_interval_ms)

    case read_follow_chunk(path, last_size) do
      {:ok, new_bytes, next_offset} ->
        IO.write(render_chunk(kind, new_bytes))
        follow_poll_loop(path, kind, next_offset)

      {:error, _} ->
        # File disappeared — try to re-resolve (month rollover).
        new_path = resolve_audit_path_for_follow(path, kind)

        if new_path != path and File.exists?(new_path) do
          IO.puts(:stderr, "log file rotated; resuming on #{new_path}")
          follow_poll_loop(new_path, kind, 0)
        else
          follow_poll_loop(path, kind, last_size)
        end
    end
  end

  # ---------------------------------------------------------------------
  # Path + line helpers
  # ---------------------------------------------------------------------

  defp audit_path(base, company) do
    month = DateTime.utc_now() |> Calendar.strftime("%Y-%m")
    Path.join([base, "companies", company, "audit", "#{month}.jsonl"])
  end

  # For audit paths, recompute the month bucket. For stdout paths the
  # file never rotates, so the returned path is the same.
  defp resolve_audit_path_for_follow(path, :audit) do
    # path is `<base>/companies/<co>/audit/<YYYY-MM>.jsonl` — replace
    # the trailing filename with the current month.
    dir = Path.dirname(path)
    month = DateTime.utc_now() |> Calendar.strftime("%Y-%m")
    Path.join(dir, "#{month}.jsonl")
  end

  defp resolve_audit_path_for_follow(path, {:stdout, _raw?}), do: path

  # ---------------------------------------------------------------------
  # Rendering — audit is structured; stdout is attacker-controlled.
  # ---------------------------------------------------------------------

  # C-117: agent stdout.log is the provider/agent CLI's combined
  # stdout+stderr — an untrusted output channel under the threat model.
  # A compromised provider can embed terminal control / ANSI / OSC escape
  # sequences that, when written verbatim to the operator's terminal via
  # `glorbo logs`, spoof output, rewrite displayed lines, or manipulate
  # window title / hyperlink / clipboard (OSC 8/52). Strip them by default
  # on the CLI path (the LiveView streamer already strips before
  # broadcasting); `--raw` opts back in for trusted local debugging.
  defp render_chunk(:audit, bytes), do: format_audit_chunk(bytes)
  defp render_chunk({:stdout, raw?}, bytes), do: render_stdout(bytes, raw?)

  defp render_stdout(bytes, true), do: bytes
  defp render_stdout(bytes, false), do: Glorbo.Terminal.Sanitizer.strip(bytes)

  defp read_last_lines(path, n) do
    path |> File.stream!() |> Enum.take(-n)
  end

  @doc false
  @spec read_incremental(Path.t(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def read_incremental(path, from_byte) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        result =
          with {:ok, _position} <- :file.position(io, from_byte) do
            case IO.read(io, :eof) do
              :eof -> {:ok, "", from_byte}
              data when is_binary(data) -> {:ok, data, from_byte + byte_size(data)}
              {:error, reason} -> {:error, reason}
            end
          end

        _ = File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_audit_line(raw) do
    case Jason.decode(String.trim(raw)) do
      {:ok, %{"ts" => ts, "actor" => a, "action" => act} = m} ->
        target = Map.get(m, "target") || "-"
        detail = Jason.encode!(Map.get(m, "detail", %{}))
        "#{ts}  #{a}  #{act}  #{target}  #{detail}"

      _ ->
        # Unparseable — emit raw (trimmed).
        String.trim_trailing(raw)
    end
  end

  defp format_audit_chunk(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.map_join("\n", &format_audit_line/1)
    |> Kernel.<>("\n")
  end

  defp glorbo_home do
    Glorbo.Filesystem.Hierarchy.home_root()
  end

  defp usage do
    {:logs, 1, "Usage: glorbo logs <company> [agent] [--lines N] [--follow]\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo logs — tail company audit JSONL or agent stdout.log.

    USAGE
      glorbo logs <company>              # audit/<YYYY-MM>.jsonl, pretty
      glorbo logs <company> <agent>      # agents/<ag>/stdout.log, raw

    FLAGS
      --lines N    Initial backfill (default #{@default_lines})
      --follow     Tail forever (inotify + 1s poll fallback).
      --raw        Emit agent stdout verbatim (no escape stripping).
                   Only for trusted local debugging — agent stdout is
                   untrusted and may contain terminal escapes.

    BEHAVIOR
      Audit lines are JSON-decoded and pretty-printed:
        <ts>  <actor>  <action>  <target>  <detail-json>
      Agent stdout is sanitized by default: terminal control / ANSI /
      OSC escape sequences are stripped so a compromised agent cannot
      inject escapes into the operator's terminal. Use --raw to opt out.

      Under --follow, month rollover (audit only) auto-resumes on the
      new <YYYY-MM>.jsonl file with a stderr warning.
    """
  end
end
