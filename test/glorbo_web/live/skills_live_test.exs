defmodule GlorboWeb.SkillsLiveTest do
  @moduledoc """
  `GlorboWeb.SkillsLive` — `/companies/:co/skills`
  (paperclip-ux-gaps §9).
  """
  use GlorboWeb.LiveCase, async: false

  test "lists builtin skills with source badge", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/skills")
    assert html =~ "glorbo"
    assert html =~ "builtin"
  end

  test "shadowed skill marker when a user override exists", %{conn: conn, base: base} do
    user_dir = Path.join(base, "skills")
    File.mkdir_p!(user_dir)

    File.write!(Path.join(user_dir, "glorbo.md"), """
    ---
    name: glorbo
    title: customised
    ---
    my own version
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/skills")
    assert html =~ "shadowed"
  end

  test "used-by column lists agents that declare the skill", %{conn: conn, base: base} do
    # Fixture agent `ceo` declares `skills: [glorbo]` via our default scaffold;
    # override agent.md to make the assertion deterministic.
    agent_md = Path.join([base, "companies", "acme", "agents", "ceo", "AGENT.md"])

    File.write!(agent_md, """
    ---
    name: ceo
    provider: claude-code
    model: anthropic/claude-opus-4-6
    skills:
      - glorbo
    ---
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/skills")
    assert html =~ "ceo"
  end

  test "toggle expands a skill body inline", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme/skills")
    html = render_click(view, "toggle", %{"name" => "glorbo"})
    assert html =~ "gl-skills-table__body"
  end

  test "unknown company redirects to /companies", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies"}}} =
             live(conn, "/companies/bogus/skills")
  end
end
