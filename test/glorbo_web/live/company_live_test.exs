defmodule GlorboWeb.CompanyLiveTest do
  @moduledoc """
  `GlorboWeb.CompanyLive` (/companies/:company).

  Asserts the 4-tab bar (Kanban/Chat/Approvals/Audit) renders — the
  former dead "Agents" `<span>` tab was removed because the agent grid
  on the same page already serves that purpose (TODO.md P0 #4). The
  tab bar comes from the shared `CompanyTabs` component now, so lateral
  navigation keeps the active state (TODO.md P0 #5).

  Unknown-company mounts redirect to the overview with a flash.
  """
  use GlorboWeb.LiveCase, async: false

  test "sidebar exposes COMPANY navigation", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme")

    # CompanyTabs removed — sidebar owns navigation now.
    # Kanban is reached via the PROJECTS rail (per-project scope) instead
    # of a top-level nav entry.
    for label <- ~w(Overview Channels Approvals Providers) do
      assert html =~ ">#{label}<"
    end

    assert html =~ "Audit log"
    refute html =~ ~s(<span class="gl-tab")
  end

  test "unknown company redirects to overview", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies"}}} =
             live(conn, "/companies/ghost")
  end

  test "agent roster renders working-on line when :agent_status is :busy",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme")

    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:agents:status",
      {:agent_status, "ceo", :busy, "projects/foo/tasks/bar.md"}
    )

    Process.sleep(50)
    html = render(view)
    assert html =~ "working on"
    assert html =~ "projects/foo/tasks/bar.md"

    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:agents:status",
      {:agent_status, "ceo", :idle, nil}
    )

    Process.sleep(50)
    refute render(view) =~ "projects/foo/tasks/bar.md"
  end
end
