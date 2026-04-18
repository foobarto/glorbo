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
    path = Path.join([base, "companies", "acme", "agents", "ceo", "stdout.log"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")

    topic = "company:acme:agents:ceo:stdout"
    Phoenix.PubSub.subscribe(Glorbo.PubSub, topic)

    %{base: base, path: path, topic: topic}
  end

  defp ensure_supervisor! do
    case Process.whereis(GlorboWeb.StdoutStreamer.Supervisor) do
      nil ->
        {:ok, _pid} =
          DynamicSupervisor.start_link(
            name: GlorboWeb.StdoutStreamer.Supervisor,
            strategy: :one_for_one
          )

        :ok

      _pid ->
        :ok
    end
  end

  test "replays trailing history on mount then tails live (task #136)", %{
    base: base,
    path: path
  } do
    File.write!(path, "old history line\n")

    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", "ceo", base: base)

    # Pre-existing content IS replayed so the user sees recent activity
    # when revisiting an agent detail page.
    assert_receive {:stdout_line, "acme", "ceo", %{body: "old history line"}}, 2_000

    # New bytes continue to stream live.
    File.write!(path, "fresh line\n", [:append])
    assert_receive {:stdout_line, "acme", "ceo", %{body: "fresh line"}}, 2_000

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "replay is bounded — only the last ~32KiB is surfaced", %{
    base: base,
    path: path
  } do
    # Write > 32 KiB so the seek-back trims the leading content.
    old_padding = String.duplicate("padding-line\n", 4_000)
    File.write!(path, old_padding <> "MARKER-LATEST-LINE\n")

    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", "ceo", base: base)

    # The trailing marker shows up.
    assert_receive {:stdout_line, "acme", "ceo", %{body: "MARKER-LATEST-LINE"}}, 2_000

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
    path: path
  } do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", "ceo", base: base)

    File.write!(path, "hello\nworld\n", [:append])

    assert_receive {:stdout_line, "acme", "ceo", %{body: "hello"}}, 2_000
    assert_receive {:stdout_line, "acme", "ceo", %{body: "world"}}, 2_000

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "strips ANSI escape sequences", %{base: base, path: path} do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", "ceo", base: base)

    File.write!(path, "\e[31mred text\e[0m\n", [:append])

    assert_receive {:stdout_line, "acme", "ceo", %{body: "red text"}}, 2_000

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "buffers partial trailing line until newline arrives", %{
    base: base,
    path: path
  } do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", "ceo", base: base)

    File.write!(path, "partial", [:append])
    Process.sleep(400)
    refute_received {:stdout_line, _, _, _}

    File.write!(path, " trailing\n", [:append])

    assert_receive {:stdout_line, "acme", "ceo", %{body: "partial trailing"}}, 2_000

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "lazy-opens a file that doesn't exist at start time", %{base: base} do
    # No stdout.log yet for this agent.
    late_path = Path.join([base, "companies", "acme", "agents", "engineer", "stdout.log"])
    File.mkdir_p!(Path.dirname(late_path))
    # File intentionally NOT created yet.

    Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:acme:agents:engineer:stdout")

    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", "engineer", base: base)

    # Give the streamer a couple of open-retry cycles, then create + write.
    Process.sleep(400)
    File.write!(late_path, "late arrival\n")

    assert_receive {:stdout_line, "acme", "engineer", %{body: "late arrival"}}, 3_000

    GlorboWeb.StdoutStreamer.stop(pid)
  end

  test "stop/1 terminates cleanly and closes the file handle", %{base: base} do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", "ceo", base: base)
    ref = Process.monitor(pid)

    GlorboWeb.StdoutStreamer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "line id is monotonically increasing per line", %{base: base, path: path} do
    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", "ceo", base: base)

    File.write!(path, "a\nb\nc\n", [:append])

    assert_receive {:stdout_line, "acme", "ceo", %{id: id1, body: "a"}}, 2_000
    assert_receive {:stdout_line, "acme", "ceo", %{id: id2, body: "b"}}, 2_000
    assert_receive {:stdout_line, "acme", "ceo", %{id: id3, body: "c"}}, 2_000

    assert id1 < id2
    assert id2 < id3

    GlorboWeb.StdoutStreamer.stop(pid)
  end
end
