---
gep: 0029
title: Glorbo as MCP Server (Localhost HTTP-SSE, R/W)
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-22
history:
  - date: 2026-04-22
    status: Draft
    note: Initial draft. Concrete implementation of the direction sketched in GEP-9.
  - date: 2026-04-22
    status: Implemented
    note: |
      All waves shipped. (a) transport scaffolding; (b.1/b.2) 13
      read-only tools; (c.1/c.2) 10 write/creation tools; (d.1)
      resources/list + resources/read; (d.2) resources/subscribe
      + SSE streaming with SessionSupervisor; (e) MCP-Protocol-Version
      header validation; (f) end-to-end smoke (scripts/mcp-smoke.sh)
      + client setup doc (docs/mcp-client-setup.md).
requires: [2, 6, 9, 19, 28]
see-also: [4, 10]
---

# GEP-29: Glorbo as MCP Server (Localhost HTTP-SSE, R/W)

## Problem

External agents (Claude Code, Cursor, Codex, and anything else that
speaks MCP) currently have three unsatisfying ways to work with a
running Glorbo instance:

1. **Filesystem drop-in.** They can write into
   `~/.glorbo/companies/<co>/agents/<slug>/outbox/` directly if they
   run as the same user. This mostly works but offers zero schema
   validation at call time, no error surface, and no way to ask
   Glorbo a question (e.g., "what are my pending approvals?").
2. **Shell out to the `glorbo` CLI.** Works for a few commands but
   has subprocess latency, can't stream, and requires the external
   agent to know Glorbo's CLI surface.
3. **Render the LiveView dashboard in a headless browser.**
   Functional but absurd.

GEP-9 (Protocol-Level Integration — MCP, ACP) explicitly anticipated
this and sketched "Glorbo could be an MCP server exposing resources
that agents' CLI tools connect to as clients," then deferred the
actual implementation to a separate Standards GEP. This is that GEP.

The concrete trigger: the Director wants external CLI agents to be
able to drive Glorbo as effectively as a human does through the web
UI — query state, dispatch tasks, post in channels, approve or deny
approvals, and submit proposals — without bolting on a home-rolled
REST API or duplicating the LiveView handlers.

## Goals

- Expose an MCP server at `/mcp` on the existing Phoenix endpoint
  (localhost:4000 by default, alongside the dashboard).
- Provide an MCP **tool surface** that is a 1:1 map of the Director's
  web-UI capabilities: browse companies, inspect agents/tasks/channels,
  dispatch, approve, post messages, create/decide proposals, query
  audit.
- Provide an MCP **resource surface** for read-only streaming tails
  (audit log, channel transcripts, agent stdout) by tapping existing
  PubSub topics.
- Every MCP-initiated mutation flows through the same Elixir action
  functions the LiveView already calls (`Approvals.approve/1`,
  `Router.route/2`, `Actions.*`). No shortcut code paths.
- Zero new auth surface. Same trust model as GEP-6 D5: localhost =
  trusted user.
- Start automatically when `mix phx.server` / `glorbo serve` runs;
  disabled by a single config flag and absent from the headless
  `glorbo run` dispatch mode.

## Non-goals

- **Remote access / auth / TLS.** Strict localhost binding; anything
  remote is a future GEP with its own threat model.
- **MCP client side** — Glorbo is not going to consume external MCP
  servers. Agent-as-MCP-client is already how CLI runtimes work via
  their own per-tool MCP configs.
- **Non-SSE transports.** No WebSocket, no stdio, no custom framing.
- **Multi-operator / role-based access control.** Every MCP caller
  gets Director scope.
- **Service discovery / announcement.** The caller knows the host and
  port out of band.
- **Wrapping GEP-25 offline tooling** (`glorbo validate`, `glorbo fmt`).
  Those are host-CLI concerns, not runtime concerns.
- **Rate limiting.** v1 accepts abuse; see Open questions.

## Design

### Transport and mount point

- **Protocol:** MCP spec version 2025-06-18, **Streamable HTTP**
  transport. Single endpoint handling both POST (client → server
  JSON-RPC) and GET (optional server-initiated SSE stream). The
  server responds to each POST with either `Content-Type:
  application/json` (one-shot) or `Content-Type: text/event-stream`
  (SSE) at its own discretion.
