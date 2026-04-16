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

  @switches [lines: :integer, follow: :boolean, help: :boolean]
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

  defp do_run([company], opts), do: tail_audit(company, opts)
  defp do_run([company, agent], opts), do: tail_stdout(company, agent, opts)
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

      output =
        path
        |> read_last_lines(lines)
        |> Enum.join("")

      if opts[:follow] do
        # --follow: emit backfill now, then stream further events live.
        IO.write(output)
        follow(path, :stdout)
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
    new_size = File.stat!(path).size

    if new_size > last_size do
      new_bytes = read_incremental(path, last_size)

      if kind == :audit do
        IO.write(format_audit_chunk(new_bytes))
      else
        IO.write(new_bytes)
      end
    end

    listen_loop(path, kind, File.stat!(path).size)
  end

  # 1s-tick poll fallback. No exit condition in the loop — the caller
  # hits Ctrl-C (SIGINT) to stop. For tests, use a TTL option.
  defp follow_poll(path, kind) do
    follow_poll_loop(path, kind, File.stat!(path).size)
  end

  defp follow_poll_loop(path, kind, last_size) do
    Process.sleep(@poll_interval_ms)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > last_size ->
        new_bytes = read_incremental(path, last_size)

        if kind == :audit do
          IO.write(format_audit_chunk(new_bytes))
        else
          IO.write(new_bytes)
        end

        follow_poll_loop(path, kind, size)

      {:ok, _} ->
        follow_poll_loop(path, kind, last_size)

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

  defp resolve_audit_path_for_follow(path, :stdout), do: path

  defp read_last_lines(path, n) do
    path |> File.stream!() |> Enum.take(-n)
  end

  defp read_incremental(path, from_byte) do
    {:ok, io} = File.open(path, [:read, :binary])
    :file.position(io, from_byte)
    data = IO.read(io, :eof)
    File.close(io)

    case data do
      :eof -> ""
      bin when is_binary(bin) -> bin
      _ -> ""
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
    System.get_env("GLORBO_HOME") || Path.expand("~/.glorbo")
  end

  defp usage do
    {:logs, 1,
     "Usage: glorbo logs <company> [agent] [--lines N] [--follow]\n"}
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

    BEHAVIOR
      Audit lines are JSON-decoded and pretty-printed:
        <ts>  <actor>  <action>  <target>  <detail-json>
      Stdout lines are emitted verbatim (ANSI preserved).

      Under --follow, month rollover (audit only) auto-resumes on the
      new <YYYY-MM>.jsonl file with a stderr warning.
    """
  end
end
