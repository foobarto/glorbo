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
    test "lists real workspace files and opens editor for them",
         %{conn: conn, base: base} do
      workspace = Path.join([base, "companies/acme/agents/ceo/workspace"])
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "notes.md"), "initial content")

      {:ok, view, html} = live(conn, ~p"/companies/acme/agents/ceo")

      # File appears in the tree as a clickable button.
      assert html =~ "notes.md"
      assert html =~ "phx-click=\"open_file\""
      assert html =~ ~s(phx-value-path="notes.md")

      # Click opens the editor with the file's content.
      html = render_click(view, "open_file", %{"path" => "notes.md"})
      assert html =~ "initial content"
      assert html =~ "workspace/"
      assert html =~ "gl-file-editor"
    end

    test "save_file writes new content to disk",
         %{conn: conn, base: base} do
      workspace = Path.join([base, "companies/acme/agents/ceo/workspace"])
      File.mkdir_p!(workspace)
      path = Path.join(workspace, "notes.md")
      File.write!(path, "v1")

      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      render_click(view, "open_file", %{"path" => "notes.md"})
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
      html = render_click(view, "open_file", %{"path" => "blob.bin"})

      assert html =~ "Binary file"
    end
  end
end
