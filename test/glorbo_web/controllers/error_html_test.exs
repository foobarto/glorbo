defmodule GlorboWeb.ErrorHTMLTest do
  use GlorboWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    # Plan 04-03: 404 template carries 04-UI-SPEC §Error states copy.
    html = render_to_string(GlorboWeb.ErrorHTML, "404", "html", [])
    assert html =~ "Not found."
    assert html =~ "~/.glorbo/companies/"
    assert html =~ "glorbo reindex"
  end

  test "renders 500.html" do
    # Plan 04-03: 500 template carries 04-UI-SPEC §Error states copy.
    html = render_to_string(GlorboWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Something broke."
    assert html =~ "~/.glorbo/logs/"
  end

  test "falls back to Phoenix status-message for other templates" do
    assert render_to_string(GlorboWeb.ErrorHTML, "400", "html", []) == "Bad Request"
  end
end
