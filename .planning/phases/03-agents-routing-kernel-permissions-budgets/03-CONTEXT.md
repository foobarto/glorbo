# Phase 3: Agents, Routing, Kernel Permissions, Budgets - Context

**Gathered:** 2026-04-16
**Status:** Ready for planning
**Mode:** Auto-generated (--auto; all gray areas resolved to recommended defaults — Claude's Discretion for everything not covered below)

<domain>
## Phase Boundary

Markdown `agent.md` files become live, supervised, kernel-isolated Linux-user workers inside their Company's Podman container. They wake on one of four triggers (new inbox file, cron heartbeat, `@agent` channel mention, Director request), pick up task files, execute via the FastAPI worker built in Phase 2, write results to their outbox, and get routed by Elixir's Router with permission checks at BOTH the application layer (Router) and kernel layer (POSIX ACLs inside the container). Per-agent USD budgets are tracked from `litellm.completion` usage reports, network policy (`none | api-only | open`) is enforced at `podman run` time, and tasks with `requires_approval: director` pause until a Director-approved sentinel file appears (dashboard UI ships in Phase 4 — Phase 3 exercises the file-mutation path directly).

**In scope:** Per-company supervision tree fleshed out (Router, Scheduler, BudgetTracker, per-agent GenServers, plus existing Phase-2 AuditLog + Watcher); Linux user provisioning (`glorbo-<company>-<agent>` with keep-id mapping); POSIX ACL reconciliation from `agent.md` permission frontmatter; per-agent network policy implemented via `podman run --network` modes + netavark/slirp4netns selection (v1 uses the `none | slirp4netns:allow=<hosts> | default`-equivalent ladder); Anthropic/OpenAI/Google provider support via `litellm` routed through the existing worker; skills injection into the prompt at dispatch time; approval gate file-mutation flow; Python usage reporting → SQLite budget ledger → hard-stop before dispatch; agent-creation-is-Director-only invariant enforcement.

**Out of scope (Phase 4/5):** LiveView dashboard (approval UI, budget widgets, audit viewer); Phoenix Channels + PubSub surface (stdout streaming is wired in Phase 2, PubSub-to-LiveView is Phase 4); `glorbo up/down` CLI verbs, `glorbo logs` streaming, `backup/restore/doctor --fix` repair semantics; skill marketplace / remote skills; agent-spawn-agent (v2 deferred, permanently out of v1).

</domain>

<decisions>
## Implementation Decisions

### [auto] Linux user provisioning (SEC-02 foundation)
- **D-01:** Username scheme — `glorbo-<company_slug>-<agent_slug>` (e.g. `glorbo-acme-engineer`). Stable across restarts; derived deterministically from filesystem paths. Reason: debuggable in `podman top` output and matches the setfacl examples in DESIGN.md §7.2.
- **D-02:** UID allocation — **dynamic, per-company offset block**. Each company reserves a 100-UID range starting at `100000 + 100*company_ordinal` (company_ordinal from a persistent `.companies-uid.json` sidecar under `~/.glorbo/runtime/`). Agent UIDs are assigned sequentially within the block. Reason: keeps `--userns keep-id` simple (deterministic host-UID → container-UID mapping) without requiring manual configuration.
- **D-03:** Provisioning layer — users exist **inside the container only**. Elixir writes a declarative `/etc/passwd` + `/etc/group` fragment into a tmpfs-backed overlay at container start; no host-side `useradd` invoked (keeps the host unmodified per CLAUDE.md's "filesystem is user data" guarantee for `~/.glorbo/companies/`). Reason: rootless Podman honours the in-container passwd file when combined with `--userns keep-id --uidmap` — the host never learns these users exist.
- **D-04:** Agent removal — deleting `agent.md` leaves the assigned UID "soft-retired" in the sidecar (tombstoned, not recycled) so audit log foreign keys stay valid. Reason: audit-log append-only invariant extends to UID stability.

### [auto] POSIX ACL reconciliation (SEC-02)
- **D-05:** Reconciliation timing — ACLs are rewritten **on container start** (idempotent, `setfacl -b` followed by declarative re-apply from the parsed `permissions:` list). Not on every file change. Reason: permissions only change at agent-definition-edit time; reconciling at container start + on agent.md save is sufficient and keeps inotify handlers cheap.
- **D-06:** Scope mapping — the `resource:action:scope` tuple maps to ACL entries via a central mapping table (e.g. `projects:write:website-redesign` → `setfacl -R -m u:<user>:rwx /company/projects/website-redesign/`). Table lives in `lib/glorbo/security/acl_mapper.ex`. Reason: single source of truth; testable without a container.
- **D-07:** Default baseline — every agent gets **`rwx` on its own `agents/<name>/outbox/`, `workspace/`, `state/`** and **`r` on `agents/<name>/inbox/`** (one-way flow). Everything else starts denied (`u:<user>:---`) and is opened only by explicit permissions. Reason: fail-closed default matches CLAUDE.md's "kernel is the policy engine" invariant.
- **D-08:** Channel ACLs — channel files (`channels/*.md`) get `r` for all agents with `chat:read:*` and **`---` (denied write) for every agent**. Elixir is the sole writer (§6.2). Agents write to their outbox; the Router appends to the channel. Reason: honours DESIGN.md §6.2 invariant.
- **D-09:** Enforcement test — the "deliberate write attempt" contract (ROADMAP SC-4) is a concrete integration test: spawn a running container for Agent X with `projects:write:A` permission, `podman exec` into the container as `glorbo-<co>-<x>`, attempt `touch /company/projects/B/smoke`, assert `EACCES` in the result. Not just an Elixir-side rejection — a kernel-observed denial.

### [auto] Network policy enforcement (SEC-03)
- **D-10:** Transport implementation — policy strings map to podman flags:
  - `none` → `--network none` (default; matches Phase 2 D-34 Unix-socket transport; airplane-mode path).
  - `api-only` → `--network slirp4netns:allow_host_loopback=false` + outbound DNS resolvable, with a **netavark firewall allow-list** restricting destination IPs/CIDRs to the known LLM provider endpoints (Anthropic, OpenAI, Google, HuggingFace CDN). Allow-list lives in `lib/glorbo/security/network_policy.ex`.
  - `open` → `--network slirp4netns` with no extra restriction (default Podman behavior).
- **D-11:** `api-only` enforcement layer — **rootless netavark firewall rules** applied at container start via `podman network create --internal=false --dns=<resolver>` + per-container `--ip-filter` where supported, with a fallback to in-container `iptables`/`nftables` applied by the entrypoint when netavark lacks the filter primitive on the host's Podman version. Reason: defence in depth matches SEC-01/SEC-02 philosophy — a prompt-injected agent must not egress to arbitrary hosts even if the `litellm` SDK is tricked into it.
- **D-12:** Allow-list composition — static base list (documented in `config/network_policy.exs`) plus per-company override in `company.md` frontmatter's `network_allow: [...]` (v1: optional). Reason: companies may use proxies (e.g. internal Claude gateway).
- **D-13:** `network: none` ambush test — integration test confirms that an `api-only` agent whose LLM call is tool-using cannot perform an HTTP GET to `http://example.com` from inside the worker (the allow-list should reject it). Concrete proof of SEC-03's enforcement claim.

### [auto] Router architecture (AGT-03)
- **D-14:** Router shape — **single per-company `Glorbo.Company.Router` GenServer**, supervised by the Company's supervision tree. Routes every outbox→inbox / outbox→channel transfer. Reason: AGT-03 inbox/outbox one-way flow must be mediated through a single choke point for auditability.
- **D-15:** Trigger source — Router listens for file events from the existing Phase 2 `Filesystem.Watcher` (`agents/<name>/outbox/`). Each new file in an agent's outbox is a routing job. Reason: file-system is source of truth; watcher already exists.
- **D-16:** Permission check flow — Router parses the outbox file's `to:` frontmatter, looks up the sender agent's `permissions:`, applies the ACL mapper to check `{chat:write:<channel> | agents:message:<target>}`, and either:
  - permitted → copy file to recipient's `inbox/` (or append to channel file), move source to sender's `history/`, emit `message.route` audit event.
  - denied → move source to sender's `history/` with `.rejected.md` suffix, append a rejection notice message to sender's `inbox/` explaining which permission was missing, emit `message.reject` audit event.
  Reason: denial is audible (agent sees the rejection) AND auditable, not a silent drop.
- **D-17:** Channel append — channels are append-only files (DESIGN.md §6.2); Router uses the same `[:append, :sync]` pattern as AuditLog to maintain ordering under concurrent routing.
- **D-18:** `@agent-name` detection — Router scans channel-append payloads for `@<name>` tokens matching the company's agent list; for each hit, writes a synthetic mention message to `agents/<name>/inbox/mentions/<timestamp>-<channel>.md`. Reason: keeps channel → agent-wake uniform with the inbox trigger path (no separate wake mechanism).

### [auto] Agent wake + execution (AGT-01, AGT-02)
- **D-19:** Per-agent GenServer — **one `Glorbo.Company.Agent` GenServer per agent**, under a DynamicSupervisor named `Glorbo.Company.<slug>.AgentSupervisor`. Holds `{company_slug, agent_slug, last_wake_at, current_task, ...}`. Reason: AGT-01 crash isolation — one agent crashing restarts only that agent. `max_restarts: 3, max_seconds: 60` at the DynamicSupervisor level.
- **D-20:** Wake dispatch — Router, Scheduler, and Watcher all call `Agent.wake(company, agent, trigger)` which either no-ops (already executing) or starts a `Task` under the agent's `Task.Supervisor` that runs the execution pipeline. Reason: keeps the GenServer responsive (wake is a short call), execution runs in a supervised task that can be killed on budget hard-stop or timeout.
- **D-21:** Heartbeat implementation — `Glorbo.Company.Scheduler` parses each agent's `heartbeat: "*/30 * * * *"` cron expression (library: `crontab` — pure-Elixir, no runtime job store needed) at start, uses `Process.send_after` with recomputed intervals. Reason: no Oban/Quantum dependency needed for simple cron; agents wake frequency is low (minutes).
- **D-22:** Task serialisation — Elixir writes `{task_path, trigger_type, trigger_payload, skills_resolved}` to a JSON file at `~/.glorbo/companies/<co>/agents/<ag>/state/current-task.json` just before invoking the worker. On crash recovery, the GenServer re-reads this to know if a task was in flight. Reason: durable wake state without Ecto roundtrip.
- **D-23:** Worker invocation — ephemeral by default (`mode: :ephemeral` via `ContainerManager.start_container/2` from Phase 2), persistent when `agent.md` declares `lifecycle: persistent`. Reason: matches DESIGN.md §5.3/§5.4 lifecycle and Phase 2's existing mode split.

### [auto] Budget tracking (SEC-05)
- **D-24:** Usage reporting — Python worker's `litellm.completion` call returns a `response.usage` dict; worker writes a JSON usage report to `agents/<name>/outbox/usage/<task_id>.json` (schema: `{task_id, timestamp, provider, model, prompt_tokens, completion_tokens, cost_usd}`) **after** writing the result. Reason: usage is a first-class outbox artifact; the Router routes it to the BudgetTracker.
- **D-25:** Cost source — `litellm.cost_per_token` (litellm's built-in cost DB) is the canonical source. Python worker includes `cost_usd` in the usage report. Reason: single source of truth; Ollama reports `cost_usd: 0.0` (local inference, no cost).
- **D-26:** Aggregation — `Glorbo.Company.BudgetTracker` GenServer handles usage reports, upserts into `budgets` Ecto schema (new in Phase 3: `{agent_slug, year_month, prompt_tokens, completion_tokens, cost_usd_cents}`), emits `budget.usage` audit event. Reason: one writer per company keeps monthly rollover deterministic.
- **D-27:** Hard-stop enforcement — **pre-dispatch check**. Before invoking the worker, the agent GenServer calls `BudgetTracker.check_budget(agent_slug)` which returns `:ok | {:alert, used_usd, cap_usd} | {:stop, used_usd, cap_usd}`. On `:stop`, the wake aborts and emits a `budget.hard_stop` audit event with a rejection message appended to the agent's inbox. Reason: prevents any further LLM spend without requiring mid-call kills.
- **D-28:** Alert propagation — at alert threshold (`alert_at_pct: 80` default), BudgetTracker emits a PubSub-ready broadcast and writes a marker file at `~/.glorbo/companies/<co>/alerts/<agent>-budget.md` (dashboard consumes in Phase 4). Reason: file artifact + PubSub hook ready for Phase 4 without requiring Phase 4 to land first.
- **D-29:** Monthly rollover — calendar-month boundary (UTC), no mid-month top-ups in v1. Reason: simplicity; matches DESIGN.md §8.1.

### [auto] Approval gates (SEC-04)
- **D-30:** Sentinel mechanism — tasks with `requires_approval: director` in frontmatter trigger a "pause on pick-up" in the agent GenServer. The agent writes `agents/<name>/state/awaiting-approval-<task_id>.md` containing `{task_path, requested_at}`, appends an `approval.requested` audit event, and goes back to idle. Reason: no polling, no background wait — the agent sleeps and wakes on approval file change.
- **D-31:** Approval mechanism — the Director updates the task file's `status: approved` (frontmatter) and optionally adds an `approved_by: director` + `approved_at: <ISO>` field. This is a file write to `projects/<p>/tasks/<t>.md`. The Watcher detects the change, the Router notices the status flip on an awaiting task, removes the sentinel, and wakes the agent with a `director-approval` trigger. Reason: keeps the mechanism filesystem-first and testable without dashboard UI.
- **D-32:** Approval denial — `status: denied` triggers cleanup (sentinel removed, `approval.denied` audit event, task moved to `history/` with denial reason) and does not wake the agent. Reason: symmetric to approval and auditable.
- **D-33:** Dashboard hook — Phase 4 will render awaiting-approval markers as an approval queue; Phase 3 ensures the markers exist and the file shape is stable.

### [auto] Skills injection (AGT-04)
- **D-34:** Injection point — **at dispatch time**, by Elixir. Skills named in `agent.md`'s `skills:` list are resolved from `~/.glorbo/skills/<name>.md`, concatenated into the task JSON under a `skills_resolved:` key (full markdown body, not a file path). The FastAPI worker injects them into the LLM prompt as system-prompt context. Reason: Python worker stays simple (receives ready-to-use text), avoids mounting a skills volume.
- **D-35:** Missing skill handling — unknown skill name → Router emits `skill.missing` audit event, drops the skill from the task's `skills_resolved:`, logs a warning, and proceeds. The task still runs. Reason: missing skill is recoverable; the Director notices the audit event.
- **D-36:** Skill precedence — skills are injected in the order listed in `agent.md`. No skill priority system. Reason: deterministic, simple.

### [auto] Cloud LLM provider wiring (LLM-03, LLM-04)
- **D-37:** API-key source — `~/.glorbo/config.md` frontmatter carries `api_keys: {anthropic: "sk-...", openai: "sk-...", google: "..."}`. File is chmod `0600`. Reason: DESIGN.md §4.3 + the CLAUDE.md "API keys never touch company directory" invariant.
- **D-38:** Key injection — at dispatch time, Elixir reads the relevant key based on `agent.md`'s `provider:`, injects it into the `/run` POST body (per Phase 2 D-37 — never an env var). Reason: preserves `podman inspect` leak resistance.
- **D-39:** Provider validation — before each dispatch, `provider` must be in `[ollama, huggingface, anthropic, openai, google]`. Unknown → `provider.unknown` audit event + agent error message. Reason: fails closed.
- **D-40:** One model per agent — enforced at `agent.md` parse time. `provider:` and `model:` are required when not `ollama`. Multiple models in one agent = validation error. Reason: locked by PROJECT.md Key Decision.

### [auto] Agent-creation-is-Director-only (AGT-05)
- **D-41:** Enforcement layer — the Router rejects any outbox message from an agent that would create/edit another agent's definition. Specifically: the Router inspects every routed message and if the recipient path contains `agents/<new>/agent.md` and the sender's permissions don't include `agents:create` (which no agent has in v1), the route is rejected with `permission.denied` audit. Reason: AGT-05 is enforced through the permission system (no agent has `agents:create` permission by default).
- **D-42:** Director path — the Director creates agents by writing `agent.md` files directly to the filesystem (outside any container). The Watcher picks up the new file, the Router does NOT apply the agent-creation restriction because the origin is not an outbox but a direct filesystem edit. Reason: trust model — the Director owns `~/.glorbo/` (PROJECT.md Out of Scope: multi-user).
- **D-43:** Self-spawn detection — integration test: spawn Agent X with full permissions, have its Python worker write `outbox/create-new-agent.md` containing an `agent.md` targeting `agents/rogue/`, assert the Router rejects it with `permission.denied` and no `agents/rogue/` directory appears.

### [auto] Supervision tree (AGT-01)
- **D-44:** Company supervisor children — **extend** Phase 2's 2-child shape (`AuditLog`, `Filesystem.Watcher`) to a 6-child shape: `AuditLog, Filesystem.Watcher, Router, Scheduler, BudgetTracker, AgentSupervisor (DynamicSupervisor)`. Reason: matches the crash-isolation invariant (CLAUDE.md) — killing any one child restarts only that subtree.
- **D-45:** Crash surface — Router crash → re-processes any unprocessed outbox files (Watcher rescans on init). BudgetTracker crash → rebuilds state from SQLite ledger. Scheduler crash → recomputes all agent heartbeats from `agent.md` files. Reason: all state is derivable from filesystem + SQLite (filesystem is source of truth).

### Claude's Discretion
- Exact ACL mapping table structure (Map vs behaviour module).
- Router file-routing queue shape (direct handle_info vs a work queue with a separate job struct).
- BudgetTracker internal state caching (in-memory cache with SQLite refresh, or SQLite-direct on every check).
- Scheduler's cron parsing library choice (`crontab` strongly recommended; alternatives acceptable).
- Whether per-agent Task.Supervisor is its own child of Company or a child of the agent GenServer.
- Audit event key names for new Phase 3 events (stable across the phase, refine in later milestones).
- Whether `budgets` table uses cents or fractional USD (cents strongly recommended — integer math).
- Whether skill files get a schema validation pass at Director-commit time or only at dispatch time (dispatch-time OK for v1).
- Inbox cleanup policy (message lifecycle inside `inbox/` — TTL, archive-to-history on read, etc.).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture (authoritative)
- `DESIGN.md` §5 — Agent Lifecycle (definition, waking, execution, sleeping). Full `agent.md` example at §5.1 is the schema contract.
- `DESIGN.md` §6 — Communication (inbox/outbox, channels, stdout). §6.1 has the message format; §6.2 has the channel append contract.
- `DESIGN.md` §7 — Permissions & Isolation. §7.1 defines `resource:action:scope`; §7.2 shows the two-layer enforcement; §7.3 covers company isolation.
- `DESIGN.md` §8 — Budget & Governance. §8.1 budget tracking; §8.2 approval gates (task frontmatter + workflow); §8.3 audit log (already implemented in Phase 2).
- `DESIGN.md` §12 — Security Considerations (threat model, defence-in-depth, prompt injection resistance).
- `DESIGN.md` §14 — Open Questions (may apply to Phase 3 decisions).

### Project-level constraints
- `CLAUDE.md` — Load-bearing invariants. Phase 3 is the phase where "kernel is the policy engine" and "inbox write-only for Elixir, outbox write-only for agent" become real (not stubs).
- `.planning/PROJECT.md` — Key Decisions table: POSIX ACLs for kernel-level enforcement; one provider+model per agent; filesystem-first; append-only audit.
- `.planning/REQUIREMENTS.md` — AGT-01..05, SEC-01..05, LLM-03, LLM-04 (12 requirements this phase must satisfy).
- `.planning/ROADMAP.md` Phase 3 — nine success criteria.

### Phase 2 handoff (direct dependencies)
- `.planning/phases/02-filesystem-foundation-container-runtime-local-llm/02-CONTEXT.md` — Read D-30..D-33 (Watcher topology/events/debounce/path-prefix), D-34..D-42 (Python worker API contract including `/run` body schema with `api_key` field and `litellm` dispatch), D-43..D-45 (Doctor schema additive-only rule).
- `.planning/phases/02-filesystem-foundation-container-runtime-local-llm/02-04-SUMMARY.md` — `Glorbo.Company.Supervisor` current 2-child shape + B5 test contract that Phase 3 must extend, not replace.
- `lib/glorbo/company/supervisor.ex` — the supervisor Phase 3 will extend.
- `lib/glorbo/company/router.ex`, `scheduler.ex`, `budget_tracker.ex` — Phase 1 stubs that Phase 3 fills in.
- `lib/glorbo/container/invocation.ex` — Phase 2's argv builder; Phase 3 passes `network: policy` through `extra_volumes:` + new `network_mode:` keyword.
- `lib/glorbo/container/worker_client.ex` — Phase 2's Finch-over-UDS client; Phase 3 adds `api_key` to the request body (already supported).

### External specs to investigate during research
- POSIX ACL semantics inside rootless Podman: https://docs.podman.io/en/latest/markdown/podman-run.1.html#userns — `keep-id` mapping behaviour with `setfacl`.
- `setfacl`/`getfacl` man pages — Fedora default acl tooling; the `setfacl -R -m u:<user>:rwx <path>` pattern.
- Netavark firewall primitives: https://github.com/containers/netavark — which versions support per-container egress filter rules; fallback to in-container iptables/nftables.
- slirp4netns allow-list options: https://github.com/rootless-containers/slirp4netns — `--allow-host-loopback=false` and CIDR filter support.
- Elixir `crontab` library: https://hex.pm/packages/crontab — cron expression parser + next-run calculator (used by Scheduler).
- litellm usage/cost API: https://docs.litellm.ai/docs/observability/custom_callback — `cost_per_token` + `completion_cost` helpers; response.usage shape.
- Ecto upsert patterns for monthly-bucket aggregation tables: https://hexdocs.pm/ecto/Ecto.Repo.html#c:insert/2 — `on_conflict: {:replace, [...]}` for usage accumulation.
- Cron heartbeat coexistence with DynamicSupervisor restarts: Elixir `Process.send_after` vs Erlang `:timer.send_interval` — choose the monotonic-clock-safe option.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`Glorbo.Company.Supervisor`** (`lib/glorbo/company/supervisor.ex`) — Phase 2 shipped a 2-child supervisor (AuditLog + Watcher). Phase 3 extends to 6 children without replacing the existing shape (B5 test assertion must be updated, not broken).
- **`Glorbo.Company.AuditLog`** (`lib/glorbo/company/audit_log.ex`) — `append/2` is the sole sink for every routing/budget/approval/permission event. No new audit primitives needed; just new event `action:` names.
- **`Glorbo.Filesystem.Watcher`** — already dispatches by path prefix (`agents/<n>/inbox|outbox`, `audit/`, `channels/`, else → reindex). Phase 3 wires the new Router GenServer as the subscriber for outbox events.
- **`Glorbo.Container.Invocation`** — `build_argv/4` accepts `extra_volumes: [...]` and enforces the RT-04 flag set. Phase 3 adds a `:network_mode` keyword → `--network none | slirp4netns:... | default`.
- **`Glorbo.Container.WorkerClient`** — `post_run/3` already sends `api_key` in the POST body. Phase 3 just populates it from the `~/.glorbo/config.md` lookup.
- **`Glorbo.Repo` + Ecto schemas** — Phase 2 shipped `companies, agents, audit_events, reindex_state`. Phase 3 adds `budgets, tasks_approval_state` (new) and possibly extends `agents` with `permissions_hash` (for cheap ACL-change detection).

### Established Patterns
- **Dep-injection via keyword opts** — Phase 1 Doctor pattern, preserved in Phase 2 Orchestrator. Phase 3 extends the pattern: Router, Scheduler, BudgetTracker all accept `opts` for testability (mock filesystem, mock Ecto, mock container invocation).
- **Integration tests gated with `@moduletag :integration`** — Phase 3 adds `@moduletag :acl` (requires setfacl + kernel FS with ACL support — tmpfs may not) and `@moduletag :netavark` (requires compatible Podman/netavark version). Host-less CI jobs exclude both; doctor check flags gaps.
- **File-artefact + PubSub hook readiness** — Phase 2 established the pattern (sockets dir, stdout.log, alert marker files) of creating dashboard-consumable artefacts even before the dashboard exists. Phase 3 continues this with `state/awaiting-approval-*.md` and `alerts/<agent>-budget.md`.
- **W2-scope integration test pattern** — Phase 2 introduced it; Phase 3 extends the same convention to `W3: kernel ACL enforcement round-trip`, `W4: api-only egress rejection`.

### Integration Points
- **Phase 4 handoff:** All file-artefact shapes created in Phase 3 (approval sentinels, budget alerts, rejection messages) become the consumer set for the LiveView dashboard. Shapes must be stable between Phase 3 commit and Phase 4 read.
- **Phase 5 handoff:** `glorbo logs <agent>` surfaces the agent's recent audit events + usage reports + inbox/outbox deltas. The audit-event key naming in Phase 3 determines the log shape in Phase 5.
- **Backward compat with Phase 2:** Phase 3 MUST NOT change the `/run` POST body shape (stability invariant). New fields are additive: Phase 3 may ADD `skills_resolved:` to the request body but must not rename or remove `api_key`, `task_path`, `provider`, `model`.

</code_context>

<specifics>
## Specific Ideas

- **"Kernel is the policy engine" becomes real in Phase 3.** This is the phase where CLAUDE.md's load-bearing invariant gets operationalised: every outbox-to-inbox transfer is Router-mediated, every filesystem write by a Python worker has to pass through POSIX ACLs, every LLM call has to pass the budget hard-stop check. The whole point of Phase 3 is to stop trusting the agent (or its LLM-generated Python) and let the kernel enforce.
- **Defence in depth is three-layered here, not two.** DESIGN.md §7.2 describes two layers (Elixir Router + POSIX ACLs); in practice Phase 3 adds a third (network policy via Podman/netavark). The integration test suite must exercise all three independently: (a) Router rejects a permission-missing outbox message; (b) ACL rejects a `podman exec` filesystem write; (c) Network policy rejects an egress attempt from an `api-only` agent to a non-allowed host.
- **Budget hard-stop is pre-dispatch by design.** Not "kill the container mid-call" — that would waste tokens already paid for and could leave the agent in a weird intermediate state. Check-before-dispatch means the worst case is one call slightly over the cap (the one that crosses the threshold during execution), which is acceptable trivia; next call refuses. This matches the litellm cost-reporting shape (cost is known AFTER the call, not before).
- **Approval gates use file mutation deliberately.** The dashboard in Phase 4 is "a tail of file state" — if approval can be expressed as a file edit, the dashboard is a render of that file state and nothing more. Any approval mechanism that doesn't reduce to a file edit adds a parallel source of truth that the dashboard would have to learn. This is why `status: approved` in task frontmatter is the canonical approval signal, not a Phoenix Channel message or a SQLite UPDATE.
- **Agent-creation restriction is a permission, not a special case.** AGT-05 is enforced purely through the `permissions:` system: no agent is issued `agents:create`, so no agent can write `agents/<new>/agent.md`. The Director has implicit `agents:create` by owning `~/.glorbo/` (filesystem UID). This falls out of the existing mechanism; no new code path.
- **litellm is the one-error-surface promise.** Every provider's errors — OpenAI 429s, Anthropic overload, Ollama connection refused, Google auth expired — surface as `litellm.exceptions.*`. The Router's retry/budget logic handles one taxonomy, not five. This reaffirms Phase 2 D-40 from the Phase 3 perspective.
- **Target feel for Phase 3:** Director edits `companies/acme/agents/engineer/agent.md`, saves, the Engineer's GenServer picks up the change, ACLs get reconciled at next container start, budget ledger resets on month boundary, an @Engineer mention in `channels/engineering.md` wakes the agent which picks a task, requests Director approval for a `requires_approval: director` task, the Director flips `status: approved` in the task file, the agent executes, writes result to outbox, Router routes back to CEO's inbox with permission checks. All of that happens without the dashboard existing.

</specifics>

<deferred>
## Deferred Ideas

- **Agent-spawn-agent** — permanently out of v1 per PROJECT.md. Revisit in v2 with a governance model that a single-Director trust model doesn't need.
- **Mid-run budget rebalancing / top-ups** — v1 uses calendar-month buckets with no mid-month adjustment. v2 may add if a user requests.
- **Fine-grained time-based permissions** (e.g. "chat:write only on weekdays") — not in v1; all permissions are unconditional.
- **Per-message quotas** (separate from USD budget) — v1 uses only USD; message-count caps deferred.
- **Remote skills marketplace / skill sharing across companies** — v1 skills are local-filesystem only.
- **Router-level rate limiting** (e.g. max 100 messages/minute per agent) — deferred; OTP supervisor's `max_restarts` handles pathological cases for now.
- **ACL enforcement on host-side `~/.glorbo/` dirs** — v1 only applies ACLs inside the container (where the Python worker runs). Host-side ACLs would matter only in a multi-user trust model (PROJECT.md Out of Scope).
- **`agents:create` permission for "agent template bots"** — v2; meshes with template marketplace.
- **Websocket-level stdout streaming** from worker → Elixir (bypassing the file-tail indirection) — Phase 2 already committed to file-tail; revisit only if dashboard latency becomes a UX problem.
- **Per-company proxy** (HTTP proxy for `api-only` egress going through a corporate proxy) — configurable via `network_allow:` + proxy env var in v1.1 if needed; out of Phase 3.

</deferred>

---

*Phase: 03-agents-routing-kernel-permissions-budgets*
*Context gathered: 2026-04-16*
*Mode: --auto (all decisions at recommended defaults; override by editing before /gsd-plan-phase)*
