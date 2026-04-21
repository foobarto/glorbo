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
  On first visit we ensure the channel file exists (so ChannelLive
  doesn't 404), then redirect into the normal channel route — this
  reuses ChannelLive's compose / mention-wake / real-time path
  unchanged.

  Director-side DMs only for v0.0.3. Agent↔agent DMs (the existing
  outbox→inbox pattern in `Glorbo.Company.Router`) are a separate
  surface.
  """
  def redirect_to_dm(conn, %{"company" => co, "agent" => agent}) do
    with true <- GlorboWeb.Slug.valid?(co),
         true <- GlorboWeb.Slug.valid?(agent) do
      base = Glorbo.Filesystem.Hierarchy.default_root()
      agent_dir = Path.join([base, "companies", co, "agents", agent])

      if File.dir?(agent_dir) do
        ensure_dm_channel(base, co, agent)
        redirect(conn, to: ~p"/companies/#{co}/channels/#{dm_slug(agent)}")
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

  defp dm_slug(agent), do: "dm-director--#{agent}"

  defp ensure_dm_channel(base, co, agent) do
    channels_dir = Path.join([base, "companies", co, "channels"])
    File.mkdir_p!(channels_dir)
    path = Path.join(channels_dir, "#{dm_slug(agent)}.md")

    unless File.exists?(path) do
      File.write!(path, """
      ---
      kind: channel-log/v1
      channel: #{dm_slug(agent)}
      ---
      # DM · director ↔ #{agent}
      """)
    end

    :ok
  end
end
