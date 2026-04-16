defmodule GlorboWeb.Components.TabBar do
  @moduledoc """
  Generic tab bar for company-scope LVs. The caller supplies a list of
  `%{label, path, active?}` maps; the tab renders its active state via
  a 2px `--gl-accent` underline (UI-SPEC §Color accent reserved item #6).

  CompanyLive currently renders its own inline tab markup (Plan 04-02);
  this component exists for consistency and future swap-in.
  """
  use Phoenix.Component

  attr :tabs, :list, required: true

  def tab_bar(assigns) do
    ~H"""
    <nav class="gl-tabs" role="tablist">
      <a
        :for={t <- @tabs}
        href={t.path}
        class={["gl-tab", t.active? && "gl-tab--active"]}
        role="tab"
        aria-selected={to_string(t.active?)}
      >
        {t.label}
      </a>
    </nav>
    """
  end
end
