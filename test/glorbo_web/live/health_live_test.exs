defmodule GlorboWeb.HealthLiveTest do
  @moduledoc """
  HealthLive smoke tests.

  No company scoping — this view renders at `/health` and introspects
  the running Elixir supervision tree + Doctor checks + CLI tool
  presence. Supervisor enumeration tolerates an empty `CompanySupervisor`
  in the test env (no companies booted) — the view must still render.
  """
  use GlorboWeb.LiveCase, async: false

  test "renders all three health sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/health")
    assert html =~ "System health"
    assert html =~ "Doctor checks"
    assert html =~ "Supervisors"
    assert html =~ "CLI tools"
  end

  test "shows bwrap and claude CLI rows", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/health")
    assert html =~ "bwrap"
    assert html =~ "claude"
  end

  test "Doctor check rows render pass/warn/fail tally", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/health")
    assert html =~ "pass"
    assert html =~ "warn"
    assert html =~ "fail"
  end
end
