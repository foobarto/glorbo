defmodule GlorboWeb.PageController do
  @moduledoc false
  use GlorboWeb, :controller

  def health(conn, _params), do: send_resp(conn, 200, "ok")
end
