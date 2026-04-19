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

    ## 2026-04-16T10:00:00Z | Director
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

  test "sidebar marks Channels nav item active", %{conn: conn} do
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
    assert content =~ "| Director"
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

  test "dm rail lists every agent as a director↔agent thread", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")
    # The seeded fixture has one agent `ceo`; the rail should link to it.
    assert html =~ ~s(href="/companies/acme/dms/ceo")
    assert html =~ "director ↔ ceo"
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

  test "DM channel heading renders 'DM · director ↔ <agent>'", %{conn: conn, base: base} do
    File.write!(
      Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"]),
      "# DM\n"
    )

    {:ok, _view, html} = live(conn, "/companies/acme/channels/dm-director--ceo")
    assert html =~ "DM · director ↔ ceo"
    assert html =~ "Message ceo as Director"
  end

  test "message body with markdown sub-header stays intact", %{conn: conn, base: base} do
    # Regression: earlier regex treated ANY `## ` as a new message boundary,
    # so a multi-step plan with `## Step 1:` got split mid-body.
    path = Path.join([base, "companies", "acme", "channels", "general.md"])

    File.write!(path, """
    # general

    ## 2026-04-19T08:00:00Z | Director
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
end