- **Mount point:** single URL path `/mcp` on the existing
  `GlorboWeb.Endpoint`. Serves POST and GET. The legacy two-endpoint
  HTTP+SSE transport (`/sse` + `/messages`, from the 2024-11-05 spec)
  is **not** supported — clients too old to speak Streamable HTTP get
  a 400.
- **Headers:** clients MUST send `MCP-Protocol-Version: 2025-06-18`
  on every request after `initialize`. The server advertises
  `Mcp-Session-Id: <uuid>` in the `initialize` response; clients
  echo it on every subsequent request.
- **Security:** the plug binds `127.0.0.1` only and MUST validate
  the `Origin` header on all requests to prevent DNS rebinding
  attacks (spec §Security Warning). Requests from unknown origins
  get 403.
- **Supervision:** the session registry is a child of
  `Glorbo.Application`. Each active session is a lightweight
  GenServer under a `DynamicSupervisor` so a bad client can't take
  down the dashboard. Session state: protocol version, client name,
  subscribed resources, last-event-id (for SSE resumability).
- **Library:** hand-rolled Plug-based adapter (D6 resolved). Research
  found `hermes_mcp` (0.14.1) and `mcp_sse` (0.1.6) on Hex; hermes
  has underdocumented SSE server mode plus a `finch` transitive
  dep, `mcp_sse` is lighter but still adds a dep. Streamable HTTP's
  wire format is small enough (~200 LoC for `initialize`,
  `tools/list`, `tools/call`, `resources/*`, plus JSON-RPC framing)
  that hand-rolling keeps the dep tree lean and matches Glorbo's
  single-binary Burrito constraint.

### Tool surface (1:1 with the dashboard)

Tools are namespaced under `glorbo.`. All tools take `company` as
an argument when the operation is scoped to one — there is no
session-level company binding (Q2 resolved: global, argument per
call).

**Companies and health**
- `glorbo.list_companies` → `[{slug, name, headcount_budget}]`
- `glorbo.get_company(company)` → full `company/v1` frontmatter + counts
- `glorbo.get_company_health(company)` → supervisor + budget + idle summary
- `glorbo.create_company(slug, name, …)` → scaffold a new company

**Agents**
- `glorbo.list_agents(company)`
- `glorbo.get_agent(company, slug)` → AGENT.md parsed + last heartbeat
- `glorbo.create_agent(company, slug, template, provider, …)`
- `glorbo.force_agent_heartbeat(company, slug)`
- `glorbo.get_agent_stdout_tail(company, slug, lines?)` — snapshot;
  streaming lives in the resource surface.

**Tasks / Kanban**
- `glorbo.list_tasks(company, project?, status?, assigned_to?)`
- `glorbo.get_task(company, project, task_id)`
- `glorbo.create_task(company, project, title, body, …)`
- `glorbo.dispatch_task(company, project, task_id)`
- `glorbo.update_task_status(company, project, task_id, status)`

**Chat**
- `glorbo.list_channels(company)`
- `glorbo.get_channel(company, channel, since?, limit?)`
- `glorbo.post_message(company, channel, body)` — actor is
  `mcp:<client>` (Q3 resolved).
- `glorbo.create_channel(company, channel)`

**Approvals (GEP-19)**
- `glorbo.list_pending_approvals(company)`
- `glorbo.approve_task(company, project, task_id, note?)`
- `glorbo.deny_task(company, project, task_id, denial_reason)`

**Proposals (GEP-28)**
- `glorbo.list_proposals(company, status?)`
- `glorbo.get_proposal(company, id)`
- `glorbo.create_proposal(company, id, subtype, body, …)` —
  internally drops the file in the caller's surrogate outbox (see
  Identity) and lets the Router validate. Same enforcement as any
  agent-sourced proposal.
- `glorbo.decide_proposal(company, id, decision, denial_reason?)` —
  actor `mcp:<client>`; Router enforces `approved_by ≠ proposed_by`
  just as for agent-sourced flips.

**Audit**
- `glorbo.query_audit(company, actor?, action?, since?, until?, q?)`
- Streaming tail lives in the resource surface.

**Brain dump**
- `glorbo.capture_brain_dump(company, content)` → writes to the
  existing brain-dump intake the same way the LV button does.

### Resource surface (streaming)

MCP resources are the "subscribe to a URI" primitive. Glorbo
exposes tails of existing PubSub topics:

