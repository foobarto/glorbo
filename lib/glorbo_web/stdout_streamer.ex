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

  @ansi_re ~r/\x1B\[[0-9;]*[a-zA-Z]/

  @doc """
  Start a streamer under the supervision tree. Returns `{:ok, pid}`.

  Opts:
    * `:base`   — filesystem root (default `~/.glorbo`)
    * `:pubsub` — PubSub registry (default `Glorbo.PubSub`)
  """
  @spec start(String.t(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start(company, agent, opts \\ []) do
    child_opts = Keyword.merge(opts, company: company, agent: agent)

    DynamicSupervisor.start_child(
      GlorboWeb.StdoutStreamer.Supervisor,
      {__MODULE__, child_opts}
    )
  end

  @doc "Stop the streamer normally (closes the file handle via terminate/2)."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid, :normal)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    agent = Keyword.fetch!(opts, :agent)
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    pubsub = Keyword.get(opts, :pubsub, Glorbo.PubSub)
    path = Path.join([base, "companies", company, "agents", agent, "stdout.log"])

    state = %{
      io: nil,
      path: path,
      company: company,
      agent: agent,
      pubsub: pubsub,
      buf: ""
    }

    # Open at EOF if the file exists; otherwise lazy-open on retry.
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        {:ok, _} = :file.position(io, :eof)
        schedule_poll()
        {:ok, %{state | io: io}}

      {:error, :enoent} ->
        schedule_open_retry()
        {:ok, state}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
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

  defp flush_lines(bytes, state) do
    parts = String.split(bytes, "\n")
    {complete, [tail]} = Enum.split(parts, -1)

    Enum.each(complete, fn raw ->
      body = strip_ansi(raw)

      Phoenix.PubSub.broadcast(
        state.pubsub,
        "company:#{state.company}:agents:#{state.agent}:stdout",
        {:stdout_line, state.company, state.agent, %{id: make_id(), body: body}}
      )
    end)

    %{state | buf: tail}
  end

  defp make_id, do: System.unique_integer([:positive, :monotonic])
  defp strip_ansi(s), do: Regex.replace(@ansi_re, s, "")
end
