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

  test "opens at EOF — pre-existing content is NOT replayed", %{
    base: base,
    path: path
  } do
    File.write!(path, "old history line\n")

    {:ok, pid} = GlorboWeb.StdoutStreamer.start("acme", "ceo", base: base)

    # Give the streamer > one poll interval to read any pre-existing bytes.
    Process.sleep(400)
    refute_received {:stdout_line, "acme", "ceo", _}

    # New bytes DO stream through.
    File.write!(path, "fresh line\n", [:append])
    assert_receive {:stdout_line, "acme", "ceo", %{body: "fresh line"}}, 2_000

    GlorboWeb.StdoutStreamer.stop(pid)
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
