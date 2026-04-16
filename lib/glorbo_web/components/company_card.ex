defmodule GlorboWeb.Components.CompanyCard do
  @moduledoc """
  Overview grid cell for `GlorboWeb.OverviewLive` (D-21, 04-UI-SPEC §Copy).

  Props:

    * `:company` — map with `:slug`, `:name`, `:agent_count`,
      `:in_progress_count`, `:spend_usd` (float), `:alert_count`,
      `:health` (`:healthy | :warning | :crashed`).

  Emits a terminal-aesthetic card with the folder glyph, company name,
  a health dot, and four stat lines (agents, in-progress, spend,
  alerts). The whole card is an `<a>` — click navigates to
  `CompanyLive`.
  """
  use Phoenix.Component

  attr :company, :map, required: true

  def company_card(assigns) do
    ~H"""
    <a class="gl-company-card" href={"/companies/#{@company.slug}"}>
      <header class="gl-company-card__header">
        <GlorboWeb.CoreComponents.icon name="folder" />
        <span class="gl-company-card__name">{@company.name}</span>
        <span class={"gl-dot gl-dot--" <> Atom.to_string(@company.health)}></span>
      </header>
      <div class="gl-company-card__stats">
        <div>{@company.agent_count} {agent_label(@company.agent_count)}</div>
        <div>{@company.in_progress_count} in progress</div>
        <div>${:erlang.float_to_binary(@company.spend_usd * 1.0, decimals: 2)} this month</div>
        <div :if={@company.alert_count > 0}>
          {@company.alert_count} {alert_label(@company.alert_count)}
        </div>
      </div>
    </a>
    """
  end

  defp agent_label(1), do: "agent"
  defp agent_label(_), do: "agents"

  defp alert_label(1), do: "alert"
  defp alert_label(_), do: "alerts"
end