| Resource URI                                   | Tapped topic                       |
|------------------------------------------------|------------------------------------|
| `glorbo://audit/<company>`                     | `company:<co>:audit`              |
| `glorbo://chat/<company>/<channel>`            | `company:<co>:chat:<channel>`     |
| `glorbo://agent/<company>/<slug>/stdout`       | `company:<co>:agent:<slug>:stdout`|
| `glorbo://approvals/<company>`                 | `company:<co>:approvals`          |
| `glorbo://proposals/<company>`                 | `company:<co>:proposals`          |

Each resource subscription opens a server-push channel over the
same SSE connection; new messages on the underlying PubSub topic
fan out as MCP `notifications/resources/updated` frames.

### Identity, permissions, audit

- **Connection header.** The MCP client advertises its name via
  the `MCP-Client-Name` header (or the `clientInfo` block in
  `initialize`). We normalize to a slug, prefix with `mcp:`, and
  carry it as the actor for every audit event generated by calls
  on that connection.
- **Director scope.** Every tool call is treated as if the Director
  invoked it through the LiveView. Per GEP-6 D5 this is safe on
  localhost; the MCP server refuses to bind to anything other than
  loopback.
- **Same enforcement path.** For proposals specifically (GEP-28 D7
  outbox-indirection), the MCP `create_proposal` tool synthesises
  the outbox write that a CEO-class agent would make — it writes
  into a synthetic `mcp/<client>` outbox under the company's
  `agents/` tree, then lets the existing Router pipeline process
  it. No Router bypass.
