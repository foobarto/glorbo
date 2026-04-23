defmodule GlorboWeb.StdoutStreamerTest do
  @moduledoc """
  Plan 04-01 Task 3: `GlorboWeb.StdoutStreamer` tail poller.

  The streamer is filesystem-polled (not inotify-driven), so these tests
  do NOT require `inotify-tools` on the host — unlike the Watcher suite.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Test.TmpGlorboHome

  setup do
    # Ensure the DynamicSupervisor is started for each test (Application
    # boots it normally; in async: false mode we still use the running
    # tree).
    ensure_supervisor!()

    base = TmpGlorboHome.setup()

    # Each test gets a unique agent slug so the singleton Registry key
    # (#134) doesn't leak streamer pids between tests. Company stays
    # "acme" since the PubSub topic partition is per-agent anyway.
    agent = "ceo-#{System.unique_integer([:positive])}"
    path = Path.join([base, "companies", "acme", "agents", agent, "stdout.log"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")

    topic = "company:acme:agents:#{agent}:stdout"
    Phoenix.PubSub.subscribe(Glorbo.PubSub, topic)

    on_exit(fn ->
      case Registry.lookup(Glorbo.Agent.Registry, {:stdout_streamer, "acme", agent}) do
        [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        _ -> :ok
      end
    end)

    %{base: base, agent: agent, path: path, topic: topic}
  end

  defp ensure_supervisor! do
    # The StdoutStreamer.Supervisor is a child of Glorbo.Application's
    # supervision tree — `mix test` starts the app which starts this
    # supervisor. If it's there, return immediately.
    #
    # Bug #145: previous version used DynamicSupervisor.start_link
    # without a parent, which linked the supervisor to the test pid
    # and killed all streamer children when the test finished. Don't
    # introduce a test-linked supervisor.
    unless Process.whereis(GlorboWeb.StdoutStreamer.Supervisor) do
      Application.ensure_all_started(:glorbo)
      wait_for_supervisor!(50)
    end

    :ok
  end

  defp wait_for_supervisor!(0), do: raise("StdoutStreamer.Supervisor never started")

  defp wait_for_supervisor!(attempts) do
    if Process.whereis(GlorboWeb.StdoutStreamer.Supervisor) do
      :ok
    else
      Process.sleep(20)
      wait_for_supervisor!(attempts - 1)
    end
  end

  test "replays trailing history on mount then tails live (task #136)", %{
    base: base,
    agent: agent,
    path: path
  } do
    File.write!(path, "old history line\n")

    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    # Pre-existing content IS replayed so the user sees recent activity
    # when revisiting an agent detail page.
    assert_receive {:stdout_line, "acme", ^agent, %{body: "old history line"}}, 2_000

    # New bytes continue to stream live.
    File.write!(path, "fresh line\n", [:append])
    assert_receive {:stdout_line, "acme", ^agent, %{body: "fresh line"}}, 2_000

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "replay is bounded — only the last ~32KiB is surfaced", %{
    base: base,
    agent: agent,
    path: path
  } do
    # Write > 32 KiB so the seek-back trims the leading content.
    old_padding = String.duplicate("padding-line\n", 4_000)
    File.write!(path, old_padding <> "MARKER-LATEST-LINE\n")

    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    # The trailing marker shows up.
    assert_receive {:stdout_line, "acme", ^agent, %{body: "MARKER-LATEST-LINE"}}, 2_000

    # Collect everything the replay broadcast and verify we didn't
    # replay the FIRST line (which should have been seeked past).
    Process.sleep(300)

    messages =
      for _ <- 1..1000, msg = drop_message(), msg != nil, do: msg

    bodies =
      messages
      |> Enum.filter(&match?({:stdout_line, _, _, _}, &1))
      |> Enum.map(fn {:stdout_line, _, _, %{body: b}} -> b end)

    # Every body must have been within the trailing window. Since
    # every replay line is identical padding ("padding-line"), we
    # just assert that the replay didn't include ALL 4000 of them.
    padding_count = Enum.count(bodies, &(&1 == "padding-line"))
    assert padding_count < 4_000, "expected bounded replay; saw #{padding_count} padding lines"

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  defp drop_message do
    receive do
      msg -> msg
    after
      10 -> nil
    end
  end

  test "broadcasts each new line as a separate PubSub message", %{
    base: base,
    agent: agent,
    path: path
  } do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    File.write!(path, "hello\nworld\n", [:append])

    assert_receive {:stdout_line, "acme", ^agent, %{body: "hello"}}, 2_000
    assert_receive {:stdout_line, "acme", ^agent, %{body: "world"}}, 2_000

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "strips ANSI escape sequences", %{base: base, agent: agent, path: path} do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    File.write!(path, "\e[31mred text\e[0m\n", [:append])

    assert_receive {:stdout_line, "acme", ^agent, %{body: "red text"}}, 2_000

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "buffers partial trailing line until newline arrives", %{
    base: base,
    agent: agent,
    path: path
  } do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    File.write!(path, "partial", [:append])
    Process.sleep(400)
    refute_received {:stdout_line, _, _, _}

    File.write!(path, " trailing\n", [:append])

    assert_receive {:stdout_line, "acme", ^agent, %{body: "partial trailing"}}, 2_000

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "caps an unterminated partial line and drops overflow until newline", %{
    base: base,
    agent: agent,
    path: path
  } do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    File.write!(path, String.duplicate("x", 20_000), [:append])
    Process.sleep(400)

    state = :sys.get_state(pid)
    assert state.buf_truncated?
    assert byte_size(state.buf) <= 8_192
    assert String.ends_with?(state.buf, "... [truncated]")

    File.write!(path, "ignored-after-cap\nnext line\n", [:append])

    assert_receive {:stdout_line, "acme", ^agent, %{body: body}}, 2_000
    assert byte_size(body) <= 8_192
    assert String.ends_with?(body, "... [truncated]")
    refute body =~ "ignored-after-cap"

    assert_receive {:stdout_line, "acme", ^agent, %{body: "next line"}}, 2_000

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "caps a complete long line before broadcast", %{base: base, agent: agent, path: path} do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    File.write!(path, String.duplicate("y", 20_000) <> "\n", [:append])

    assert_receive {:stdout_line, "acme", ^agent, %{body: body}}, 2_000
    assert byte_size(body) <= 8_192
    assert String.ends_with?(body, "... [truncated]")

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "trims trailing whitespace and \\r from lines", %{
    base: base,
    agent: agent,
    path: path
  } do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    # Terminal clears / progress bars often emit CRLF or trailing spaces.
    # Leading whitespace is meaningful for indented output so it must be preserved.
    File.write!(path, "  indented body   \r\n", [:append])

    assert_receive {:stdout_line, "acme", ^agent, %{body: body}}, 2_000
    assert body == "  indented body"

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "strips mid-line \\r so pre-wrap CSS doesn't break lines in the UI", %{
    base: base,
    agent: agent,
    path: path
  } do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    # claude-code's spinner clears emit \r INSIDE a line to overwrite
    # previous content. With CSS white-space: pre-wrap the bare \r
    # renders as a visual line break in Chrome, producing ghost gaps.
    File.write!(path, "first\rsecond\n", [:append])

    assert_receive {:stdout_line, "acme", ^agent, %{body: body}}, 2_000
    refute String.contains?(body, "\r")
    assert body == "firstsecond"

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "strips OSC window-title sequences", %{
    base: base,
    agent: agent,
    path: path
  } do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    # OSC 0 / ST: "set window title"; claude-code emits these before
    # prompting so the terminal tab shows the current task.
    File.write!(path, "\e]0;glorbo\x07hello\n", [:append])

    assert_receive {:stdout_line, "acme", ^agent, %{body: body}}, 2_000
    assert body == "hello"

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "lazy-opens a file that doesn't exist at start time", %{base: base} do
    # A different agent to the shared fixture — file intentionally NOT created.
    engineer = "engineer-#{System.unique_integer([:positive])}"
    late_path = Path.join([base, "companies", "acme", "agents", engineer, "stdout.log"])
    File.mkdir_p!(Path.dirname(late_path))

    Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:acme:agents:#{engineer}:stdout")

    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", engineer, base: base)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    # Give the streamer a couple of open-retry cycles, then create + write.
    Process.sleep(400)
    File.write!(late_path, "late arrival\n")

    assert_receive {:stdout_line, "acme", ^engineer, %{body: "late arrival"}}, 3_000
  end

  test "stop/1 terminates cleanly and closes the file handle", %{base: base, agent: agent} do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)
    ref = Process.monitor(pid)

    GlorboWeb.StdoutStreamer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  # task #141 — backfill/1 returns the rolling buffer of recent
  # payloads in chronological (oldest-first) order. Late-subscribing
  # LVs call this to seed their local stream; without it, singleton
  # streamers only emit history at init and later mounts start empty.
  test "backfill/1 returns recent payloads in chronological order",
       %{base: base, agent: agent, path: path} do
    # Pre-seed so the init-time replay populates `recent`.
    File.write!(path, "first\nsecond\nthird\n")

    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    # Wait for init replay to finish.
    Process.sleep(200)

    payloads = GlorboWeb.StdoutStreamer.backfill(pid)
    bodies = Enum.map(payloads, & &1.body)

    assert bodies == ["first", "second", "third"]

    # Backfill is defensively re-sanitized: any stale buffer entries
    # from before a strip_ansi regex tweak must come out clean even
    # if the stored body was stored pre-fix. We simulate this by
    # injecting a dirty payload directly into state.recent via :sys.
    :sys.replace_state(pid, fn state ->
      dirty = %{id: 999_999, body: "dirty\rline  ", kind: :body}
      %{state | recent: [dirty | state.recent]}
    end)

    payloads = GlorboWeb.StdoutStreamer.backfill(pid)
    assert "dirty\rline  " not in Enum.map(payloads, & &1.body)
    assert "dirtyline" in Enum.map(payloads, & &1.body)

    # A live-written line should also accumulate into backfill.
    File.write!(path, "fourth\n", [:append])
    Process.sleep(500)

    payloads = GlorboWeb.StdoutStreamer.backfill(pid)
    bodies = Enum.map(payloads, & &1.body)
    assert "fourth" in bodies

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  # task #142 — blank lines (and whitespace-only lines) are dropped
  # before broadcast so the STDOUT tab doesn't render empty rows.
  # Header/exit markers survive because their bodies have non-ws
  # content.
  test "blank and whitespace-only lines are filtered out",
       %{base: base, agent: agent, path: path} do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    File.write!(path, "real line\n\n   \n\t\nanother real line\n", [:append])

    assert_receive {:stdout_line, "acme", ^agent, %{body: "real line"}}, 2_000
    assert_receive {:stdout_line, "acme", ^agent, %{body: "another real line"}}, 2_000
    # Give the streamer another poll cycle to make sure we don't
    # receive a stray blank-body payload afterwards.
    Process.sleep(400)
    refute_received {:stdout_line, "acme", ^agent, %{body: ""}}
    refute_received {:stdout_line, "acme", ^agent, %{body: "   "}}
    refute_received {:stdout_line, "acme", ^agent, %{body: "\t"}}

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  # task #134 — singleton guarantee: multiple start/3 calls for the
  # same {company, agent} return the SAME pid. Without this, every
  # open dashboard tab would spawn its own streamer tailing the same
  # file, producing N-way line duplication in every LV.
  test "start/3 is a singleton per {company, agent}", %{base: base, agent: agent} do
    {:ok, pid1} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)
    {:ok, pid2} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)
    {:ok, pid3} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    assert pid1 == pid2
    assert pid2 == pid3

    GlorboWeb.StdoutStreamer.stop(pid1)
  end

  test "line id is monotonically increasing per line", %{base: base, agent: agent, path: path} do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", agent, base: base)

    File.write!(path, "a\nb\nc\n", [:append])

    assert_receive {:stdout_line, "acme", ^agent, %{id: id1, body: "a"}}, 2_000
    assert_receive {:stdout_line, "acme", ^agent, %{id: id2, body: "b"}}, 2_000
    assert_receive {:stdout_line, "acme", ^agent, %{id: id3, body: "c"}}, 2_000

    assert id1 < id2
    assert id2 < id3

    GlorboWeb.StdoutStreamer.stop(pid)
  end
end
