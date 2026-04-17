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

  test "renders 4-tab bar (Kanban/Chat/Approvals/Audit)", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme")

    for tab <- ~w(Kanban Chat Approvals Audit) do
      assert html =~ tab
    end

    # The agent grid lives below the tab bar; no "Agents" tab anymore.
    refute html =~ ~s(<span class="gl-tab")
  end

  test "unknown company redirects to overview", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies"}}} =
             live(conn, "/companies/ghost")
  end
end
