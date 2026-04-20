defmodule GlorboWeb.Router do
  use GlorboWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GlorboWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Optional bearer-token gate for LAN exposure (D-06). Active only when
  # `config.md dashboard_token:` is set — a no-op by default.
  pipeline :dashboard do
    plug GlorboWeb.Plugs.DashboardToken
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", GlorboWeb do
    pipe_through [:browser, :dashboard]

    # Plan 04-02 Task 1: dashboard entry + company-scope routes.
    # /health-legacy keeps the Phase 1 health probe available; 04-03
    # mounts HealthLive at /health below.
    get "/", PageController, :redirect_to_companies
    get "/health-legacy", PageController, :health

    live "/companies", OverviewLive
    live "/companies/:company", CompanyLive
    live "/companies/:company/kanban", KanbanLive
    live "/companies/:company/projects/:project", ProjectLive
    # Dedicated task-detail page — JIRA-style. Kanban opens the same task
    # as a right-side shelf; clicking "open task page →" navigates here.
    live "/companies/:company/tasks/:task_id", TaskLive
    live "/companies/:company/agents/:agent", AgentLive
    live "/companies/:company/approvals", ApprovalQueueLive
    # Plan 04-03 Task 2: content-scope chat view.
    live "/companies/:company/channels/:channel", ChannelLive
    # Director ↔ agent DM: delegates to ChannelLive with a reserved
    # `dm-director--<agent>` channel name; auto-creates the file.
    get "/companies/:company/dms/:agent", PageController, :redirect_to_dm
    # Plan 04-03 Task 3: audit viewer + system health.
    live "/companies/:company/audit", AuditLive
    live "/health", HealthLive
    # GEP-8 — provider registry dashboard.
    live "/providers", ProvidersLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", GlorboWeb do
  #   pipe_through :api
  # end
end
