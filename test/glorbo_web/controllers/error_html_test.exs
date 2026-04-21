defmodule GlorboWeb.ErrorHTMLTest do
  use GlorboWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    # R32: path labels route through display_base() — resolves to
    # `~/.glorbo` for default home, absolute override otherwise
    # (tests typically set GLORBO_HOME to /tmp/...). Assert the
    # suffix rather than the base.
    html = render_to_string(GlorboWeb.ErrorHTML, "404", "html", [])
    assert html =~ "Not found."
    assert html =~ "/companies/"
    assert html =~ "glorbo reindex"
  end

  test "renders 500.html" do
    html = render_to_string(GlorboWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Something broke."
    assert html =~ "/logs/"
  end

  test "falls back to Phoenix status-message for other templates" do
    assert render_to_string(GlorboWeb.ErrorHTML, "400", "html", []) == "Bad Request"
  end
end
