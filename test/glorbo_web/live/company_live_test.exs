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

  # P1 — submitting the new-project modal form scaffolds
  # projects/<slug>/project.md on disk (status:active) and flashes
  # the created-project confirmation. Exercises the
  # `new_project_create` handle_event → Scaffold.Project path end to
  # end. No `?wizard=` query param, so the non-wizard branch fires
  # (plain flash, no push_patch chain).
  test "new_project_create scaffolds projects/<slug>/project.md on disk",
       %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, ~p"/companies/acme")

    # `marketing` doesn't collide with the seeded `website` project,
    # so we hit the create branch (not the "already exists" no-op).
    proj_md = Path.join([base, "companies", "acme", "projects", "marketing", "project.md"])
    refute File.exists?(proj_md)

    html = render_submit(view, "new_project_create", %{"slug" => "marketing"})

    # Modal closes and the flash confirms the scaffold.
    assert html =~ "Created project: marketing"

    # project.md scaffolded on disk with the active-status frontmatter
    # block Scaffold.Project.do_scaffold/3 writes.
    assert File.exists?(proj_md)
    contents = File.read!(proj_md)
    assert contents =~ "kind: project/v1"
    assert contents =~ "slug: marketing"
    assert contents =~ "status: active"

    # README.md sibling is part of the same scaffold.
    assert File.exists?(
             Path.join([base, "companies", "acme", "projects", "marketing", "README.md"])
           )
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

  # Direct (non-wizard) `new_agent_create` coverage. The wizard-chain
  # test above only proves the success path *patches* to the next
  # wizard step; it never asserts the on-disk AGENT.md scaffold nor any
  # of the three reject paths (duplicate / invalid slug / reserved
  # `mcp`). Those all run through `Glorbo.CLI.Scaffold.Agent.run/1`,
  # which `base_dir()` points at the per-test tmp tree (LiveCase sets
  # `:glorbo_base`; no `GLORBO_HOME` in play).
  describe "new_agent_create (direct, non-wizard)" do
    test "writes a valid AGENT.md scaffold to disk with default frontmatter",
         %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, ~p"/companies/acme")

      html =
        render_submit(view, "new_agent_create", %{
          "slug" => "new-eng",
          "role" => "Backend Engineer",
          "provider" => ""
        })

      assert html =~ "Created agent: new-eng"

      agent_md =
        Path.join([base, "companies", "acme", "agents", "new-eng", "AGENT.md"])

      assert File.exists?(agent_md)
      body = File.read!(agent_md)

      # D-12 contract defaults — must match Scaffold.Agent.scaffold_default/4.
      assert body =~ "kind: agent/v1"
      assert body =~ "slug: new-eng"
      # name: is the slug upcased (`new-eng` -> `NEW-ENG`).
      assert body =~ "name: NEW-ENG"
      assert body =~ ~s(role: "Backend Engineer")
      # Empty provider falls back to the claude-code default.
      assert body =~ "provider: claude-code"
      assert body =~ "model: claude-sonnet-4-5"
      assert body =~ "network: proxy"
      assert body =~ "heartbeat: null"
      # threatmodel M21: fresh agents start with zero permissions.
      assert body =~ "permissions: []"
      assert body =~ "monthly_usd: 10.00"

      # Canonical sub-dir layout is scaffolded alongside AGENT.md.
      ag_dir = Path.join([base, "companies", "acme", "agents", "new-eng"])

      for sub <- ~w(inbox outbox workspace history state) do
        assert File.dir?(Path.join(ag_dir, sub))
      end
    end

    test "duplicate slug (ceo) is a no-op and does not overwrite the seeded AGENT.md",
         %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, ~p"/companies/acme")

      ceo_md =
        Path.join([base, "companies", "acme", "agents", "ceo", "AGENT.md"])

      before = File.read!(ceo_md)

      html =
        render_submit(view, "new_agent_create", %{
          "slug" => "ceo",
          "role" => "Impostor",
          "provider" => ""
        })

      # Scaffold returns exit 0 with an "already exists" message; the LV
      # rewrites it to the friendly no-change flash.
      assert html =~ "Agent ceo already exists"

      # The seeded CEO AGENT.md (role "Chief Executive Officer") is
      # byte-for-byte untouched — no clobber, no role: "Impostor".
      assert File.read!(ceo_md) == before
      refute File.read!(ceo_md) =~ "Impostor"
    end

    test "invalid slug (uppercase + space) is rejected with an error flash and no dir",
         %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, ~p"/companies/acme")

      html =
        render_submit(view, "new_agent_create", %{
          "slug" => "Bad Name",
          "role" => "",
          "provider" => ""
        })

      assert html =~ "Invalid slug in"

      # Neither the trimmed-but-spaced nor an upcased variant lands a dir.
      refute File.exists?(Path.join([base, "companies", "acme", "agents", "Bad Name"]))
      refute File.exists?(Path.join([base, "companies", "acme", "agents", "Bad"]))
    end

    test "reserved slug `mcp` is refused with an error flash and no dir",
         %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, ~p"/companies/acme")

      html =
        render_submit(view, "new_agent_create", %{
          "slug" => "mcp",
          "role" => "",
          "provider" => ""
        })

      assert html =~ "Refusing to scaffold reserved agent slug"
      refute File.exists?(Path.join([base, "companies", "acme", "agents", "mcp"]))
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
