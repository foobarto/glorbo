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

  test "renders the CompanyTabs strip with :chat active", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/companies/acme/channels/general")

    assert html =~
             ~r|<a[^>]*href="/companies/acme/channels/general"[^>]*class="[^"]*gl-tab gl-tab--active|
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
end
