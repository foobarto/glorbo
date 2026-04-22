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

  test "dm channel URL auto-creates + redirects to ChannelLive", %{conn: conn, base: base} do
    {:error, {:redirect, %{to: dest}}} = live(conn, "/companies/acme/dms/ceo")
    assert dest == "/companies/acme/channels/dm-director--ceo"

    # ensure_dm_channel/3 side-effect: the file was seeded.
    dm_path =
      Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"])

    assert File.exists?(dm_path)
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
end
