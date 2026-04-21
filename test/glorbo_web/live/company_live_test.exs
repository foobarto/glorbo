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

  test "goals: frontmatter renders a goals panel with a tasks deep link",
       %{conn: conn, base: base} do
    # Overlay a company.md that has a goals list.
    File.write!(Path.join([base, "companies", "acme", "company.md"]), """
    ---
    slug: acme
    name: Acme
    mission: Test
    goals:
      - slug: q4-launch
        title: Launch v2 by end of Q4
        description: Ship the next major release
        status: active
    ---
    # Acme
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme")
    assert html =~ "goals/"
    assert html =~ "Launch v2 by end of Q4"
    assert html =~ "Ship the next major release"
    # Deep link to kanban filtered by goal slug.
    assert html =~ "kanban?goal=q4-launch"
  end

  # #253 part 2 — goal progress mini-bar renders when tasks
  # reference the goal via `goal:` frontmatter.
  test "goals panel shows progress bar with done/total",
       %{conn: conn, base: base} do
    File.write!(Path.join([base, "companies", "acme", "company.md"]), """
    ---
    slug: acme
    name: Acme
    goals:
      - slug: q4-launch
        title: Launch v2
        status: active
    ---
    """)

    tasks_dir = Path.join([base, "companies/acme/projects/foo/tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([base, "companies/acme/projects/foo/project.md"]), """
    ---
    slug: foo
    name: foo
    ---
    """)

    File.write!(Path.join(tasks_dir, "foo-1.md"), """
    ---
    title: task-1
    status: done
    goal: q4-launch
    ---
    """)

    File.write!(Path.join(tasks_dir, "foo-2.md"), """
    ---
    title: task-2
    status: todo
    goal: q4-launch
    ---
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme")
    assert html =~ "gl-goals-row__progress"
    assert html =~ "gl-goals-row__progress-fill--mid"
    assert html =~ "1 / 2"
    assert html =~ "50%"
  end

  describe "wizard chain (paperclip-ux-gaps §13)" do
    test "?wizard=new_agent opens the new-agent modal with step marker",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme?wizard=new_agent")
      assert html =~ "gl-wizard-steps"
      assert html =~ "company ✓"
      assert html =~ "first agent"
    end

    test "?wizard=new_project opens the new-project modal at step 3",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme?wizard=new_project")
      assert html =~ "first agent ✓"
      assert html =~ "first project"
    end

    test "agent-create with wizard step chains into new_project step",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/companies/acme?wizard=new_agent")

      # Render the submit — after a successful scaffold, the socket
      # pushes a patch to ?wizard=new_project. Assert by checking the
      # re-rendered HTML now shows the new-project step marker.
      html =
        render_submit(view, "new_agent_create", %{
          "slug" => "wizard-agent",
          "role" => "wizard role",
          "provider" => ""
        })

      assert html =~ "first project"
    end
  end

  # #247 — company budget cap status strip at top of CompanyLive.
  describe "budget cap strip (#247)" do
    test "renders a progress bar when company.md declares a cap",
         %{conn: conn, base: base} do
      File.write!(Path.join([base, "companies/acme/company.md"]), """
      ---
      slug: acme
      budget_usd_cents_month: 10000
      ---
      """)

      {:ok, _view, html} = live(conn, ~p"/companies/acme")
      assert html =~ "budget (month)"
      assert html =~ "gl-budget-strip"
      # Cap is $100 ($10000 cents); used is $0. Both values appear
      # somewhere in the rendered strip, separated by whitespace /
      # markup, so test for them independently.
      assert html =~ "100.00"
      assert html =~ "0%"
    end

    test "omits the strip when no cap is declared", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme")
      refute html =~ "gl-budget-strip"
    end
  end
end
