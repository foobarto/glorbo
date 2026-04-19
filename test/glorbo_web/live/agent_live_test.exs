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

  test "history tab lists audit activity filtered to this agent",
       %{conn: conn, base: base} do
    # Seed a mix of audit entries so we can check the filter. Write
    # current-month file — AgentLive reads YYYY-MM.jsonl.
    month =
      DateTime.utc_now()
      |> Calendar.strftime("%Y-%m")

    audit_path = Path.join([base, "companies", "acme", "audit", "#{month}.jsonl"])
    File.mkdir_p!(Path.dirname(audit_path))

    File.write!(audit_path, """
    {"ts":"2026-04-18T10:00:00Z","actor":"ceo","action":"agent.dispatch","target":null,"detail":{"provider":"claude-code","model":"claude-sonnet-4-5","agent":"ceo"}}
    {"ts":"2026-04-18T10:00:01Z","actor":"system","action":"agent.heartbeat_skipped","target":"agents/engineer","detail":{"reason":"no_heartbeat_file"}}
    {"ts":"2026-04-18T10:00:02Z","actor":"director","action":"agent.wake_request","target":"agents/ceo","detail":{"reason":""}}
    """)

    {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
    html = render_click(view, "tab", %{"tab" => "history"})

    # Both ceo-related rows present (dispatch + wake_request), the
    # engineer-scoped heartbeat_skipped filtered out.
    assert html =~ "agent.dispatch"
    assert html =~ "agent.wake_request"
    refute html =~ "agent.heartbeat_skipped"
  end

  # Regression (task #121, 2026-04-18): the inbox/outbox tab used
  # `:if={not @detail.inbox.latest}` where `latest` is a map, not a
  # boolean. `not map` raises ArgumentError, crashing the LiveView on
  # tab-click. Covered now so the HEEX stays boolean-safe.
  test "inbox/outbox tab renders without crashing the LiveView",
       %{conn: conn, base: base} do
    # Seed a non-empty inbox so `latest` is a map (the crash trigger).
    ag = Path.join([base, "companies", "acme", "agents", "ceo"])
    File.mkdir_p!(Path.join(ag, "inbox"))

    File.write!(Path.join([ag, "inbox", "hello.md"]), """
    ---
    from: director
    ---

    hi
    """)

    {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")

    # Pre-fix this raised ArgumentError; now returns normal HTML.
    html = render_click(view, "tab", %{"tab" => "inbox"})
    assert html =~ "inbox/outbox"
  end

  # task #117 — workspace file tree + edit overlay.
  describe "workspace file editor" do
    test "open_file opens workspace files via the widened resolver",
         %{conn: conn, base: base} do
      workspace = Path.join([base, "companies/acme/agents/ceo/workspace"])
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "notes.md"), "initial content")

      {:ok, view, _html} = live(conn, ~p"/companies/acme/agents/ceo")

      # Task #143 — the top-level "files" panel no longer enumerates
      # workspace files individually (it shows subdirs with counts).
      # The open_file handler still accepts workspace-relative paths
      # via the widened resolver.
      html = render_click(view, "open_file", %{"path" => "workspace/notes.md"})
      assert html =~ "initial content"
      assert html =~ "gl-file-editor"
    end

    test "save_file writes new content to disk",
         %{conn: conn, base: base} do
      workspace = Path.join([base, "companies/acme/agents/ceo/workspace"])
      File.mkdir_p!(workspace)
      path = Path.join(workspace, "notes.md")
      File.write!(path, "v1")

      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      render_click(view, "open_file", %{"path" => "workspace/notes.md"})
      render_submit(view, "save_file", %{"content" => "v2 changed"})

      assert File.read!(path) == "v2 changed"
    end

    test "traversal attempts are rejected",
         %{conn: conn, base: base} do
      workspace = Path.join([base, "companies/acme/agents/ceo/workspace"])
      File.mkdir_p!(workspace)

      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      html = render_click(view, "open_file", %{"path" => "../../etc/passwd"})

      assert html =~ "Invalid path"
      refute html =~ "gl-file-editor"
    end

    test "binary files are refused",
         %{conn: conn, base: base} do
      workspace = Path.join([base, "companies/acme/agents/ceo/workspace"])
      File.mkdir_p!(workspace)
      # Write a file with NUL bytes in the first 4 KiB.
      File.write!(Path.join(workspace, "blob.bin"), <<0, 1, 2, 3, 0, 255>>)

      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      html = render_click(view, "open_file", %{"path" => "workspace/blob.bin"})

      assert html =~ "Binary file"
    end
  end

  # task #143 — agent dir file manager: contracts + subdirs + actions.
  describe "agent file manager (#143)" do
    test "lists contract files and directories", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/agents/ceo")

      # Contract files named in @contract_files are always listed.
      for name <- ~w(AGENT.md HEARTBEAT.md SOUL.md stdout.log), do: assert(html =~ name)
      # Subdirs listed with counts.
      for name <- ~w(inbox outbox history state workspace), do: assert(html =~ "#{name}/")
    end

    test "create_file on a missing contract creates it and opens editor",
         %{conn: conn, base: base} do
      ag = Path.join([base, "companies/acme/agents/ceo"])
      # Ensure SOUL.md doesn't exist in the fixture.
      File.rm(Path.join(ag, "SOUL.md"))

      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      html = render_click(view, "create_file", %{"path" => "SOUL.md"})

      # File now exists and editor is open for it.
      assert File.exists?(Path.join(ag, "SOUL.md"))
      assert html =~ "gl-file-editor"
    end

    test "delete_file soft-deletes via history/deleted/",
         %{conn: conn, base: base} do
      ag = Path.join([base, "companies/acme/agents/ceo"])
      File.write!(Path.join(ag, "HEARTBEAT.md"), "test body")

      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      html = render_click(view, "delete_file", %{"path" => "HEARTBEAT.md"})

      refute File.exists?(Path.join(ag, "HEARTBEAT.md"))
      # Moved to history/deleted/<ts>-HEARTBEAT.md
      {:ok, deleted} = File.ls(Path.join([ag, "history", "deleted"]))
      assert Enum.any?(deleted, &String.ends_with?(&1, "-HEARTBEAT.md"))

      assert html =~ "Moved"
    end

    test "delete_file refuses AGENT.md",
         %{conn: conn, base: base} do
      ag = Path.join([base, "companies/acme/agents/ceo"])

      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      html = render_click(view, "delete_file", %{"path" => "AGENT.md"})

      assert File.exists?(Path.join(ag, "AGENT.md"))
      assert html =~ "load-bearing"
    end
  end

  # task #118 — SOUL.md renders as an identity-column panel when
  # present; absent = no panel.
  describe "SOUL.md rendering" do
    test "shows a soul panel when SOUL.md exists",
         %{conn: conn, base: base} do
      ag = Path.join([base, "companies/acme/agents/ceo"])
      File.mkdir_p!(ag)

      File.write!(Path.join(ag, "SOUL.md"), """
      ---
      role: "CEO"
      ---

      Direct. Quiet. Pragmatic.
      """)

      {:ok, _view, html} = live(conn, ~p"/companies/acme/agents/ceo")
      assert html =~ "gl-agent-soul"
      assert html =~ "Direct. Quiet. Pragmatic"
      # Frontmatter is stripped — don't render the --- delimiters in body.
      refute html =~ ~s(role: "CEO")
    end

    test "no soul panel when SOUL.md is missing",
         %{conn: conn, base: base} do
      # Default fixture doesn't ship a SOUL.md; confirm the panel is
      # absent.
      soul_path = Path.join([base, "companies/acme/agents/ceo/SOUL.md"])
      File.rm(soul_path)

      {:ok, _view, html} = live(conn, ~p"/companies/acme/agents/ceo")
      refute html =~ "gl-agent-soul"
    end
  end

  describe "retire" do
    test "retire button not rendered for ceo", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/companies/acme/agents/ceo")
      refute html =~ "🗃 retire"
      refute html =~ ~s(phx-click="retire")
    end

    test "retire button rendered for non-ceo agents",
         %{conn: conn, base: base} do
      seed_engineer(base, "alice")

      {:ok, _view, html} = live(conn, ~p"/companies/acme/agents/alice")
      assert html =~ "🗃 retire"
      assert html =~ ~s(phx-click="retire")
    end

    test "retire event refuses on ceo", %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, ~p"/companies/acme/agents/ceo")

      result = render_hook(view, "retire", %{})
      assert result =~ "load-bearing role"

      assert File.dir?(Path.join([base, "companies/acme/agents/ceo"]))
    end

    test "retire moves a non-ceo agent dir to agents/.archive/ and navigates to company page",
         %{conn: conn, base: base} do
      seed_engineer(base, "bob")
      eng_dir = Path.join([base, "companies/acme/agents/bob"])

      {:ok, view, _html} = live(conn, ~p"/companies/acme/agents/bob")

      assert {:error, {:live_redirect, %{to: "/companies/acme"}}} =
               render_hook(view, "retire", %{})

      refute File.exists?(eng_dir)

      archive_root = Path.join([base, "companies/acme/agents/.archive"])
      assert {:ok, archived_children} = File.ls(archive_root)
      assert Enum.any?(archived_children, &String.starts_with?(&1, "bob-"))
    end
  end

  defp seed_engineer(base, slug) do
    eng_dir = Path.join([base, "companies/acme/agents", slug])
    Enum.each(~w(inbox outbox workspace history state), &File.mkdir_p!(Path.join(eng_dir, &1)))

    File.write!(Path.join(eng_dir, "AGENT.md"), """
    ---
    name: #{slug}
    role: Engineer
    provider: claude-code
    model: claude-sonnet-4-5
    network: api-only
    heartbeat: null
    permissions:
      - projects:read:*
    ---

    # #{slug}
    """)

    :ok
  end
end
