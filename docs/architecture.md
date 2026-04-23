# Architecture — Glorbo

High-level map of the code. Read `docs/DESIGN.md` for the
authoritative architectural spec; read `docs/knowledge-graph/GRAPH_REPORT.md`
for the graph-derived navigational view (what calls what, which
modules cluster together). This file sits between the two — a
human-written summary keyed to module paths — and is maintained
alongside code changes per the CLAUDE.md six-phase step 6.

## The six subsystems

Glorbo's code clusters into six roughly-cohesive subsystems. Each
is rooted at one or two hub modules that show up near the top of
the knowledge-graph "god nodes" list.

### 1. Company Router — `lib/glorbo/company/`

**Entry point:** `Glorbo.Company.Router` (96 edges, the highest-
centrality module in the graph).

The single choke point between agent outboxes and their
destinations. Every agent-initiated write — a message, a task, a
comment, a memory entry, a path request, a proposal — flows through
the Router. It validates, permission-checks, atomically writes, and
emits the audit event. Its classmates in the same supervision tree:

- `Glorbo.Company.Supervisor` — per-company OTP supervisor
  (crash-isolation boundary from CLAUDE.md invariants).
- `Glorbo.Company.AgentSupervisor` — DynamicSupervisor for
  per-agent `Glorbo.Agent.Server` processes.
- `Glorbo.Company.AuditLog` — per-company GenServer that writes
  JSONL to `audit/YYYY-MM.jsonl`. Append-only invariant.
- `Glorbo.Company.ProposalsSink` — GEP-28 wave 2a observer
  emitting `proposal.*` audit events.
- `Glorbo.Company.Scheduler` + `Glorbo.Company.TaskScheduler`
  (GEP-24) — cron-driven heartbeats + task dispatch.

### 2. Agent runtime — `lib/glorbo/agent/`

**Entry points:** `Glorbo.Agent.Server` (53 edges), `Glorbo.Agent.Dispatch` (50 edges).

The lifecycle of a single agent invocation. When the Scheduler
fires or an inbox message lands, `Agent.Server` enters `:dispatching`
and hands off to `Agent.Dispatch`, which shells out inside a bwrap
sandbox to either an external CLI runtime (`claude`, `gemini`,
`codex`, etc.) or the first-party `glorbo harness` native-provider
subcommand. It then reads the reply file, parses provider telemetry,
and for native runs can replay sanitized tool-audit events back into
the company audit log before recording cost + outcome. On Linux,
`network: proxy` dispatches now wrap that launch in `pasta` so only
the per-company proxy port is reachable inside the agent netns. See
GEP-4, GEP-5, GEP-8, GEP-31, and GEP-32.

Supporting modules: `Glorbo.Agent.Parser` (validates AGENT.md),
`Glorbo.Agent.Spec` (struct), `Glorbo.Agent.FileLayout`
(filename resolution), `Glorbo.Agent.RunLog` (persisted run metadata).

### 3. Filesystem & FileSpec — `lib/glorbo/filesystem/` + `lib/glorbo/file_spec/`

**Entry points:** `Glorbo.Filesystem.Hierarchy.default_root` (74 edges),
`Glorbo.Filesystem.Frontmatter`, `Glorbo.FileSpec` behaviour.

`default_root/0` is load-bearing: every module that touches disk
calls it to resolve `~/.glorbo`. The knowledge graph flags it as
bridging 27 communities — changing its behaviour has enormous blast
radius. Treat it as an API boundary even though it's a plain
function.

`FileSpec.*Md` modules (15+ of them, one per file kind) each
implement the same contract: `match?/1`, `kind/0`,
`frontmatter_schema/0`, `canonical_key_order/0`, `docs/0`. By
design, each spec is independent — the graph flags them as
"thin communities" but that's the point of the GEP-25 pattern, not
a signal to refactor.

Related: `Glorbo.Filesystem.Watcher` (inotify → PubSub bridge),
`Glorbo.Filesystem.FrontmatterWriter` (atomic tmp+rename writer).

### 4. Phoenix / LiveView dashboard — `lib/glorbo_web/`

**Entry points:** `GlorboWeb.AgentLive` (75 edges),
`GlorboWeb.CompanyLive` (70 edges), `GlorboWeb.KanbanLive` (45
edges). `GlorboWeb.Actions` is the shared-action layer called from
every LV and from MCP — it's the enforcement point for permissions
+ audit and must not be bypassed (GEP-6 D6).

Seven canonical views per GEP-6:

- Overview (`OverviewLive`) — multi-company list.
- Company (`CompanyLive`) — per-company dashboard.
- Kanban (`KanbanLive`) — task board + new-task wizard.
- Agent (`AgentLive`) — agent detail + runtime status.
- Chat (`ChannelLive`, `ChatDrawer`) — channel + DM view.
- Inbox (`InboxLive`) — approvals + activity.
- Audit (`AuditLive`) — filterable audit log.
- Health (`HealthLive`) — doctor checks + supervisor state.

Plus specialty LVs: Costs, Providers, Goals, BrainDump, Projects.
(ApprovalQueueLive was folded into Inbox in backlog #14 — the Mine
tab renders the same sentinel data with approve/deny buttons.)

