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
    # Unified director inbox — approvals + recent activity + future
    # @mention and assignment feeds. The standalone `/approvals`
    # route was folded in here (backlog #14) — Inbox's Mine tab
    # renders the same awaiting-approval sentinels with approve /
    # deny / archive buttons.
    live "/companies/:company/inbox", InboxLive
    # Plan 04-03 Task 2: content-scope chat view.
    live "/companies/:company/channels/:channel", ChannelLive
    # Director ↔ agent DM: delegates to ChannelLive with a reserved
    # `dm-director--<agent>` channel name; auto-creates the file.
    get "/companies/:company/dms/:agent", PageController, :redirect_to_dm
    # Plan 04-03 Task 3: audit viewer + system health.
    live "/companies/:company/audit", AuditLive
    # paperclip-ux-gaps §7 — dedicated goals page.
    live "/companies/:company/goals", GoalsLive
    # paperclip-ux-gaps §9 — skills marketplace / bundle view.
    # Read-only listing of skills available to this company's agents;
    # "builtin" = ships with Glorbo under priv/templates/skills,
    # "custom" = `<base>/skills/<name>.md` user overrides.
    live "/companies/:company/skills", SkillsLive
    # T1-E brain dump (#230) — daily append-only capture log.
    live "/companies/:company/braindump", BrainDumpLive
    # #259 — CSV export of the current month's audit log.
    get "/companies/:company/audit.csv", AuditExportController, :export
    live "/health", HealthLive
    # GEP-8 — provider registry dashboard.
    live "/providers", ProvidersLive
    # T2-D (#242) — cross-company monthly cost ledger.
    live "/costs", CostsLive
  end

  # T2-B (#232) — Ctrl+K content search. JSON endpoint consumed by
  # the palette. Pipes through :api AND :dashboard — the same bearer-
  # token gate that protects the LiveView surface also protects this
  # endpoint on LAN exposure. Otherwise, with `dashboard_token:` set,
  # the browser UI would be gated but task titles would be enumerable
  # via `curl /api/search?co=<slug>&q=<prefix>`.
  scope "/api", GlorboWeb do
    pipe_through [:api, :dashboard]

    get "/search", SearchController, :search
  end

  # GEP-29 wave (a) — Model Context Protocol server.
  # Streamable HTTP transport, single endpoint. Wrapped in the
  # `:dashboard` pipeline (threatmodel T11): if `dashboard_token` is
  # configured, MCP clients must pass it via `Authorization: Bearer
  # <token>` or `?token=<token>`. Without a configured token the
  # pipeline is a no-op and loopback binding + host-user trust is the
  # outer boundary. The MCP plug keeps its own Origin check for
  # DNS-rebind protection.
  scope "/" do
    pipe_through :dashboard

    forward "/mcp", GlorboWeb.MCP.Plug
  end
end
