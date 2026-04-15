defmodule GlorboWeb.PageControllerTest do
  use GlorboWeb.ConnCase

  test "GET /health returns 200 ok", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert response(conn, 200) == "ok"
  end
end
