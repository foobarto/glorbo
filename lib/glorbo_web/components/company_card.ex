defmodule GlorboWeb.Components.CompanyCard do
  @moduledoc """
  Overview grid cell for `GlorboWeb.OverviewLive` (D-21, 04-UI-SPEC §Copy).

  Props:

    * `:company` — map with `:slug`, `:name`, `:agent_count`,
      `:in_progress_count`, `:spend_usd` (float), `:alert_count`,
      `:goals` (optional — `%{count, total_tasks, done_tasks, pct}`
      or nil), `:health` (`:healthy | :warning | :crashed`).

  Emits a terminal-aesthetic card with the folder glyph, company
  name, a health dot, stat lines (agents, in-progress, spend,
  alerts), and — if goals are defined on `company.md` — a
  goals-progress row with a thin bar. The whole card is an `<a>`
  — click navigates to `CompanyLive`.
  """
  use Phoenix.Component

  attr :company, :map, required: true

  def company_card(assigns) do
    ~H"""
    <a class="gl-company-card" href={"/companies/#{@company.slug}"}>
      <header class="gl-company-card__header">
        <GlorboWeb.CoreComponents.icon name="folder" />
        <span class="gl-company-card__name">{@company.name}</span>
        <GlorboWeb.Components.HealthDot.health_dot
          status={@company.health}
          label={"Company #{@company.name} status: #{@company.health}"}
        />
      </header>
      <div class="gl-company-card__stats">
        <div>{@company.agent_count} {agent_label(@company.agent_count)}</div>
        <div>{@company.in_progress_count} in progress</div>
        <div>${:erlang.float_to_binary(@company.spend_usd * 1.0, decimals: 2)} this month</div>
        <div :if={@company.alert_count > 0}>
          {@company.alert_count} {alert_label(@company.alert_count)}
        </div>
      </div>
      <div
        :if={Map.get(@company, :goals)}
        class="gl-company-card__goals"
        aria-label={"goals progress: #{@company.goals.done_tasks} of #{@company.goals.total_tasks} tasks done across #{@company.goals.count} goals"}
      >
        <div class="gl-company-card__goals-label">
          <span>{@company.goals.count} {goal_label(@company.goals.count)}</span>
          <span class="gl-muted">·</span>
          <span>{@company.goals.pct}%</span>
          <span
            :if={@company.goals.total_tasks > 0}
            class="gl-muted"
          >
            ({@company.goals.done_tasks}/{@company.goals.total_tasks})
          </span>
        </div>
        <div class="gl-company-card__goals-bar">
          <div
            class={[
              "gl-company-card__goals-fill",
              "gl-company-card__goals-fill--" <> progress_state(@company.goals.pct)
            ]}
            style={"width: #{@company.goals.pct}%"}
          />
        </div>
      </div>
    </a>
    """
  end

  defp agent_label(1), do: "agent"
  defp agent_label(_), do: "agents"

  defp alert_label(1), do: "alert"
  defp alert_label(_), do: "alerts"

  defp goal_label(1), do: "goal"
  defp goal_label(_), do: "goals"

  defp progress_state(pct) when pct >= 100, do: "done"
  defp progress_state(pct) when pct >= 60, do: "good"
  defp progress_state(pct) when pct >= 25, do: "warm"
  defp progress_state(_), do: "cold"
end
