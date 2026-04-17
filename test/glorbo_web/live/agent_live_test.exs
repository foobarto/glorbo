defmodule GlorboWeb.AgentLiveTest do
  @moduledoc """
  Plan 04-02 Task 3 — `GlorboWeb.AgentLive`
  (/companies/:company/agents/:agent).

  Covers the happy-path header render (name + provider + Wake CTA),
  the 404 redirect for unknown agents, and the wake action path
  (click → `state/wake-request.md` on disk).
  """
  use GlorboWeb.LiveCase, async: false

  test "renders agent header + stdout tab + wake CTA", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/agents/ceo")
    assert html =~ "Ceo" or html =~ "CEO" or html =~ "ceo"
    assert html =~ "claude-code"
    # Stdout tab button in the center panel
    assert html =~ "stdout"
    # Inline wake form in the action row
    assert html =~ "wake now"
  end

  test "renders three-column layout (identity, center tabs, config)",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/agents/ceo")
    assert html =~ "gl-agent-detail__grid"
    assert html =~ "gl-agent-identity"
    assert html =~ "sandbox argv"
    assert html =~ "inbox/outbox"
    assert html =~ "config"
  end

  test "unknown agent redirects to company view", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies/acme"}}} =
             live(conn, ~p"/companies/acme/agents/ghost")
  end

  test "wake button writes state/wake-request.md", %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
    render_click(view, "wake", %{"reason" => ""})

    wake_path =
      Path.join([base, "companies", "acme", "agents", "ceo", "state", "wake-request.md"])

    assert File.exists?(wake_path), "wake-request.md was not written"
    content = File.read!(wake_path)
    assert content =~ "reason:"
  end
end
