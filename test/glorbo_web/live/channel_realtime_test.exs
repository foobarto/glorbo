defmodule GlorboWeb.ChannelRealtimeTest do
  @moduledoc """
  UI-02 regression: an external append to `channels/<slug>.md` must
  propagate to ChannelLive within 1.5 s via the Watcher →
  `company:<co>:channels:<slug>` PubSub topic.

  Tagged `:integration` + `:inotify` because the Watcher requires
  inotify-tools to start. CI on a Linux host with the package
  installed runs this via `mix test --include integration --include
  inotify`.
  """
  use GlorboWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :inotify

  setup %{base: base} do
    start_supervised!(
      {Glorbo.Company.Supervisor,
       [
         name: Glorbo.Test.UniqueName.gen("acme_realtime_sup"),
         company: "acme",
         base: base
       ]}
    )

    File.write!(
      Path.join([base, "companies", "acme", "channels", "general.md"]),
      """
      # general

      ## 2026-04-16T10:00:00Z | director
      Hello
      """
    )

    :ok
  end

  test "file appended externally propagates to LiveView within 1500 ms", %{
    conn: conn,
    base: base
  } do
    {:ok, view, _} = live(conn, "/companies/acme/channels/general")
    refute render(view) =~ "Late message"

    File.write!(
      Path.join([base, "companies", "acme", "channels", "general.md"]),
      "\n## 2026-04-16T10:05:00Z | CEO\nLate message\n",
      [:append]
    )

    assert wait_until(1_500, fn -> render(view) =~ "Late message" end),
           "channel did not propagate within 1500ms"
  end

  defp wait_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(deadline, fun)
  end

  defp do_wait(deadline, fun) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(50)
        do_wait(deadline, fun)
    end
  end
end
