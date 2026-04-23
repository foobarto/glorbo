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

  describe "config tab (paperclip-ux-gaps §5)" do
    test "edit button flips to structured form", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      html = render_click(view, "config_edit", %{})
      assert html =~ ~s(phx-submit="config_save")
      assert html =~ ~s(name="model")
    end

    test "config_save writes allow-listed keys back to AGENT.md",
         %{conn: conn, base: base} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      render_click(view, "config_edit", %{})

      render_submit(view, "config_save", %{
        "provider" => "opencode",
        "model" => "lmstudio/qwen/qwen3.6-35b-a3b",
        "reports_to" => "",
        "heartbeat" => "* * * * *",
        "network" => "proxy"
      })

      agent_md = Path.join([base, "companies", "acme", "agents", "ceo", "AGENT.md"])
      content = File.read!(agent_md)
      assert content =~ "provider: opencode"
      assert content =~ "model: lmstudio/qwen/qwen3.6-35b-a3b"
      assert content =~ "network: proxy"
    end

    # #277 — reject an invalid heartbeat cron before it reaches disk.
    # Malformed cron used to save silently and the heartbeat scheduler
    # would log-and-skip forever; directors had no feedback.
    test "config_save rejects invalid heartbeat cron with inline error",
         %{conn: conn, base: base} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      render_click(view, "config_edit", %{})

      html =
        render_submit(view, "config_save", %{
          "provider" => "claude-code",
          "model" => "claude-sonnet-4-5",
          "reports_to" => "",
          "heartbeat" => "wutang-clan",
          "network" => "proxy"
        })

      assert html =~ "Invalid heartbeat cron"
      # Still in edit mode — nothing saved yet.
      assert html =~ ~s(phx-submit="config_save")

      # AGENT.md untouched (no "wutang-clan" present).
      agent_md =
        File.read!(Path.join([base, "companies", "acme", "agents", "ceo", "AGENT.md"]))

      refute agent_md =~ "wutang-clan"
    end

    test "config_save accepts blank heartbeat (no-heartbeat agent)",
         %{conn: conn, base: base} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      render_click(view, "config_edit", %{})

      render_submit(view, "config_save", %{
        "provider" => "claude-code",
        "model" => "claude-sonnet-4-5",
        "reports_to" => "",
        "heartbeat" => "",
        "network" => "proxy"
      })

      agent_md =
        File.read!(Path.join([base, "companies", "acme", "agents", "ceo", "AGENT.md"]))

      assert agent_md =~ "provider: claude-code"
    end

    # GEP-32 phase 4 — model datalist is populated from the cached
    # `provider_models` projection for the currently-selected provider,
    # so the director gets autocomplete suggestions alongside the free
    # text fallback.
    test "model datalist lists cached models for current provider",
         %{conn: conn} do
      Glorbo.Repo.insert_all(Glorbo.ProviderModel, [
        %{
          alias: "openai",
          model_id: "gpt-5-alpha",
          raw_json: "{}",
          refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        %{
          alias: "openai",
          model_id: "gpt-4o",
          raw_json: "{}",
          refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        %{
          alias: "openrouter",
          model_id: "other/model",
          raw_json: "{}",
          refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")

      # Flip the agent over to the openai provider so model_options loads its cache.
      render_click(view, "config_edit", %{})
      html = render_change(view, "config_form_change", %{"provider" => "openai", "model" => ""})

      assert html =~ ~s(id="gl-agent-model-options")
      assert html =~ "gpt-4o"
      assert html =~ "gpt-5-alpha"
      refute html =~ "other/model"
    end

    test "cancel returns to read-only view without writing", %{conn: conn, base: base} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      render_click(view, "config_edit", %{})
      html = render_click(view, "config_cancel", %{})
      refute html =~ ~s(phx-submit="config_save")

      agent_md = Path.join([base, "companies", "acme", "agents", "ceo", "AGENT.md"])
      before_ctime = File.stat!(agent_md).mtime
      :timer.sleep(10)
      # Confirm no write happened on cancel
      assert File.stat!(agent_md).mtime == before_ctime
    end
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

  test "runs tab groups dispatch + complete entries by invocation_id",
       %{conn: conn, base: base} do
    month = DateTime.utc_now() |> Calendar.strftime("%Y-%m")
    audit_path = Path.join([base, "companies", "acme", "audit", "#{month}.jsonl"])
    File.mkdir_p!(Path.dirname(audit_path))

    File.write!(audit_path, """
    {"ts":"2026-04-20T10:00:00Z","actor":"system","action":"agent.dispatch","target":"projects/foo/tasks/bar.md","detail":{"invocation_id":"abc12345","provider":"opencode","model":"lmstudio/qwen","agent":"ceo","trigger":"heartbeat"}}
    {"ts":"2026-04-20T10:00:05Z","actor":"ceo","action":"agent.complete","target":"projects/foo/tasks/bar.md","detail":{"invocation_id":"abc12345","duration_ms":5000,"exit_status":"0","reply_preview":"all done","agent":"ceo"}}
    """)

    {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
    html = render_click(view, "tab", %{"tab" => "runs"})

    # Short invocation id + trigger rendered in the row header.
    assert html =~ "abc12345"
    assert html =~ "heartbeat"
    # Status 'complete' set after the agent.complete event.
    assert html =~ "complete"
    # Click to expand -> reply preview visible.
    html = render_click(view, "toggle_run", %{"inv" => "abc12345"})
    assert html =~ "all done"
    assert html =~ "lmstudio/qwen"
  end

  test "runs tab empty state when no runs recorded",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
    html = render_click(view, "tab", %{"tab" => "runs"})
    assert html =~ "No runs yet"
  end

  # R17b — Memory tab on agent detail. Surfaces agent memory files
  # (GEP-21) so directors can read what the agent has remembered
  # without shelling into the filesystem.
  describe "memory tab (GEP-21, R17b)" do
    test "empty state when no memory dir", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      html = render_click(view, "tab", %{"tab" => "memory"})
      assert html =~ "No memories yet"
    end

    test "lists memory files with frontmatter", %{conn: conn, base: base} do
      memory_dir = Path.join([base, "companies/acme/agents/ceo/memory"])
      File.mkdir_p!(memory_dir)

      File.write!(Path.join(memory_dir, "feedback_tone.md"), """
      ---
      name: Director tone
      description: concise, dry, no emoji
      type: feedback
      ---

      Rule: keep replies short.
      """)

      File.write!(Path.join(memory_dir, "MEMORY.md"), """
      - [Director tone](feedback_tone.md) — concise, dry, no emoji
      """)

      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      html = render_click(view, "tab", %{"tab" => "memory"})

      # Index section.
      assert html =~ "MEMORY.md"
      assert html =~ "Director tone"
      # Individual entry.
      assert html =~ "feedback_tone.md"
      assert html =~ "concise, dry, no emoji"
      assert html =~ "Rule: keep replies short"
      # Type pill.
      assert html =~ "gl-pill--feedback"
    end

    test "filters out invalid filenames", %{conn: conn, base: base} do
      memory_dir = Path.join([base, "companies/acme/agents/ceo/memory"])
      File.mkdir_p!(memory_dir)

      File.write!(Path.join(memory_dir, "feedback_ok.md"), """
      ---
      name: valid memory
      type: feedback
      ---

      keep me
      """)

      File.write!(Path.join(memory_dir, "random_nope.md"), "invalid type prefix")
      File.write!(Path.join(memory_dir, "not_markdown.txt"), "ignored")

      {:ok, view, _} = live(conn, ~p"/companies/acme/agents/ceo")
      html = render_click(view, "tab", %{"tab" => "memory"})

      assert html =~ "valid memory"
      refute html =~ "invalid type prefix"
      refute html =~ "not_markdown.txt"
    end
  end

  test "+ assign task button links to Kanban with assignee prefilled",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/agents/ceo")
    assert html =~ "+ assign task"
    # Query string should carry both the assignee and the return-to
    # target so Cancel bounces back here.
    assert html =~ "assignee=ceo"
    assert html =~ "return_to=%2Fcompanies%2Facme%2Fagents%2Fceo"
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
    network: proxy
    heartbeat: null
    permissions:
      - projects:read:*
    ---

    # #{slug}
    """)

    :ok
  end
end
