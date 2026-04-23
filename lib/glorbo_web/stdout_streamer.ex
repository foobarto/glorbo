defmodule GlorboWeb.StdoutStreamer do
  @moduledoc """
  Per-agent-page file-tail poller for `agents/<slug>/stdout.log`.

  AgentLive spawns one of these on `mount/3` under a
  `DynamicSupervisor` (`GlorboWeb.StdoutStreamer.Supervisor`, see
  `Glorbo.Application`). The streamer opens the log at its CURRENT
  EOF (D-15: no history replay) and then every `@poll_ms`:

    1. `:file.read/2` up to `@read_chunk` bytes
    2. splits on `\\n`
    3. strips ANSI escapes (`~r/\\x1B\\[[0-9;]*[a-zA-Z]/`)
    4. broadcasts each complete line as
       `{:stdout_line, company, agent, %{id: ..., body: ...}}` on
       `company:<co>:agents:<ag>:stdout`.

  Partial trailing bytes (no newline yet) are buffered for the next
  poll. When the file doesn't exist yet, the streamer retries the
  open every `@poll_ms` (lazy-open — common on fresh agents that
  haven't booted).

  Crash isolation: the streamer is NOT linked to the LiveView. The
  LV uses `Process.monitor/1` to learn about crashes and re-spawns
  as needed (see pitfall 4 in 04-RESEARCH.md). Since inotify carries
  only event types and not payload bytes, polling is unavoidable.
  """
  use GenServer
  require Logger

  # Poll interval (D-15). 300ms is the sweet spot:
  # * fast enough to feel live (sub-second)
  # * slow enough that 100 agents × 300ms ≈ 333 polls/s — well
  #   inside BEAM's comfort zone.
  @poll_ms 300

  # 64 KiB read chunk bounds per-poll memory. A runaway agent spewing
  # more than 64 KiB / 300 ms would lag on the tail but not crash —
  # remaining bytes are picked up on the next poll.
  @read_chunk 64_000

  # On init, read the trailing slice of the existing log so the user
  # sees recent activity when revisiting an agent (task #136 — the
  # D-15 "no history replay" default meant the STDOUT tab was always
  # empty until the next wake). 32 KiB ≈ last ~10 dispatches worth
  # of claude-code output; streamer then positions at EOF and tails
  # from there.
  @history_replay_bytes 32_000

  # CSI (cursor-move, SGR, clear, etc), OSC (window-title), and
  # standalone CR/BEL. `\r` survives after CSI/OSC strip and, under
  # `white-space: pre-wrap`, renders as a line break in Chrome — which
  # produces ghost blank lines between paragraphs of claude-code output.
  # Kill them so the tail matches the on-disk log.
  @ansi_re ~r/\x1B\[[0-9;?]*[A-Za-z]|\x1B\][^\x07]*\x07|[\r\x07]/

  # Threatmodel M8: bound both the pending no-newline buffer and the
  # final per-line payload size so a sandboxed agent cannot grow the
  # streamer's heap with one giant stdout line.
  @line_max_bytes 8_192
  @truncated_suffix "... [truncated]"

  @doc """
  Start (or look up) a streamer for this {company, agent}. Singleton
  keyed by `{:stdout_streamer, company, agent}` in `Glorbo.Agent.Registry`
  — if one already exists, the pid is returned instead of starting a
  second (task #134, avoids N-way line duplication with multiple LV
  tabs open on the same agent).

  Opts:
    * `:base`   — filesystem root (default `~/.glorbo`)
    * `:pubsub` — PubSub registry (default `Glorbo.PubSub`)
  """
  @spec start(String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start(company, agent, opts \\ []) do
    case Registry.lookup(Glorbo.Agent.Registry, {:stdout_streamer, company, agent}) do
      [{pid, _}] when is_pid(pid) ->
        {:ok, pid}

      _ ->
        child_opts = Keyword.merge(opts, company: company, agent: agent)

        case DynamicSupervisor.start_child(
               GlorboWeb.StdoutStreamer.Supervisor,
               {__MODULE__, child_opts}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @doc "Stop the streamer normally (closes the file handle via terminate/2)."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid, :normal)

  @doc """
  Return the streamer's rolling buffer of recent broadcast payloads.
  Used by late-subscribing LiveViews (task #141) to seed their local
  stream with what the streamer has already emitted since it booted.
  Returns `[]` if the streamer hasn't produced anything yet.
  """
  @spec backfill(pid()) :: [map()]
  def backfill(pid) when is_pid(pid) do
    GenServer.call(pid, :backfill)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    company = Keyword.fetch!(opts, :company)
    agent = Keyword.fetch!(opts, :agent)
    name = {:via, Registry, {Glorbo.Agent.Registry, {:stdout_streamer, company, agent}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    agent = Keyword.fetch!(opts, :agent)
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    pubsub = Keyword.get(opts, :pubsub, Glorbo.PubSub)
    path = Path.join([base, "companies", company, "agents", agent, "stdout.log"])

    state = %{
      io: nil,
      path: path,
      company: company,
      agent: agent,
      pubsub: pubsub,
      buf: "",
      buf_truncated?: false,
      # Rolling buffer of recent payloads (newest-last). Late
      # subscribers (additional LV mounts on the same agent) call
      # backfill/1 to seed their local stream with this slice —
      # fixes the #141 collision between singleton streamer and
      # per-mount history replay.
      recent: []
    }

    # Open with replay (task #136): seek to `max(0, size - N)`, flush
    # the trailing slice so the UI shows recent history on mount, then
    # continue tailing from EOF. If the file doesn't exist yet we
    # lazy-open on retry (common for freshly scaffolded agents).
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        state = %{state | io: io}
        state = replay_history(state)
        schedule_poll()
        {:ok, state}

      {:error, :enoent} ->
        schedule_open_retry()
        {:ok, state}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  # Read up to @history_replay_bytes from the tail of the log and emit
  # each complete line as if it had just been written. Drops the
  # leading partial fragment (we may have seeked mid-line) so we never
  # broadcast a half-line. Leaves the file position at EOF so
  # schedule_poll resumes live-tail mode.
  defp replay_history(%{io: io} = state) do
    with {:ok, size} <- :file.position(io, :eof),
         start_pos <- max(0, size - @history_replay_bytes),
         {:ok, _} <- :file.position(io, start_pos),
         {:ok, chunk} <- :file.read(io, size - start_pos) do
      to_replay =
        if start_pos == 0 do
          chunk
        else
          # Drop the partial first line — we likely seeked into the
          # middle of one.
          case :binary.split(chunk, "\n") do
            [_partial, rest] -> rest
            [_] -> ""
          end
        end

      state = replay_broadcast(to_replay, state)
      seek_to_eof(state)
    else
      _ -> state
    end
  end

  # Replay = broadcast only fully-terminated lines; no tail buffering
  # (we reset the state.buf to "" because the subsequent live tail
  # starts at EOF with no partial). Also accumulates each replayed
  # payload into state.recent so late-subscribing LVs can backfill
  # (#141) without re-reading the log themselves.
  defp replay_broadcast("", state), do: state

  defp replay_broadcast(bytes, state) do
    parts = String.split(bytes, "\n")
    # Drop the final element — it's either "" (if bytes ends with "\n")
    # or a partial mid-line that hasn't been completed yet. Safer to
    # skip it on replay than broadcast a fragment.
    complete = Enum.drop(parts, -1)

    Enum.reduce(complete, state, &process_line(&1, &2))
  end

  defp seek_to_eof(%{io: io} = state) do
    {:ok, _} = :file.position(io, :eof)
    state
  end

  @impl GenServer
  def handle_info(:poll, %{io: nil} = state),
    do: handle_info(:open_retry, state)

  def handle_info(:poll, state) do
    case :file.read(state.io, @read_chunk) do
      {:ok, bytes} ->
        state = flush_lines(state.buf <> bytes, state)
        schedule_poll()
        {:noreply, state}

      :eof ->
        schedule_poll()
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "[stdout_streamer/#{state.company}/#{state.agent}] read failed: #{inspect(reason)}"
        )

        {:stop, {:shutdown, reason}, state}
    end
  end

  def handle_info(:open_retry, state) do
    case File.open(state.path, [:read, :binary, :raw]) do
      {:ok, io} ->
        # Lazy-open: the file DIDN'T exist at init, so any bytes now in
        # it appeared while we were waiting — read from position 0 so
        # the Director sees them. This differs from the init-time open
        # (which positions at EOF per D-15 "no history replay") because
        # there is no history to skip on first appearance.
        schedule_poll()
        {:noreply, %{state | io: io}}

      {:error, _} ->
        schedule_open_retry()
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:backfill, _from, state) do
    # state.recent is prepended newest-first; reverse so the LV stream
    # inserts them in chronological order (oldest first, matching the
    # live tail order).
    #
    # Defensive re-strip: the server's buffer can outlive a hot code
    # replace, and payloads stored before a strip_ansi regex tweak
    # will still carry CR / OSC residue that renders as ghost gaps
    # under `white-space: pre-wrap`. Apply the current regex to each
    # body on the way out — cheap, idempotent, and guarantees the UI
    # matches the current streamer policy.
    cleaned =
      state.recent
      |> Enum.reverse()
      |> Enum.map(fn
        %{body: body} = payload when is_binary(body) ->
          %{payload | body: body |> strip_ansi() |> String.trim_trailing()}

        other ->
          other
      end)

    {:reply, cleaned, state}
  end

  @impl GenServer
  def terminate(_reason, %{io: io}) when not is_nil(io) do
    _ = File.close(io)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)
  defp schedule_open_retry, do: Process.send_after(self(), :open_retry, @poll_ms)

  # Split on `\n`; keep the trailing partial (no newline yet) in the
  # buffer for the next poll. Broadcast each COMPLETE line after ANSI
  # strip.
  defp flush_lines("", state), do: state

  # Once the pending buffer has already been capped, ignore everything
  # else on that line until the next newline arrives. This keeps heap
  # growth bounded even if the agent never flushes line breaks.
  defp flush_lines(bytes, %{buf_truncated?: true} = state) do
    case :binary.match(bytes, "\n") do
      :nomatch ->
        state

      {newline_idx, 1} ->
        line = state.buf
        rest_offset = newline_idx + 1
        rest_size = byte_size(bytes) - rest_offset
        rest = :binary.part(bytes, rest_offset, rest_size)

        state =
          state
          |> Map.put(:buf, "")
          |> Map.put(:buf_truncated?, false)

        state = process_line(line, state)

        flush_lines(rest, state)
    end
  end

  defp flush_lines(bytes, state) do
    parts = String.split(bytes, "\n")
    {complete, [tail]} = Enum.split(parts, -1)

    state = Enum.reduce(complete, state, &process_line(&1, &2))

    case cap_partial_buffer(tail) do
      {:ok, tail} ->
        %{state | buf: tail, buf_truncated?: false}

      {:truncated, tail} ->
        %{state | buf: tail, buf_truncated?: true}
    end
  end

  # Drop whitespace-only lines (task #142) before turning them into
  # payloads. claude-code sprinkles blank lines around tool-use echoes
  # and spinner clears; without this filter they pile up as empty rows
  # in the STDOUT tab, breaking the dispatch-card rhythm. Header/exit
  # markers still survive the filter because their bodies contain
  # non-whitespace.
  defp process_line(raw, state) do
    body =
      raw
      |> strip_ansi()
      |> String.trim_trailing()
      |> truncate_line_body()

    if String.trim(body) == "" do
      state
    else
      payload = build_payload(body)
      broadcast_payload(state, payload)
      remember(state, payload)
    end
  end

  defp broadcast_payload(state, payload) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      "company:#{state.company}:agents:#{state.agent}:stdout",
      {:stdout_line, state.company, state.agent, payload}
    )

    :ok
  end

  # Cap the rolling buffer so long-running agents with millions of
  # dispatch lines don't balloon the streamer's heap. Matches the
  # @history_replay_bytes sentiment ("a few dispatches") at the
  # payload-count level.
  @recent_cap 500

  defp remember(%{recent: recent} = state, payload) do
    new_recent =
      case [payload | recent] do
        list when length(list) > @recent_cap -> Enum.take(list, @recent_cap)
        list -> list
      end

    %{state | recent: new_recent}
  end

  defp build_payload(body) do
    {kind, extra} = classify_and_extract(body)
    Map.merge(%{id: make_id(), body: body, kind: kind}, extra)
  end

  defp cap_partial_buffer(tail) when byte_size(tail) <= @line_max_bytes, do: {:ok, tail}

  defp cap_partial_buffer(tail) do
    keep = max(@line_max_bytes - byte_size(@truncated_suffix), 0)
    {:truncated, valid_utf8_prefix(tail, keep) <> @truncated_suffix}
  end

  defp truncate_line_body(body) when byte_size(body) <= @line_max_bytes, do: body

  defp truncate_line_body(body) do
    keep = max(@line_max_bytes - byte_size(@truncated_suffix), 0)
    valid_utf8_prefix(body, keep) <> @truncated_suffix
  end

  defp valid_utf8_prefix(_body, max_bytes) when max_bytes <= 0, do: ""

  defp valid_utf8_prefix(body, max_bytes) do
    size = min(byte_size(body), max_bytes)
    prefix = :binary.part(body, 0, size)

    if String.valid?(prefix) do
      prefix
    else
      trim_invalid_utf8_suffix(prefix)
    end
  end

  defp trim_invalid_utf8_suffix(prefix) do
    size = byte_size(prefix)

    Enum.find_value(0..3, "", fn drop ->
      candidate = :binary.part(prefix, 0, max(size - drop, 0))
      if String.valid?(candidate), do: candidate
    end)
  end

  # Tag each line so the UI can render dispatch boundaries as cards.
  # Markers written by Glorbo.Sandbox.Bwrap's tee (task #135):
  #
  #   === glorbo dispatch <ISO8601> ===
  #   <body lines>
  #   === exit <code> ===
  #
  # The streamer emits `:header` / `:exit` / `:body` per line; AgentLive
  # groups them into styled dispatch cards.
  @header_re ~r/^=== glorbo dispatch (.+?) ===$/
  @exit_re ~r/^=== exit (\S+) ===$/

  defp classify_and_extract(body) do
    trimmed = String.trim(body)

    case Regex.run(@header_re, trimmed) do
      [_, ts] ->
        {:header, %{ts: ts}}

      _ ->
        case Regex.run(@exit_re, trimmed) do
          [_, code] -> {:exit, %{exit_code: code}}
          _ -> {:body, %{}}
        end
    end
  end

  defp make_id, do: System.unique_integer([:positive, :monotonic])
  defp strip_ansi(s), do: Regex.replace(@ansi_re, s, "")
end
