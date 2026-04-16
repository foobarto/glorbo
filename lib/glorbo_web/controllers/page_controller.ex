defmodule GlorboWeb.PageController do
  @moduledoc false
  use GlorboWeb, :controller

  def health(conn, _params), do: send_resp(conn, 200, "ok")

  @doc """
  Redirect `GET /` to the multi-company overview (`/companies`).
  Plan 04-02 Task 1 entry point for the LiveView dashboard (D-08).
  """
  def redirect_to_companies(conn, _params), do: redirect(conn, to: ~p"/companies")
end
