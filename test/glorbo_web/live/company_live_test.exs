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
    # Approvals was folded into Inbox (backlog #14); nav no longer
    # has a separate entry. The pending-approvals badge moved to
    # the Inbox item.
    for label <- ~w(Overview Chat Inbox Providers) do
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

    # :agent_status is coalesced (250 ms window) — wait past it so the
    # deferred light reload fires and stamps working-on.
    Process.sleep(350)
    html = render(view)
    assert html =~ "working on"
    assert html =~ "projects/foo/tasks/bar.md"

    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:agents:status",
      {:agent_status, "ceo", :idle, nil}
    )

    Process.sleep(350)
    refute render(view) =~ "projects/foo/tasks/bar.md"
  end

  test "rapid :agent_status burst coalesces to the latest flip",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme")

    # Fire a burst inside one coalescing window: busy → busy → idle. Only
    # the last flip should be reflected once the window closes.
    for path <- ["a.md", "b.md", "c.md"] do
      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:acme:agents:status",
        {:agent_status, "ceo", :busy, "projects/foo/tasks/#{path}"}
      )
    end

    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:agents:status",
      {:agent_status, "ceo", :idle, nil}
    )

    Process.sleep(350)
    html = render(view)
    # Latest flip was :idle → no working-on line at all, and none of the
    # intermediate busy paths leak through.
    refute html =~ "projects/foo/tasks/a.md"
    refute html =~ "projects/foo/tasks/c.md"
  end

  test "working-on survives a :file_event reload (durable overlay)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme")

    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:agents:status",
      {:agent_status, "ceo", :busy, "projects/foo/tasks/sticky.md"}
    )

    Process.sleep(350)
    assert render(view) =~ "projects/foo/tasks/sticky.md"

    # A :file_event triggers a full load_company_data, whose agent rows
    # carry no working-on. The durable per-slug overlay must re-stamp it,
    # otherwise the "working on" line vanishes mid-work until the next
    # status flip (codex review, 2026-05-22).
    send(view.pid, {:file_event, "companies/acme/agents/ceo/outbox/x.md", [:created]})

    Process.sleep(350)
    assert render(view) =~ "projects/foo/tasks/sticky.md"
  end

  test ":agent_status reload is deferred while the new-agent modal is open",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme")

    # Open the new-agent modal, then fire a status flip.
    render_click(view, "new_agent", %{})

    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:agents:status",
      {:agent_status, "ceo", :busy, "projects/foo/tasks/deferred.md"}
    )

    # Past the window: the reload re-arms instead of firing, so the
    # working-on stamp is withheld while the modal is open.
    Process.sleep(350)
    refute render(view) =~ "projects/foo/tasks/deferred.md"

    # Close the modal; the deferred reload now lands.
    render_click(view, "new_agent_cancel", %{})
    Process.sleep(350)
    assert render(view) =~ "projects/foo/tasks/deferred.md"
  end

  test "goals: frontmatter renders a goals panel with a tasks deep link",
       %{conn: conn, base: base} do
    # Overlay a company.md that has a goals list.
    File.write!(Path.join([base, "companies", "acme", "company.md"]), """
    ---
    kind: task/v1
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

  # R25 — goal normalizer accepts `name:` as a title fallback to
  # match muscle memory from the rest of company.md.
  test "goals panel accepts `name:` as title fallback",
       %{conn: conn, base: base} do
    File.write!(Path.join([base, "companies", "acme", "company.md"]), """
    ---
    slug: acme
    name: Acme
    goals:
      - slug: alt
        name: Friendly Name
    ---
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme")
    assert html =~ "Friendly Name"
  end

  # #253 part 2 — goal progress mini-bar renders when tasks
  # reference the goal via `goal:` frontmatter.
  test "goals panel shows progress bar with done/total",
       %{conn: conn, base: base} do
    File.write!(Path.join([base, "companies", "acme", "company.md"]), """
    ---
    kind: task/v1
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
    kind: task/v1
    title: task-1
    status: done
    goal: q4-launch
    ---
    """)

    File.write!(Path.join(tasks_dir, "foo-2.md"), """
    ---
    kind: task/v1
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

  # C-113 / C-101 / C-102 — the overview reads agent-controlled task
  # .md files, the shared chat drawer reads channels/general.md, and
  # the sparklines read the month audit file. All three must be
  # size-/symlink-gated so a planted huge or symlinked file can't OOM
  # or hang the dashboard when a director opens the overview.
  describe "overview DoS gates (C-113 / C-101 / C-102)" do
    test "an oversized task.md is skipped, not slurped, and the overview still renders",
         %{conn: conn, base: base} do
      tasks_dir = Path.join([base, "companies/acme/projects/foo/tasks"])
      File.mkdir_p!(tasks_dir)

      File.write!(Path.join([base, "companies/acme/projects/foo/project.md"]), """
      ---
      slug: foo
      name: foo
      ---
      """)

      # One legitimate task + one planted >1 MiB task.md.
      File.write!(Path.join(tasks_dir, "foo-1.md"), """
      ---
      kind: task/v1
      title: real
      status: done
      ---
      """)

      File.write!(
        Path.join(tasks_dir, "huge.md"),
        "---\nstatus: todo\n---\n" <> String.duplicate("x", 1_100_000)
      )

      # Should not crash / hang — the gate skips the huge file.
      {:ok, _view, html} = live(conn, ~p"/companies/acme")
      assert html =~ "Overview"
    end

    test "a symlinked task.md is not followed", %{conn: conn, base: base} do
      tasks_dir = Path.join([base, "companies/acme/projects/foo/tasks"])
      File.mkdir_p!(tasks_dir)

      secret = Path.join(System.tmp_dir!(), "task-secret-#{System.unique_integer([:positive])}")
      File.write!(secret, "---\nstatus: done\ntitle: LEAKED-TASK-TITLE\n---\n")
      on_exit(fn -> File.rm(secret) end)

      File.ln_s!(secret, Path.join(tasks_dir, "evil.md"))

      {:ok, _view, html} = live(conn, ~p"/companies/acme")
      refute html =~ "LEAKED-TASK-TITLE"
    end

    test "the chat drawer tail-reads a huge general.md", %{conn: conn, base: base} do
      path = Path.join([base, "companies", "acme", "channels", "general.md"])

      old =
        for i <- 1..20_000 do
          "## 2026-01-01T00:00:00Z | director\nDRAWER-OLD-#{i} #{String.duplicate("x", 80)}\n"
        end
        |> Enum.join("\n")

      File.write!(path, old <> "\n## 2026-04-16T10:00:00Z | director\nDRAWER-FRESH\n")

      {:ok, _view, html} = live(conn, ~p"/companies/acme")
      assert html =~ "DRAWER-FRESH"
      refute html =~ "DRAWER-OLD-1 "
    end

    test "an oversized audit file does not crash the overview", %{conn: conn, base: base} do
      audit_dir = Path.join([base, "companies", "acme", "audit"])
      File.mkdir_p!(audit_dir)
      ym = Calendar.strftime(DateTime.utc_now(), "%Y-%m")

      line = ~s({"ts":"2026-04-16T10:00:00Z","action":"agent.complete","actor":"ceo"}\n)
      # ~20 MiB > 16 MiB cap.
      File.write!(Path.join(audit_dir, "#{ym}.jsonl"), String.duplicate(line, 300_000))

      {:ok, _view, html} = live(conn, ~p"/companies/acme")
      assert html =~ "Overview"
    end
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

  # #315 — "wake all" director-origin heartbeat broadcast.
  describe "wake all (#315)" do
    test "button renders in header", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme")
      assert html =~ "wake all"
      assert html =~ ~s(phx-click="wake_all")
    end

    test "click emits flash even with no running agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/companies/acme")
      html = render_click(view, "wake_all", %{})
      assert html =~ "No running agents to wake."
    end

    test "button disabled when emergency stop engaged", %{conn: conn, base: base} do
      # Engage emergency stop first
      :ok =
        Glorbo.EmergencyStop.engage("acme",
          base: base,
          actor: "director",
          audit_fun: fn _, _ -> :ok end,
          kill_fun: fn _ -> :ok end
        )

      {:ok, _view, html} = live(conn, ~p"/companies/acme")
      assert html =~ ~s(phx-click="wake_all")
      assert html =~ "disabled"
      assert html =~ "Emergency stop engaged"

      # Cleanup
      :ok =
        Glorbo.EmergencyStop.clear("acme",
          base: base,
          actor: "director",
          audit_fun: fn _, _ -> :ok end
        )
    end
  end
end
