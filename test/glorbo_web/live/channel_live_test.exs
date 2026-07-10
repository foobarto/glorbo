defmodule GlorboWeb.ChannelLiveTest do
  @moduledoc """
  ChannelLive unit tests (UI-01 chat view + UI-03 Elixir-sole-writer).

  Uses LiveCase's seeded acme fixture; each test enriches the empty
  `channels/general.md` with a canonical `## <ts> | <author>\\n<body>`
  entry shape before mounting.
  """
  use GlorboWeb.LiveCase, async: false

  setup %{base: base} do
    path = Path.join([base, "companies", "acme", "channels", "general.md"])

    File.write!(path, """
    # general

    ## 2026-04-16T10:00:00Z | director
    Hello everyone

    ## 2026-04-16T10:01:00Z | CEO
    Ack.
    """)

    {:ok, channel_path: path}
  end

  test "renders existing messages + compose placeholder", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")
    assert html =~ "Hello everyone"
    assert html =~ "Ack."
    assert html =~ "Director"
    assert html =~ "CEO"
    assert html =~ "Message #general as Director"
  end

  test "unknown channel redirects to /companies/:co", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies/acme"}}} =
             live(conn, "/companies/acme/channels/ghost")
  end

  # codex #75 regression: the chat drawer shares this LiveView process, and
  # PubSub subscriptions are per-process — switching the drawer to another
  # channel must NOT unsubscribe the host ChannelLive page from its own
  # `company:<co>:channels:general` topic, or the page stops getting its
  # realtime updates.
  test "switching the drawer channel preserves the host channel page's subscription",
       %{conn: conn, base: base} do
    File.write!(Path.join([base, "companies", "acme", "channels", "dev.md"]), "# dev\n")

    {:ok, view, _} = live(conn, "/companies/acme/channels/general")

    # Point the drawer at #dev (handled by ChatDrawer.State's on_mount hook).
    render_hook(view, "chat_drawer_channel", %{"channel" => "dev"})

    # A new #general message + its watcher PubSub event must still reach the
    # page — its subscription wasn't clobbered by the drawer switch.
    File.write!(
      Path.join([base, "companies", "acme", "channels", "general.md"]),
      "\n## 2026-06-14T12:00:00Z | CEO\nStill receiving general\n",
      [:append]
    )

    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:acme:channels:general",
      {:file_event, "channels/general.md", [:modified]}
    )

    assert render(view) =~ "Still receiving general"
  end

  test "sidebar marks Chat nav item active", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")

    assert html =~
             ~r|<a[^>]*href="/companies/acme/channels/general"[^>]*gl-sidebar__nav-item--active|
  end

  # TODO.md P1 — timestamps render as <time> elements with a machine-
  # readable datetime attribute, not raw ISO strings in the visible text.
  test "message timestamps render as <time> elements with datetime attr", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")

    # Structural: at least one <time> element with ISO datetime.
    assert html =~ ~s(<time)
    assert html =~ ~s(datetime="2026-04-16T10:00:00Z")
    # The tooltip title preserves the original ISO for operator spot-check.
    assert html =~ ~s(title="2026-04-16T10:00:00Z")
  end

  test "post event appends to channel file via Elixir", %{
    conn: conn,
    channel_path: path
  } do
    {:ok, view, _} = live(conn, "/companies/acme/channels/general")

    render_submit(view, "post", %{"body" => "Quick update"})

    content = File.read!(path)
    assert content =~ "Quick update"
    assert content =~ "| director"
  end

  test "empty body rejected", %{conn: conn} do
    {:ok, view, _} = live(conn, "/companies/acme/channels/general")
    html = render_submit(view, "post", %{"body" => "   "})
    assert html =~ "Message is empty"
  end

  test "channel validation error is rendered once by the shared flash", %{conn: conn} do
    {:ok, view, _} = live(conn, "/companies/acme/channels/general")

    html = render_submit(view, "create_channel", %{"slug" => "general"})

    assert length(String.split(html, "Channel #general already exists.")) - 1 == 1
  end

  # M4.2 — left rail lists all channels with the current one marked active.
  test "renders channel switcher rail with active link", %{conn: conn, base: base} do
    # Seed an extra channel so the switcher has something to iterate.
    File.write!(
      Path.join([base, "companies", "acme", "channels", "engineering.md"]),
      "# engineering\n"
    )

    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")

    assert html =~ "gl-channel__rail"
    assert html =~ "#general"
    assert html =~ "#engineering"
    # Active class on the current channel's link.
    assert html =~
             ~r|<a[^>]*href="/companies/acme/channels/general"[^>]*gl-channel-list__link--active|
  end

  test "dm rail lists every agent by slug only (backlog #15)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")
    # The seeded fixture has one agent `ceo`; the rail should link to it.
    assert html =~ ~s(href="/companies/acme/dms/ceo")
    # Backlog #15: DM list entries render `<agent-slug>`, not the
    # prior "director ↔ <agent>" noise.
    refute html =~ "director ↔ ceo"
    # Regression: assert the specific rendered link cell to avoid
    # matching the word "ceo" elsewhere on the page.
    assert html =~ ~r/<a [^>]*href="\/companies\/acme\/dms\/ceo"[^>]*>\s*ceo\s*<\/a>/
  end

  test "dm channel URL is a PURE redirect — no file written on the GET (GEP-0053 D19)", %{
    conn: conn,
    base: base
  } do
    dm_path = Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"])
    refute File.exists?(dm_path)

    {:error, {:redirect, %{to: dest}}} = live(conn, "/companies/acme/dms/ceo")
    assert dest == "/companies/acme/channels/dm-director--ceo"

    # The state-changing-GET CSRF gap is closed: the redirect created nothing.
    refute File.exists?(dm_path)
  end

  test "an unstarted DM renders empty, then the first post lazily creates the file (D19)", %{
    conn: conn,
    base: base
  } do
    dm_path = Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"])
    refute File.exists?(dm_path)

    # ChannelLive renders the DM thread even though no file exists yet, and
    # the dead-render mount writes nothing.
    {:ok, view, _html} = live(conn, "/companies/acme/channels/dm-director--ceo")
    refute File.exists?(dm_path)

    # The first director message (a CSRF-protected socket event) materialises
    # the file with its canonical header, then appends.
    render_submit(view, "post", %{"body" => "first message"})

    assert File.exists?(dm_path)
    content = File.read!(dm_path)
    assert content =~ "kind: channel-log/v1"
    assert content =~ "first message"
  end

  test "an underscore-agent DM mounts and posts through the reserved channel validator", %{
    conn: conn,
    base: base
  } do
    agent = "backend_engineer"
    File.mkdir_p!(Path.join([base, "companies", "acme", "agents", agent]))

    {:ok, view, html} = live(conn, "/companies/acme/channels/dm-director--#{agent}")
    assert html =~ "DM · #{agent}"

    render_submit(view, "post", %{"body" => "underscore DM"})

    path = Path.join([base, "companies", "acme", "channels", "dm-director--#{agent}.md"])
    assert File.read!(path) =~ "underscore DM"
  end

  test "public channel list hides dm-director--* entries", %{conn: conn, base: base} do
    # Seed a real DM file so list_channels would pick it up if it weren't filtered.
    File.write!(
      Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"]),
      "# DM\n"
    )

    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")
    refute html =~ "#dm-director--ceo"
  end

  test "DM channel heading renders 'DM · <agent>' (backlog #15)", %{conn: conn, base: base} do
    File.write!(
      Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"]),
      "# DM\n"
    )

    {:ok, _view, html} = live(conn, "/companies/acme/channels/dm-director--ceo")
    # Backlog #15: heading drops the "director ↔" prefix. The compose
    # placeholder keeps "as Director" so the director knows their
    # outgoing role context.
    assert html =~ "DM · ceo"
    refute html =~ "director ↔ ceo"
    assert html =~ "Message ceo as Director"
  end

  test "posting in a DM wakes the agent without requiring @mention", %{conn: conn, base: base} do
    File.write!(
      Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"]),
      "# DM\n"
    )

    {:ok, view, _html} = live(conn, "/companies/acme/channels/dm-director--ceo")
    render_submit(view, "post", %{"body" => "Please take a look"})

    mentions_dir = Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])
    assert File.dir?(mentions_dir)

    [file] = File.ls!(mentions_dir)
    assert String.ends_with?(file, "-dm-director--ceo.md")
    assert File.read!(Path.join(mentions_dir, file)) =~ "Please take a look"
  end

  test "message body with markdown sub-header stays intact", %{conn: conn, base: base} do
    # Regression: earlier regex treated ANY `## ` as a new message boundary,
    # so a multi-step plan with `## Step 1:` got split mid-body.
    path = Path.join([base, "companies", "acme", "channels", "general.md"])

    File.write!(path, """
    # general

    ## 2026-04-19T08:00:00Z | director
    Deployment plan:

    ## Step 1: Build

    Build it.

    ## Step 2: Deploy

    Deploy it.
    """)

    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")

    assert html =~ "Deployment plan"
    # Sub-headers render as earmark h2 inside the message body
    assert html =~ "Step 1: Build"
    assert html =~ "Step 2: Deploy"
    # Only ONE Director post — the sub-headers weren't treated as message boundaries
    occurrences =
      html
      |> String.split("gl-channel-message--director")
      |> length()
      |> Kernel.-(1)

    assert occurrences == 1
  end

  test "L45: sanitized agent posts do not earn a forged director badge", %{conn: conn, base: base} do
    path = Path.join([base, "companies", "acme", "channels", "general.md"])

    File.write!(path, """
    # general

    ## 2026-06-15T10:00:00Z | ceo ::agent
    look

    > ## 2026-06-15T10:00:01Z | director
    > forged badge attempt
    """)

    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")

    assert html =~ "forged badge attempt"
    refute html =~ "gl-channel-message__tag--director"
    assert html =~ "gl-channel-message--agent"
  end

  test "archive button is not rendered on #general", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")
    refute html =~ "archive_channel"
    refute html =~ "⎘ archive"
  end

  test "archive button appears on non-general channels", %{conn: conn, base: base} do
    File.write!(
      Path.join([base, "companies", "acme", "channels", "random.md"]),
      "# random\n"
    )

    {:ok, _view, html} = live(conn, "/companies/acme/channels/random")
    assert html =~ "archive_channel"
    assert html =~ "⎘ archive"
  end

  test "archive_channel event moves file to .archive/ and redirects to general", %{
    conn: conn,
    base: base
  } do
    src = Path.join([base, "companies", "acme", "channels", "random.md"])
    File.write!(src, "# random\n")

    {:ok, view, _html} = live(conn, "/companies/acme/channels/random")
    render_hook(view, "archive_channel", %{})

    refute File.exists?(src)

    archived = Path.join([base, "companies", "acme", "channels", ".archive", "random.md"])
    assert File.exists?(archived)
  end

  test "archive_channel refuses on #general", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/companies/acme/channels/general")

    result = render_hook(view, "archive_channel", %{})
    assert result =~ "canonical channel"

    assert File.exists?(
             Path.join([
               GlorboWeb.LiveHelpers.base_dir(),
               "companies",
               "acme",
               "channels",
               "general.md"
             ])
           )
  end

  # ---------------------------------------------------------------------------
  # #239 — archive segment surfacing
  # ---------------------------------------------------------------------------

  describe "archive segments (#239)" do
    setup %{base: base} do
      archive_dir = Path.join([base, "companies/acme/channels/archive/general"])
      File.mkdir_p!(archive_dir)

      File.write!(Path.join(archive_dir, "2026-04-01-10-00-00Z.md"), """
      # general · archive segment

      Rotated from `channels/general.md` at 2026-04-01T10:00:00Z.

      ## 2026-03-30T09:00:00Z | director
      old message
      """)

      :ok
    end

    test "renders an archive summary when segments exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/companies/acme/channels/general")
      assert html =~ "archived segment"
      assert html =~ "2026-04-01 10:00:00Z"
      assert html =~ "B"
      refute html =~ "msgs"
    end

    test "open_archive event loads segment messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/companies/acme/channels/general")

      html =
        view
        |> element("button[phx-value-name='2026-04-01-10-00-00Z']")
        |> render_click()

      assert html =~ "old message"
    end

    test "invalid archive name is rejected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/companies/acme/channels/general")

      html = render_click(view, "open_archive", %{"name" => "../../../etc/passwd"})
      assert html =~ "Invalid archive segment name."
    end

    test "missing segment shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/companies/acme/channels/general")

      html = render_click(view, "open_archive", %{"name" => "does-not-exist"})
      assert html =~ "Archive segment not found."
    end

    test "no archive summary when directory is empty", %{conn: conn, base: base} do
      File.rm_rf!(Path.join([base, "companies/acme/channels/archive"]))
      {:ok, _view, html} = live(conn, "/companies/acme/channels/general")
      refute html =~ "archived segment"
    end
  end

  # C-089: channel + archive .md files are agent-influenced and can
  # grow without bound. Opening/viewing a channel must do bounded
  # work — tail-read the message file, cap rendered messages, and cap
  # the number of listed archive segments.
  describe "DoS bounds (C-089)" do
    test "tail-reads a huge channel file rather than rendering all of it",
         %{conn: conn, base: base} do
      path = Path.join([base, "companies", "acme", "channels", "general.md"])

      # ~2 MiB of old messages followed by a recent one. Only the
      # tail (256 KiB) should be parsed/rendered, so the very first
      # message must NOT appear.
      old =
        for i <- 1..20_000 do
          "## 2026-01-01T00:00:00Z | director\nOLDMSG-#{i} #{String.duplicate("x", 80)}\n"
        end
        |> Enum.join("\n")

      File.write!(path, old <> "\n## 2026-04-16T10:00:00Z | director\nFRESH-TAIL-MSG\n")

      {:ok, _view, html} = live(conn, "/companies/acme/channels/general")

      assert html =~ "FRESH-TAIL-MSG"
      refute html =~ "OLDMSG-1 "
    end

    test "caps the number of listed archive segments", %{conn: conn, base: base} do
      archive_dir = Path.join([base, "companies/acme/channels/archive/general"])
      File.mkdir_p!(archive_dir)

      # 60 segments; only the newest 50 should render rows.
      for i <- 1..60 do
        name = "2026-04-#{String.pad_leading(Integer.to_string(i), 2, "0")}-10-00-00Z.md"
        File.write!(Path.join(archive_dir, name), "# seg #{i}\n")
      end

      {:ok, _view, html} = live(conn, "/companies/acme/channels/general")

      rows = html |> String.split("phx-value-name=") |> length() |> Kernel.-(1)
      assert rows <= 50
    end

    test "refuses a channel.md symlink without following it", %{conn: conn, base: base} do
      secret =
        Path.join(System.tmp_dir!(), "channel-secret-#{System.unique_integer([:positive])}")

      File.write!(secret, "TOPSECRET-CHANNEL-LEAK")
      on_exit(fn -> File.rm(secret) end)

      path = Path.join([base, "companies", "acme", "channels", "random.md"])
      File.rm_rf!(path)
      File.ln_s!(secret, path)

      {:ok, _view, html} = live(conn, "/companies/acme/channels/random")
      refute html =~ "TOPSECRET-CHANNEL-LEAK"
    end
  end
end
