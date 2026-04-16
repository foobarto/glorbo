defmodule GlorboWeb.PageControllerTest do
  use GlorboWeb.ConnCase

  test "GET /health-legacy returns 200 ok", %{conn: conn} do
    conn = get(conn, ~p"/health-legacy")
    assert response(conn, 200) == "ok"
  end

  test "GET / redirects to /companies", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/companies"
  end
end
