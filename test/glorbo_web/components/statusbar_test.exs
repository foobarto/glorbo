defmodule GlorboWeb.Components.StatusbarTest do
  @moduledoc """
  Statusbar renders the daemon state, agent counts, SQLite size,
  inotify watcher count, director identity, and clock.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GlorboWeb.Components.Statusbar

  defp render_statusbar do
    assigns = %{__changed__: nil}
    Statusbar.statusbar(assigns) |> rendered_to_string()
  end

  describe "statusbar/1" do
    test "renders daemon label (either alive or stopped)" do
      html = render_statusbar()

      assert html =~ "daemon" and
               (html =~ "alive" or html =~ "stopped" or html =~ "stale pidfile")
    end

    test "renders the agents-running count" do
      html = render_statusbar()
      assert html =~ "agents running"
    end

    test "renders SQLite WAL line" do
      html = render_statusbar()
      assert html =~ "sqlite WAL"
    end

    test "renders inotify watching line" do
      html = render_statusbar()
      # The backend label ("inotify:" or "polling:") + "watching N paths"
      # can land across span breaks; assert each piece individually.
      assert html =~ "inotify:"
      assert html =~ "watching"
      assert html =~ "paths"
    end

    test "renders the MCP endpoint segment (GEP-30)" do
      html = render_statusbar()
      assert html =~ "mcp:"
      assert html =~ "gl-statusbar__metric--optional"
      # Endpoint is localhost-relative (:PORT/mcp per GEP-29).
      assert html =~ ~r|:\d+/mcp|
    end

    test "renders a clock with datetime attr" do
      html = render_statusbar()
      assert html =~ "<time"
      assert html =~ "UTC"
    end

    test "renders director identity (user@host)" do
      html = render_statusbar()
      assert html =~ ~r/\w+@[\w\.-]+/
    end
  end
end
