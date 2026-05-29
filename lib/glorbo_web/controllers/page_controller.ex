defmodule GlorboWeb.PageController do
  @moduledoc false
  use GlorboWeb, :controller

  def health(conn, _params), do: send_resp(conn, 200, "ok")

  @doc """
  Redirect `GET /` to the multi-company overview (`/companies`).
  Plan 04-02 Task 1 entry point for the LiveView dashboard (D-08).
  """
  def redirect_to_companies(conn, _params), do: redirect(conn, to: ~p"/companies")

  @doc """
  DMs are regular channels with a reserved `dm-director--<agent>` name.
  This is a **pure redirect** into the normal channel route (GEP-0053
  D19): it does NOT create the channel file. A state-changing GET is
  CSRF-forgeable under `SameSite=Lax`, so the DM file is created lazily on
  the first director message (`ChannelLive`'s `post` event, over the
  CSRF-protected socket); `ChannelLive` renders an empty DM thread until
  then. We still verify the agent exists (a read) so a typo'd link bounces
  with a flash instead of opening a phantom thread.

  Director-side DMs only for v0.0.3. Agent↔agent DMs (the existing
  outbox→inbox pattern in `Glorbo.Company.Router`) are a separate
  surface.
  """
  def redirect_to_dm(conn, %{"company" => co, "agent" => agent}) do
    with true <- Glorbo.Slug.valid?(co),
         true <- Glorbo.Slug.valid?(agent) do
      base = Glorbo.Filesystem.Hierarchy.default_root()
      agent_dir = Path.join([base, "companies", co, "agents", agent])

      if File.dir?(agent_dir) do
        redirect(conn, to: ~p"/companies/#{co}/channels/dm-director--#{agent}")
      else
        conn
        |> put_flash(:error, "Agent \"#{agent}\" not found in #{co}.")
        |> redirect(to: ~p"/companies/#{co}")
      end
    else
      _ ->
        conn
        |> put_flash(:error, "Invalid identifier.")
        |> redirect(to: ~p"/companies")
    end
  end
end
