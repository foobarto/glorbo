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

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", GlorboWeb do
    pipe_through :browser

    # Plan 04-02 Task 1: dashboard entry + company-scope routes.
    # /health-legacy keeps the Phase 1 health probe available; 04-03
    # owns the new `/health` route for HealthLive.
    get "/", PageController, :redirect_to_companies
    get "/health-legacy", PageController, :health

    live "/companies", OverviewLive
    live "/companies/:company", CompanyLive
    live "/companies/:company/kanban", KanbanLive
    live "/companies/:company/agents/:agent", AgentLive
    live "/companies/:company/approvals", ApprovalQueueLive
    # 04-03 adds: live "/companies/:company/channels/:channel", ChannelLive
    #             live "/companies/:company/audit", AuditLive
    #             live "/health", HealthLive (+ DashboardToken plug)
  end

  # Other scopes may use custom stacks.
  # scope "/api", GlorboWeb do
  #   pipe_through :api
  # end
end
