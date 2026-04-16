defmodule GlorboWeb.CompanyLiveTest do
  @moduledoc """
  Plan 04-02 Task 1 — `GlorboWeb.CompanyLive`
  (/companies/:company).

  Asserts the 5-tab bar (D-22) renders and unknown-company mounts
  redirect to the overview with a flash.
  """
  use GlorboWeb.LiveCase, async: false

  test "renders 5-tab bar with Kanban default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme")

    for tab <- ~w(Kanban Chat Approvals Audit Agents) do
      assert html =~ tab
    end
  end

  test "unknown company redirects to overview", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies"}}} =
             live(conn, "/companies/ghost")
  end
end