- **Audit.** Every mutation emits an audit event with
  `actor: "mcp:<client>"`. Read-only tools emit no audit (matches
  the LiveView's read-only view behaviour).
- **Self-approval / self-decide.** The Router's existing rule
  `approved_by ≠ proposed_by` naturally blocks an MCP client that
  proposed `hire-writer` from later deciding it, since both carry
  the same `mcp:<client>` actor.

### Error surfaces

Map Glorbo's internal `{:error, reason}` tuples to MCP error objects
with a small canonical code table:

| Glorbo reason                                  | MCP error code           |
|------------------------------------------------|--------------------------|
| `{:permission_denied, perm}`                   | `permission_denied`      |
| `:not_found` / `{:not_found, _}`               | `not_found`              |
| `{:bad_request, _}` / validator errors         | `validation_failed`      |
| `{:routing_rejected, reason}`                  | `routing_rejected`       |
| catch-all                                      | `internal_error`         |

`message` carries the reason's human string; `data` carries the
raw tuple so programmatic clients can branch on it.

### Lifecycle

- **`mix phx.server` / `glorbo serve`:** MCP endpoint starts
  automatically on `/mcp`.
- **`glorbo run <co>/<agent> <task>`:** headless dispatch mode,
  Phoenix not started → MCP absent. Consistent with GEP-6 D4.
- **Kill switch:** config `config :glorbo, GlorboWeb.Endpoint,
  mcp_enabled: true` (default). Setting `false` omits the plug mount.
  Lets an operator disable MCP without editing code.

### Config summary

```elixir
# config/runtime.exs
config :glorbo, GlorboWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  mcp_enabled: true,
  mcp_path: "/mcp"
```

## Migration / rollout

Additive; zero breaking changes.

1. **New route.** `/mcp` is introduced. No existing path
   changes.
2. **No ACL changes.** MCP actors use the existing audit vocabulary
   with the `mcp:` prefix; existing dashboards and reporters keep
   working.
3. **No filesystem layout changes.** Proposal creation via MCP
   reuses the GEP-28 outbox indirection; no new on-disk shape.
4. **No CLI changes.** `glorbo serve` and `glorbo run` are
   unaffected; `mix phx.server` automatically includes MCP.
5. **Client advertisement.** README gets a short "Connecting MCP
   clients" section listing the URL + example Claude Code config.

## Failure modes

| Failure                                            | Surface                                                      | Mitigation                                                             |
|----------------------------------------------------|--------------------------------------------------------------|------------------------------------------------------------------------|
| Remote caller tries to connect                     | Endpoint refuses (loopback-only bind)                        | Bind `127.0.0.1` explicitly; reject non-loopback at the plug layer too |
| Tool call with unknown company                     | `not_found` MCP error                                        | Uniform lookup failure handling                                        |
| Permission denied (same as web UI denies)          | `permission_denied` MCP error with perm string               | Reuse `ACLMapper.check_action/2`                                       |
| SSE connection drops mid-stream                    | Client reconnects + re-subscribes; resource state is derived | Idempotent resource subscriptions; no server-side session resume       |
| Runaway MCP client spams tool calls                | Server happily serves them (no rate limit in v1)             | Operator disables MCP or kills the connection via Phoenix admin        |
| MCP client version mismatch                        | `initialize` negotiates capabilities; unsupported → error    | Declare supported version in capability manifest                       |
| Long-running tool (CLI subprocess) blocks          | Tool call uses Task.Supervisor; returns `progress` frames    | MCP progress notifications if library supports; else return early      |

## Test strategy

- **Unit:** one test per tool mapping `{tool_name, args}` → underlying
  Elixir action call + audit event shape. Mock the Router and
  action modules; assert call arguments.
- **Integration:** spin a Phoenix endpoint on a random port, drive
  it with a minimal Elixir MCP client (or `curl` + `:gen_tcp`),
  assert SSE frames for: `initialize`, `tools/list`, `tools/call`
  of each major verb, `resources/subscribe` tail, connection
  shutdown.
- **E2E (manual at first):** connect Claude Code to a running
  Glorbo instance, verify it can list companies, dispatch a task,
  and observe an audit tail.
- **Regression:** every new audit event surfaced by an MCP tool
  must match the shape emitted by its LiveView counterpart
  (identical keys, identical `target:` semantics from GEP-19 D3).

## Open questions

- **Q1. Rate limiting.** Not in v1. Revisit if a misbehaving client
  becomes a real problem (trivial to add a Hammer or per-session
  token bucket later).
- **Q2. Company scope — decided.** Global + `company` argument per
  call. Matches web UI browsability; no stateful session binding.
- **Q3. `approved_by` value for MCP-initiated approvals — decided.**
  Use `mcp:<client>` rather than `director`. Preserves audit
  distinctness between Director-at-browser, Director-at-CLI, and
  each connected MCP client.
- **Q4. MCP library choice.** `hermes_mcp` vs hand-rolled plug.
  Decide during implementation based on HTTP-SSE support. Captured
  in D6.
- **Q5. Progress frames for long-running tools.** MCP supports
  progress notifications; whether we use them for tool calls that
  internally start CLI subprocesses is an implementation concern.

## Decision log

### D1. Tool surface mirrors the dashboard, not the filesystem

- **Decided:** the MCP tool catalog enumerates Director actions (list
  companies, dispatch task, approve, post message, etc.), not
  filesystem primitives (read/write file, move dir).
- **Alternatives:** expose a generic `glorbo.read_file(path)` /
  `glorbo.write_file(path, content)` pair and let clients assemble
  workflows themselves. Or: expose only an abstract "task" API that
  hides the filesystem entirely.
- **Why:** matches the user's stated intent ("external agents should
  use Glorbo as effectively as a human via the web UI"). A
  filesystem-primitive surface would defeat the whole point by
  requiring each client to re-learn Glorbo's on-disk conventions;
  it would also bypass the Elixir action layer that enforces
  permissions, audit, and the filesystem-as-source-of-truth
  invariants (GEP-2 D3, GEP-6 D6). A task-only abstract surface
  hides too much — agents need to inspect chat, audit, and
  proposals too.

### D2. Localhost, no auth — inherited from GEP-6 D5

- **Decided:** the MCP endpoint binds `127.0.0.1` only, accepts no
  auth, and serves every caller as Director-scope.
- **Alternatives:** token auth with a secret in `~/.glorbo/config.md`;
  UNIX domain socket instead of TCP; OAuth device flow.
- **Why:** GEP-6 D5 already settled this exact trust model for the
  dashboard. Introducing auth for MCP while LiveView stays open
  would be inconsistent. Any remote-access story is a future GEP
  that must solve the threat model for both surfaces at once.

### D3. All mutations via the shared Elixir action layer

- **Decided:** MCP tool handlers call the same `Actions.*`,
  `Approvals.*`, `Router.route/2` functions the LiveView calls. No
  direct filesystem writes. Proposals in particular reuse the
  GEP-28 outbox indirection.
- **Alternatives:** give MCP handlers direct `File.write/2` access
  for speed; or introduce a new "trusted write" path that skips
  permission checks because localhost.
- **Why:** GEP-6 D6, GEP-19 D2, GEP-28 D7 all reinforce the same
  invariant — one write path per mutation type. A parallel MCP
  path would silently diverge on audit shape, permission
  enforcement, and sandbox semantics (the kind of drift GEP-19 D2
  was written to fix). Also shorter code — every tool handler is
  a wrapper, not a reimplementation.

### D4. Actor is `mcp:<client>`, not `director`

- **Decided:** every audit event from an MCP call carries
  `actor: "mcp:<client-name>"`, where `<client-name>` is derived
  from the MCP `clientInfo.name` field at `initialize` time.
- **Alternatives:** (a) actor = `director`, collapsing all MCP
  sources; (b) actor = `mcp`, collapsing all clients into one.
- **Why:** distinct actors preserve forensic clarity — a Director
  auditing approvals can see that a specific client approved
  something versus the Director clicking through the UI. It also
  makes the Router's existing `approved_by ≠ proposed_by` rule
  cleanly block an MCP client from approving a proposal it
  authored.

### D5. HTTP SSE + JSON-RPC, not WebSocket or stdio

- **Decided:** transport is MCP's HTTP-SSE profile; JSON-RPC 2.0
  framed as `text/event-stream`.
- **Alternatives:** WebSocket (richer framing, bidirectional);
  stdio (classic MCP, zero-setup for local clients); custom
  framing.
- **Why:** SSE slots next to the existing Phoenix endpoint with
  zero new runtime dependencies (Phoenix already serves SSE
  trivially via Plug). WebSocket adds a second framing layer
  without enabling anything SSE doesn't. Stdio doesn't fit an
  always-on dashboard model — MCP clients that run as long-lived
  daemons alongside `glorbo serve` expect a network transport.
  SSE is also the de-facto path for agent-browser / Claude Code
  MCP integrations today.

### D6. Hand-rolled Plug-based MCP adapter

- **Decided:** hand-roll a Plug-based Streamable HTTP adapter for
  Glorbo's MCP surface. No external MCP library dependency.
- **Alternatives:** (a) `hermes_mcp` 0.14.1 — the most-established
  Elixir MCP SDK; (b) `mcp_sse` 0.1.6 — lighter-weight alternative.
- **Why:** the spike (2026-04-22, claude-code-guide agent) found
  hermes has underdocumented Streamable HTTP server support plus a
  `finch` transitive dep that bloats a single-binary Burrito
  release; `mcp_sse` is lighter but still adds a non-trivial
  dependency. The Streamable HTTP wire format is ~200 LoC for the
  methods Glorbo needs (`initialize`, `tools/list`, `tools/call`,
  `resources/list`, `resources/read`, `resources/subscribe`, plus
  JSON-RPC 2.0 envelope parsing and SSE framing). Hand-rolling keeps
  the dep tree lean, preserves full control of the wire format, and
  matches Glorbo's "no npm, no Python, single-binary" philosophy.
  Revisit if a future spec revision makes the wire format
  materially more complex.

### D7. Resources are SSE tails of existing PubSub topics

- **Decided:** MCP resource subscriptions tap the existing
  `company:<co>:*` PubSub topics; no new data path, no new
  derived state.
- **Alternatives:** re-derive resource content from the filesystem
  on every subscribe; maintain a separate MCP-specific state
  store.
- **Why:** PubSub is already the canonical fan-out for LiveView;
  reusing it means MCP resources observe exactly what the
  dashboard observes, and filesystem-as-source-of-truth (GEP-3)
  stays the single system-of-record. No new snapshots to
  invalidate.

### D8. Headless `glorbo run` skips MCP

- **Decided:** MCP is only mounted when Phoenix is running. The
  single-dispatch `glorbo run` mode exits without ever starting
  an HTTP listener, so no MCP endpoint.
- **Alternatives:** always start MCP; make `glorbo run` spin up
  a throwaway SSE server.
- **Why:** `glorbo run` is explicitly headless (GEP-6 D4). Running
  an SSE server for a single dispatch would be waste — the caller
  of `glorbo run` already has direct process access.

## Related

- **GEP-2** — Architecture Overview. GEP-29 extends beyond D6's
  "no REST or gRPC API" baseline; GEP-29 is the first programmatic
  external interface.
- **GEP-6** — Phoenix LiveView Dashboard. GEP-29 inherits D5
  (localhost, no auth) and D6 (one-way data flow) wholesale. MCP
  tools are the same action functions LiveView buttons call.
- **GEP-9** — Protocol-Level Integration (MCP, ACP). Activated by
  this GEP. GEP-9 stays as the direction record; GEP-29 is the
  concrete implementation.
- **GEP-19** — Director Approval Workflow. MCP `approve_task` /
  `deny_task` call `Approvals.set_approval/4` — same path as the
  LiveView, same audit shape.
- **GEP-28** — Agent-Created Proposals. MCP `create_proposal` /
  `decide_proposal` reuse the outbox-indirection pipeline (D7);
  the Router enforces `approved_by ≠ proposed_by` regardless of
  whether the caller is an agent, LiveView, or MCP client.
- Model Context Protocol spec: <https://spec.modelcontextprotocol.io/>

## Implementation reconciliation (2026-06-14)

This is an append-only record. Per GEP-1, an Accepted/Implemented GEP's body is not rewritten in place; deviations between the body above and the shipped code are recorded here instead.

- **Task-mutation tools — deferred (specced but not built).** The Design "Tool surface" (lines 146, 152–154) lists `glorbo.create_task`, `glorbo.dispatch_task`, `glorbo.update_task_status`, and `glorbo.get_agent_stdout_tail`. The shipped tool registry at `lib/glorbo_web/mcp/server.ex:68–97` enumerates exactly 23 tool modules and none of these four; `grep -rn 'dispatch_task|create_task|update_task_status|get_agent_stdout_tail' lib/glorbo_web/mcp test/glorbo_web/mcp` returns zero hits. The Kanban write path and stdout snapshot were never built, so the "1:1 with the dashboard" tool surface is read-only for tasks. Disposition: deferred / known-gap — implement the four tools, or amend the Tool surface to drop them.

- **`mcp_enabled` kill switch and `mcp_path` config — deferred (specced but not built).** Goals (lines 71–73), the "Kill switch" Design note (lines 251–253), and the Config summary (lines 257–263) promise `config :glorbo, GlorboWeb.Endpoint, mcp_enabled: true, mcp_path: "/mcp"`, with `false` omitting the mount. `grep -rn 'mcp_enabled|mcp_path' lib config` returns nothing; the route is hardcoded and unconditionally mounted at `lib/glorbo_web/router.ex:189–192`. There is no config-driven disable path. Disposition: deferred / known-gap — implement the flag, or strike the kill-switch/config text and document the actual disable mechanism.

- **"Zero new auth surface" / "no auth" — as-shipped (body is stale).** Goals (lines 69–71) and Decision D2 (lines 349–358) state the MCP endpoint "accepts no auth" and serves every caller as Director-scope on the GEP-6 D5 localhost trust model. The shipped route wraps `/mcp` in the `:dashboard` pipeline (`lib/glorbo_web/router.ex:189–192`), which runs `GlorboWeb.Plugs.DashboardToken`. Per the pipeline comment at `router.ex:41–48`, `dashboard_token:` is now mandatory and auto-generated by `Config.load` (GEP-48/GEP-0053), so MCP clients must pass `Authorization: Bearer <token>` (or `?token=`) on every request — a real bearer gate the GEP never mentions. Disposition: as-shipped — the code is correct and intentional (introduced after GEP-29 by GEP-48/GEP-0053); GEP-29's "no auth" / "zero new auth surface" language is superseded and should be read against this entry.

- **Agent-stdout resource — deferred (specced but not built).** The "Resource surface" table (lines 192–198) lists five resources including `glorbo://agent/<company>/<slug>/stdout`, and the history note (lines 16–18) claims wave (d.2) SSE streaming shipped. The code ships four resources: `lib/glorbo_web/mcp/resources.ex:22–24` explicitly states agent stdout "is deferred to wave (d.2)," and it appears in neither `templates/0` (`resources.ex:86–113`, four templates) nor the read path, so subscribing/reading that URI returns resource-not-found (`-32002`). Disposition: deferred — the agent-stdout row and the wave-(d.2) "shipped" claim overstate what landed; the other four resources are live.
