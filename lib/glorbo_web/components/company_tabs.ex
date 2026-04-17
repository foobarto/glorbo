defmodule GlorboWeb.Components.CompanyTabs do
  @moduledoc """
  Shared tab bar for the company-scope LiveViews (Kanban, Chat,
  Approvals, Audit).

  Before this component existed, the tab bar lived only in CompanyLive.
  Navigating to a sub-view unmounted CompanyLive and the tabs
  disappeared — TODO2.md §3 and TODO.md P0 #5. Each company-scope LV
  now renders `<CompanyTabs.company_tabs slug={..} active={..}>` above
  its own header so the Director can laterally hop between tabs
  without losing the context strip.

  Uses `<.link navigate=>` (live navigation) rather than full reloads
  so socket state + sidebar stay warm between tabs.

  ## Attrs

    * `:slug` — the company slug (required)
    * `:active` — one of `:kanban | :chat | :approvals | :audit | nil`.
      `nil` means no tab is highlighted (e.g. CompanyLive's index page
      and AgentLive which is not one of the four tabs).
  """
  use Phoenix.Component

  attr :slug, :string, required: true
  attr :active, :atom, default: nil, values: [:kanban, :chat, :approvals, :audit, nil]

  def company_tabs(assigns) do
    ~H"""
    <nav class="gl-tabs" role="tablist" aria-label="Company navigation">
      <.link
        navigate={"/companies/#{@slug}/kanban"}
        class={["gl-tab", @active == :kanban && "gl-tab--active"]}
        role="tab"
        aria-selected={to_string(@active == :kanban)}
      >
        Kanban
      </.link>
      <.link
        navigate={"/companies/#{@slug}/channels/general"}
        class={["gl-tab", @active == :chat && "gl-tab--active"]}
        role="tab"
        aria-selected={to_string(@active == :chat)}
      >
        Chat
      </.link>
      <.link
        navigate={"/companies/#{@slug}/approvals"}
        class={["gl-tab", @active == :approvals && "gl-tab--active"]}
        role="tab"
        aria-selected={to_string(@active == :approvals)}
      >
        Approvals
      </.link>
      <.link
        navigate={"/companies/#{@slug}/audit"}
        class={["gl-tab", @active == :audit && "gl-tab--active"]}
        role="tab"
        aria-selected={to_string(@active == :audit)}
      >
        Audit
      </.link>
    </nav>
    """
  end
end