### 5. MCP server (GEP-29) — `lib/glorbo_web/mcp/`

**Entry points:** `GlorboWeb.MCP.Plug` (HTTP transport),
`GlorboWeb.MCP.Server` (JSON-RPC dispatcher + tool registry).

Streamable HTTP endpoint at `/mcp` exposing 19 tools that map 1:1
to dashboard capabilities. Actor for every mutation is
`mcp:<client>` (GEP-29 D4). All writes go through the same
`GlorboWeb.Actions` layer LiveView calls; proposals specifically
use the GEP-28 outbox indirection.

Tools live in `lib/glorbo_web/mcp/tools/` — one module per tool,
implementing the `GlorboWeb.MCP.Tool` behaviour. `GlorboWeb.MCP.Args`
is the shared slug-gate defense (same regex as LV WR-02).

Read-only catalog: list_companies, get_company, list_agents,
get_agent, list_tasks, get_task, list_proposals, get_proposal,
list_channels, get_channel, list_pending_approvals, query_audit,
get_company_health.

Write catalog: approve_task, deny_task, post_message,
capture_brain_dump, force_agent_heartbeat, create_company,
create_agent, create_channel, create_proposal, decide_proposal.

### 6. CLI — `lib/glorbo/cli/`

**Entry points:** `Glorbo.CLI.dispatch/1` (verb router),
`Glorbo.CLI.Harness` (internal native-provider runtime),
`Glorbo.CLI.Scaffold.{Company,Agent}` (public `scaffold/2,3`
exports for MCP + tests).

The `glorbo` binary (Burrito-wrapped single executable). Verbs
scaffold companies/agents, run the doctor, reindex SQLite,
validate GEPs and file formats. Dispatch from `bin/glorbo` is
handled by `Glorbo.CLI`; native providers reuse the same binary
inside bwrap via the `harness` subcommand instead of requiring a
separate external CLI install. As of GEP-32 phase 2a, the harness's
tool catalog is factored under `Glorbo.CLI.Harness.Tools` and ships the
filesystem batch (`read_file`, `write_file`, `edit_file`, `glob`,
`grep`) with audit replay back into `Agent.Dispatch`. The same
subsystem also owns `Glorbo.CLI.Registry` and its built-in/user TOML
provider loading, so provider schema changes tend to touch CLI code
even when the Director experience is in LiveView.

## Graph caveats

Reading the knowledge graph well means knowing what's noise:

1. **Generic function-name god nodes are false positives.**
   `parse()` (93 edges), `get()`, `map()`, `lookup()`, `run()`,
   `inspect()`, `warning()` appear high on the centrality list
   because tree-sitter collapses cross-module name collisions.
   They aren't single abstractions — they're many.

2. **Some INFERRED edges are bogus.** Observed false positive
   during GEP-29 sweep:
   `ProposalsSink.resolve_audit_server → PathGrantStore.lookup`.
   The actual code calls `Elixir.Registry.lookup/2`; tree-sitter
   matched the function name without module scope. Treat any
   cross-subsystem INFERRED edge as a hint, confirm with grep
   before believing.

3. **`FileSpec.*Md` modules flagged as "thin communities".**
   That's the GEP-25 pattern at work (each spec independent by
   contract). Not a refactoring opportunity.

4. **Isolated top-level modules** (`Glorbo`, `Glorbo.Repo`,
   `Glorbo.Company`, `Glorbo.Agent`, `Glorbo.AuditEvent`) are
   mostly thin namespace shells. Non-issue.

5. **Graph corpus must be scoped to `lib/`.** Running
   `graphify update .` includes `deps/` and `_build/` and
   swamps the signal (21958 nodes vs 2478). Always
   `graphify update lib`.

## Where to look first for common questions

| Question | First stop |
|---|---|
| Where is X permission enforced? | `Glorbo.Security.ACLMapper` + the Router's `check_action` call (double check per GEP-5) |
| How does a proposal become approved? | GEP-28 wave 2b outbox flow → `Router.handle_outbox_proposal` |
| What wakes an agent? | `Glorbo.Agent.Server.wake/3` → `Agent.Dispatch.execute/3` |
| How is audit written? | `Glorbo.Company.AuditLog.append/2` → `audit/YYYY-MM.jsonl` |
| How does MCP dispatch to a tool? | `GlorboWeb.MCP.Plug → Server.dispatch/3 → tool module.call/2` |
| What's the filesystem source of truth? | `~/.glorbo/companies/<co>/` tree documented in GEP-3 |
| Where do native provider tool audits come from? | `Glorbo.CLI.Harness` → `Parsers.NativeV1` → `Agent.Dispatch.emit_tool_audits/5` |

## Related

- `docs/DESIGN.md` — authoritative spec.
- `docs/knowledge-graph/GRAPH_REPORT.md` — the graph output.
- `docs/geps/` — individual design decisions.
- [`CLAUDE.md`](../CLAUDE.md) §"Feature development" — six-phase
  process that keeps this doc + the graph fresh.
