defmodule GlorboWeb.LiveHelpersTest do
  use ExUnit.Case, async: true

  alias GlorboWeb.LiveHelpers

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{assigns: Map.put_new(assigns, :__changed__, %{})}
  end

  describe "schedule_coalesced_reload/3 + clear_reload_pending/1" do
    test "latches reload_pending? and delivers exactly one message for a burst" do
      s = socket()
      s1 = LiveHelpers.schedule_coalesced_reload(s, :reload_test, 30)
      assert s1.assigns.reload_pending?

      # A burst of further triggers while a reload is pending must NOT
      # schedule additional messages — that's the whole point of coalescing.
      s2 = LiveHelpers.schedule_coalesced_reload(s1, :reload_test, 30)
      _s3 = LiveHelpers.schedule_coalesced_reload(s2, :reload_test, 30)

      assert_receive :reload_test, 200
      refute_receive :reload_test, 120

      cleared = LiveHelpers.clear_reload_pending(s2)
      refute cleared.assigns.reload_pending?
    end

    test "after clearing, a new trigger schedules again" do
      s = socket() |> LiveHelpers.schedule_coalesced_reload(:reload_test, 20)
      assert_receive :reload_test, 200

      reset = LiveHelpers.clear_reload_pending(s)
      _again = LiveHelpers.schedule_coalesced_reload(reset, :reload_test, 20)
      assert_receive :reload_test, 200
    end
  end
end
