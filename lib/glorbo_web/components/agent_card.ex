defmodule GlorboWeb.Components.AgentCard do
  @moduledoc """
  CompanyLive agent grid cell (D-12, D-24 preview).

  Props:

    * `:agent` — map with `:slug`, `:name`, `:role`, `:used`, `:cap`.
    * `:company_slug` — enclosing company's slug.

  Renders user glyph, name + role, and the mini 40×40 BudgetRing.
  Whole card is a link into AgentLive.
  """
  use Phoenix.Component

  alias GlorboWeb.Components.BudgetRing

  attr :agent, :map, required: true
  attr :company_slug, :string, required: true

  def agent_card(assigns) do
    ~H"""
    <a class="gl-agent-card" href={"/companies/#{@company_slug}/agents/#{@agent.slug}"}>
      <header class="gl-agent-card__header">
        <GlorboWeb.CoreComponents.icon name="user" />
        <span class="gl-agent-card__name">{@agent.name}</span>
        <span class="gl-muted">{@agent.role}</span>
      </header>
      <BudgetRing.budget_ring used={@agent.used || 0.0} cap={@agent.cap} size={40} />
    </a>
    """
  end
end
