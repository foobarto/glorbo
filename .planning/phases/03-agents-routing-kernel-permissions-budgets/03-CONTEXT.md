# Phase 3: CLI Agent Runtime + bwrap Isolation + Routing + Budgets - Context

**Gathered:** 2026-04-16 (post-CLI-agent pivot)
**Status:** Ready for planning
**Mode:** Restructured after mission-control-inspired pivot from Python-in-container runtime to CLI-first agents. Original container-runtime design archived at `.planning/deferred/container-runtime-v0.0.2/`.

<domain>
## Phase Boundary

Markdown `agent.md` files become live, supervised, bwrap-sandboxed CLI workers that pick up tasks via inotify, collaborate via filesystem-based inbox/outbox routing, honour permissions at the Elixir Router AND the bwrap namespace layer, track USD budgets parsed from each CLI tool's session telemetry, and escalate approval-gated work to the Director via task-file `status:` edits.

The agent runtime is a **short-lived `bwrap` sandbox** that spawns one of `claude -p`, `gemini`, or `codex` with the agent's workspace bind-mounted read/write, sibling agents + other companies bind-mounted denied, and network policy enforced at `bwrap` launch. Elixir writes the task prompt + skills into the workspace just before invocation; the CLI tool runs, writes results to outbox; Elixir's Router mediates every outbox→inbox transfer.

**In scope:**
- Per-company OTP supervision tree extended to 6 children: `AuditLog + Filesystem.Watcher + Router + Scheduler + BudgetTracker + AgentSupervisor`
- Per-agent GenServer under DynamicSupervisor with wake-queue state machine (4 triggers: inbox, cron, channel mention, Director request)
- `Glorbo.Sandbox.Bwrap` invocation builder that produces a `bwrap` argv from the agent's `permissions:` + `network:` declarations
- CLI provider dispatch: `provider: claude-code | gemini-cli | codex` spawns the right binary with the right flags
- Skills materialisation: `skills:` list → agent workspace `.glorbo-skills/` just before invocation; removed after
- Usage parsing per CLI tool: Claude Code session JSONL extraction; Gemini/Codex token-tracking analogs
- Budget pre-dispatch check + hard-stop + alert threshold file markers
- Approval gate via task `status: approved` edit → Watcher → Gate → agent wake
- `Glorbo.Approvals.Gate` GenServer
- Agent-creation restriction enforced via Router (no agent has `agents:create` permission)
- Full kernel-observed integration tests (filesystem denial via bwrap, network denial via `--unshare-net`)

**Out of scope (deferred to container runtime phase — see `.planning/deferred/container-runtime-v0.0.2/`):**
- Python-in-Podman agent runtime, litellm dispatch, FastAPI worker, UDS transport
- POSIX ACL enforcement via `setfacl` (infrastructure shipped in Plan 03-01 as dormant code; exercised when container phase ships)
- Per-agent Linux user provisioning with `/etc/subuid`-relative UID blocks (`UidAllocator` shipped in Plan 03-01, dormant)
- LLM-05 offline inference via Ollama — CLI tools need their providers' cloud endpoints; offline support returns with the container runtime phase (or a future `provider: ollama-cli` option)
- Per-agent budgets via Python-worker-reported `cost_usd` (budget tracking ships in this phase but via CLI session telemetry, not litellm)

</domain>

<decisions>
## Implementation Decisions

### CLI agent dispatch
- **D-01:** Agent invocation shape — `bwrap <sandbox-args> <cli-tool> -p <prompt>`. One process tree per invocation, clean exit reclaims all resources. No persistent process pool. Reason: matches DESIGN.md §5 ephemeral lifecycle + avoids long-lived state complexity.
- **D-02:** Supported providers in v0.0.1 — `claude-code`, `gemini-cli`, `codex`. Strict allowlist parsed from `agent.md`. Unknown provider → parse-time error. Reason: limits attack surface; each provider needs an explicit Elixir adapter (`Glorbo.CLI.Adapter.ClaudeCode` etc.).
- **D-03:** Prompt delivery — each invocation writes `task-prompt.md` to the agent's workspace `.glorbo-run/<task-id>/`; the CLI tool is invoked with the prompt passed via stdin AND with the workspace as working directory. Reason: CLI tools differ in prompt mechanisms (stdin vs `-p` vs file-arg); stdin is universal, file is inspectable for audit.
- **D-04:** Skills materialisation — Elixir copies every skill listed in `agent.md`'s `skills:` from `~/.glorbo/skills/<n>.md` to the agent workspace under `.glorbo-skills/<n>.md` just before invocation. Elixir ALSO writes a `.glorbo-skills/INDEX.md` listing the skills + their purpose. The CLI tool's prompt includes "Available skills in `.glorbo-skills/`" so the tool can read them on demand. Reason: CLI-agnostic skill injection; preserves filesystem-first principle.
- **D-05:** Cleanup — post-invocation, Elixir removes `.glorbo-run/<task-id>/` and `.glorbo-skills/` from the workspace. Agent's own files (`outbox/`, `workspace/`, `state/`) persist. Reason: prevents stale skill/prompt leakage across invocations.
- **D-06:** Timeout — global default 300s per CLI invocation with per-agent override via `agent.md` `timeout_seconds:`. On timeout, Elixir sends SIGTERM to the bwrap process (which cascades to the child CLI), waits 5s, then SIGKILL. Logs `timeout` audit event. Reason: mirrors Phase 2 D-41 pattern.
- **D-07:** stdout/stderr — streamed to `agents/<name>/stdout.log` via `Port` → `File.open!([:append, :sync])`. Same tailing path as Phase 2; dashboard-ready. Reason: keeps Phase 4 dashboard hookup uniform across agent runtimes.

### bwrap sandbox architecture
- **D-08:** Base sandbox flags — `--die-with-parent --unshare-user-try --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup-try --new-session --cap-drop ALL`. Reason: namespace isolation without requiring extra capabilities.
- **D-09:** Filesystem bind strategy:
  - `--ro-bind /usr /usr` + `--ro-bind /bin /bin` + `--ro-bind /lib /lib` + `--ro-bind /lib64 /lib64` + `--ro-bind /etc /etc` (tool availability)
  - `--bind <company-path>/agents/<name>/workspace /workspace` (read/write for the agent)
  - `--bind <company-path>/agents/<name>/outbox /outbox` (write for the agent)
  - `--ro-bind <company-path>/agents/<name>/inbox /inbox` (read-only per DESIGN.md §6.1)
  - Per-permission mounts for `projects:read:*` / `projects:write:<name>` / `chat:read:*` etc. (see D-11)
  - Everything else in the company filesystem: NOT mounted (invisible to sandbox)
  - `--tmpfs /tmp` (scratch space)
  - `--proc /proc` + `--dev /dev`
- **D-10:** Default-deny for `~/.glorbo/companies/<other-co>/` — other companies are never mounted. Company isolation is absolute (CLAUDE.md invariant), enforced by bwrap's simple "not mounted = not visible" model. No cross-company access is possible because there's no path in the sandbox that could point to another company.
- **D-11:** Permission → bwrap mapping (`Glorbo.Sandbox.PermissionMapper`):
  - `projects:read:*` → `--ro-bind <co>/projects /projects`
  - `projects:read:<name>` → `--ro-bind <co>/projects/<name> /projects/<name>` (parent dir NOT mounted; sibling projects invisible)
  - `projects:write:<name>` → `--bind <co>/projects/<name> /projects/<name>`
  - `chat:read:*` → `--ro-bind <co>/channels /channels`
  - `chat:write:<channel>` → writes go through outbox (Router appends to channel), so mount is still `--ro-bind` for the channel file; this is enforced at the filesystem level AND at the Router layer
  - `agents:message:<target>` → no filesystem mount needed (message goes via outbox → Router)
  - `agents:list` → `--ro-bind <co>/agents /agents` (with per-agent subpath filtering — see D-12)
  - `tools:execute:<tool>` → not a filesystem concern; handled at prompt-injection level
- **D-12:** Sibling-agent invisibility — when `agents:list` is granted, only the sibling agents' `agent.md` files are exposed (via a staging tmpfs that Elixir populates just-in-time). Sibling agents' private dirs (`inbox/`, `workspace/`, `state/`) stay unmounted. Reason: `agents:list` should not leak other agents' data; it's a directory listing, not full read access.
- **D-13:** Testing hook — `Glorbo.Sandbox.Bwrap.build_argv/2` returns a plain argv list; `start/2` wraps `Port` invocation. Unit tests assert argv composition without actually running bwrap. Integration tests tagged `:bwrap` require bwrap binary + kernel unprivileged user namespaces.

### Network policy
- **D-14:** Policy values — `none` (default), `api-only`, `open`. Same as original design.
- **D-15:** Enforcement via bwrap:
  - `none` → `--unshare-net` (no network namespace access, kernel-enforced)
  - `api-only` → Elixir creates a named netns via `ip netns add` with nftables rules allowing only the provider's endpoints; sandbox joins it via `--unshare-net` + the agent UID's netns mapping (technique: precreate the netns, run bwrap with `--setenv NETNS=<name>` and an `unshare`-equivalent inside). In practice, simpler approach: spawn a userspace proxy on loopback inside the sandbox and route all egress through it (TinyProxy / Envoy). Final choice in planning.
  - `open` → inherit host netns (bwrap default when no `--unshare-net` flag). Reason: explicit opt-in.
- **D-16:** `api-only` allowlist — static base list in `config/network_policy.exs` (Anthropic, OpenAI, Google, Hugging Face endpoints). Per-company override in `company.md` `network_allow:`. Reason: parallel to original D-12 but simpler (no netavark).
- **D-17:** `api-only` initial implementation — ship the simpler-but-weaker option first: spawn the CLI tool inside a shared-netns sandbox (no `--unshare-net`) but set `HTTP_PROXY` + `HTTPS_PROXY` env vars pointing at a Glorbo-managed proxy that enforces the hostname allowlist. Research "host network namespace + per-process egress filter via proxy" as the v0.0.1 route; netns + nftables is deferred to a follow-on iteration. Reason: pragmatic — a proxy is easier to test + debug than per-agent netns, and covers the threat (agents can't reach disallowed hosts if they respect proxy env vars). A motivated agent could bypass the proxy by ignoring env vars, so this is advisory-only for v0.0.1; the netns+nftables path is a hardening iteration.
- **D-18:** `api-only` integration test — spawns agent, sets up a mock endpoint server at an allowed + a disallowed host, agent attempts both, assert only the allowed request succeeds.

### Router + Watcher wiring (carries forward from original Phase 3)
- **D-19:** Router shape — single per-company `Glorbo.Company.Router` GenServer under Company supervision tree. Subscribes to Watcher's outbox events. Reason: single auditable choke point per company.
- **D-20:** Routing flow — per-outbox-file: parse `to:` frontmatter, look up sender `permissions:`, check `{chat:write:<channel> | agents:message:<target>}`, route or reject. Rejection = move source to `history/<id>.rejected.md` + append rejection notice to sender's inbox + audit event. Reason: filesystem-first, debuggable, auditable.
- **D-21:** Channel append — append-only file via `[:append, :sync]`. `@<name>` mentions scanned in routed payloads; write synthetic mention message to `agents/<name>/inbox/mentions/<ts>-<channel>.md`. Reason: uniform wake mechanism.
- **D-22:** Agent-creation restriction — Router rejects any routed message whose payload would write `agents/<new>/agent.md`. No agent has `agents:create` permission in v0.0.1. Reason: AGT-05 via existing permission system, no new code path.

### Scheduler (heartbeats)
- **D-23:** Library — `crontab` Hex package (already resolved via Plan 03-01's Wave-0 foundation commit). Reason: pure Elixir, no Quantum/Oban dep.
- **D-24:** Implementation — `Glorbo.Company.Scheduler` GenServer parses each agent's `heartbeat:` cron expression at start, computes next-run via `Crontab.Scheduler.get_next_run_date/1`, uses `Process.send_after`. Recomputes from wall-clock on every firing (Pitfall 7 self-healing across VM pauses). Reason: simple, correct under clock jumps.

### Per-agent GenServer
- **D-25:** Topology — `Glorbo.Agent.Server` GenServer per agent, under `Glorbo.Company.AgentSupervisor` (DynamicSupervisor). Holds `{company_slug, agent_slug, pending_wakes, current_task, budget_state}`. Reason: AGT-01 crash isolation.
- **D-26:** Wake-queue state machine — deduplicate wakes (if a cron fires while the agent is already executing, queue one more; further queued wakes coalesce). On finish, pop next wake. Reason: prevents runaway wake accumulation under chatty inotify.
- **D-27:** Dispatch pipeline — budget check → skills materialise → prompt write → CLI provider resolve → bwrap argv build → Port.open → stdout tail → wait for exit → usage parse → budget record → skills cleanup → workspace cleanup. Reason: linear, testable, one `Task`-supervised invocation per wake.
- **D-28:** Task.Supervisor — per-agent `Task.Supervisor` (child of agent GenServer's supervision subtree). Keeps invocations isolated from the GenServer process so long-running Port work doesn't block message handling. Reason: OTP best practice.

### Budget tracking
- **D-29:** Usage source — **each CLI tool's session telemetry**. Concrete mechanisms (verify in research):
  - Claude Code writes session JSONL to `~/.claude/projects/<encoded-path>/<session-uuid>.jsonl` with `usage` entries per assistant turn. Glorbo configures `CLAUDE_PROJECT_DIR` per-invocation to capture this in the agent workspace.
  - Gemini CLI — TBD (research: does `gemini` CLI write a usage log? if not, Glorbo parses the CLI's final-result output or uses a wrapper script).
  - Codex — TBD (research: session/usage hooks).
  Plan 03-02 research sub-task must resolve the Gemini + Codex paths before execution.
- **D-30:** Cost calculation — Elixir maps `{provider, model, prompt_tokens, completion_tokens}` → USD via a per-model rate table in `config/llm_rates.exs`. Reason: CLI tools often don't report cost directly; Glorbo owns the mapping.
- **D-31:** Ledger shape — `Glorbo.Budget` schema (already shipped in Plan 03-01) with `{company_id, agent_slug, year_month, prompt_tokens, completion_tokens, cost_usd_cents}`. One row per agent-month. Atomic upsert via `on_conflict` with increment pattern. Reason: Plan 03-01 already validated the schema; this phase exercises it.
- **D-32:** Hard-stop — pre-dispatch check. `BudgetTracker.check_budget(agent_slug)` returns `:ok | {:alert, used, cap} | {:stop, used, cap}`. `:stop` aborts wake, writes rejection to inbox, emits `budget.hard_stop` audit event. Reason: matches original design; simpler than mid-call kills.
- **D-33:** Alert marker — at threshold, write `alerts/<agent>-budget.md` with `used_usd, cap_usd, threshold_pct, month` frontmatter. Phase 4 dashboard consumer lands later. Reason: file-artefact pattern from Phase 2.

### Approval gates (carries forward)
- **D-34:** Sentinel mechanism — tasks with `requires_approval: director` trigger a pause: write `agents/<name>/state/awaiting-approval-<task_id>.md`, append `approval.requested` audit event, return to idle. Reason: filesystem-first; no polling.
- **D-35:** Approval — Director edits task `status: approved` in frontmatter; Watcher detects; Router notifies Gate; Gate removes sentinel and wakes agent with `director-approval` trigger. Reason: matches DESIGN.md §8.2.
- **D-36:** `Glorbo.Approvals.Gate` GenServer — per-company; listens to Watcher for `projects/**/*.md` status changes; correlates with sentinels in `agents/*/state/awaiting-approval-*.md`. Reason: single choke point; crash-recoverable from filesystem state.
- **D-37:** Denial — `status: denied` triggers `approval.denied` audit event, sentinel removed, task moved to `history/`. Reason: symmetric to approval.

### Skills injection (CLI-adapted)
- **D-38:** Injection path — `Glorbo.Skills.Resolver.materialize/3` copies named skills into agent workspace's `.glorbo-skills/` just before invocation (D-04); cleanup after (D-05). Reason: avoids bind-mount complexity; CLI tools don't need to know about Glorbo's skill paths.
- **D-39:** Missing skill — unknown skill name → `skill.missing` audit event; dropped from invocation; task still runs. Reason: recoverable; Director notices the audit.
- **D-40:** Skill order — injected in `agent.md`'s `skills:` list order. No priority system. Reason: deterministic + simple.

### Provider adapters
- **D-41:** Adapter behaviour — `Glorbo.CLI.Adapter` behaviour with callbacks: `binary/0` (returns CLI path), `args/3` (task_path, workspace, opts → CLI args), `usage_path/2` (agent, workspace → path to session telemetry), `parse_usage/1` (usage file → `{prompt_tokens, completion_tokens, cost_usd}`).
- **D-42:** Initial adapters — `Glorbo.CLI.Adapter.ClaudeCode`, `Glorbo.CLI.Adapter.GeminiCli`, `Glorbo.CLI.Adapter.Codex`. ClaudeCode has the highest-confidence implementation (session JSONL documented); Gemini/Codex require research in Plan 03-02.
- **D-43:** Validation — `agent.md` parse validates `provider:` is in `[claude-code, gemini-cli, codex]` and that the corresponding CLI binary is on `PATH`. Missing binary → `provider.unavailable` audit event + agent cannot wake (equivalent to budget hard-stop).

### Supervision tree
- **D-44:** Six-child Company supervisor: `AuditLog + Filesystem.Watcher + Router + Scheduler + BudgetTracker + AgentSupervisor`. (Original plan's 7-child shape with separate `Approvals.Gate` is collapsed here — Gate lives as a DynamicSupervisor'd child of Router since both listen to the same Watcher stream; cleaner than two sibling listeners.) Reason: fewer moving parts for v0.0.1.
- **D-45:** Crash surface — Router crash → Watcher will re-emit recent outbox events on subscriber re-register. BudgetTracker crash → rebuilds from SQLite ledger. Scheduler crash → recomputes heartbeats from `agent.md` files. Reason: all state derivable from filesystem + SQLite.

### Claude's Discretion
- Exact `bwrap` argv ordering and grouping (security-relevant — researcher should propose a locked canonical order).
- Whether skill materialisation happens at wake-time or at container-start (for persistent agents — but persistent agents may not apply to CLI mode; decide during planning).
- TinyProxy vs HTTP-filtering proxy vs `Glorbo.Proxy` custom for `api-only` — weigh in research; pick the smallest thing that meets the threat.
- Cron parsing library edge cases — `crontab` Hex is selected but minor alternatives acceptable if needed.
- Per-agent Task.Supervisor placement (child of agent GenServer vs sibling of agent GenServer under AgentSupervisor).
- Workspace cleanup granularity — per-task-id vs per-invocation vs per-day.
- Adapter module naming (e.g., `Glorbo.CLI.Adapter.ClaudeCode` vs `Glorbo.Providers.ClaudeCode` — cosmetic).
- Whether `agent.md`'s `model:` field is required for `claude-code`/`gemini-cli`/`codex` (each CLI has its own model-selection mechanism — probably yes, forwarded as `--model` equivalent).
- Audit event naming for Phase 3 events (stable within phase; refine in later milestones). AUDIT_EVENTS.md shipped by Plan 03-01 is the starting point.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture (authoritative)
- `DESIGN.md` §5 — Agent Lifecycle. Definition frontmatter (§5.1) stays valid; §5.3 execution pipeline now replaces `podman run` with `bwrap + CLI`.
- `DESIGN.md` §6 — Communication. Inbox/outbox/channel mechanics unchanged.
- `DESIGN.md` §7 — Permissions & Isolation. §7.2 two-layer enforcement now reads: Layer 1 Router (unchanged) + Layer 2 bwrap namespace (replaces POSIX ACL).
- `DESIGN.md` §8 — Budget & Governance. §8.1 now sources usage from CLI telemetry instead of Python worker.

### Project-level
- `CLAUDE.md` — Load-bearing invariants (kernel is policy engine — bwrap is the kernel layer now; filesystem source of truth; audit append-only).
- `.planning/PROJECT.md` — Key Decisions table (still accurate; add "CLI-first agents in v0.0.1" entry in transition).
- `.planning/REQUIREMENTS.md` — AGT-01..05, SEC-01..05, LLM-03, LLM-04 (re-scoped definitions for SEC-02, SEC-03, SEC-05, LLM-03 — see REQUIREMENTS.md).
- `.planning/ROADMAP.md` Phase 3 — Updated success criteria (bwrap, CLI telemetry).

### Plan 03-01 (executed; foundations still in codebase)
- `lib/glorbo/security/acl_mapper.ex` — DORMANT in v0.0.1; reserved for container runtime phase.
- `lib/glorbo/runtime/uid_allocator.ex` — DORMANT in v0.0.1; reserved for container runtime phase.
- `lib/glorbo/budget.ex`, `lib/glorbo/tasks_approval_state.ex` — Ecto schemas, exercised by this phase's BudgetTracker + Gate.
- `priv/repo/migrations/20260416*.exs` — migrations applied.
- `containers/glorbo-runtime/worker/*` — worker extensions (skills_resolved, usage reports) — DORMANT; revived with container runtime phase.
- `.planning/phases/03-agents-routing-kernel-permissions-budgets/AUDIT_EVENTS.md` — audit event registry; stays authoritative.

### Deferred archive (reference for future container runtime phase)
- `.planning/deferred/container-runtime-v0.0.2/README.md` — restoration guide.
- `.planning/deferred/container-runtime-v0.0.2/03-CONTEXT.md` — original 45 decisions; many transferable.
- `.planning/deferred/container-runtime-v0.0.2/03-RESEARCH.md` — netavark, subuid, litellm research; still relevant.

### External specs to investigate during research
- bubblewrap docs: https://github.com/containers/bubblewrap — argv reference, `--ro-bind-try` semantics, `--unshare-net` behaviour, `--die-with-parent`, userns requirements.
- bwrap + user namespace requirements: kernel ≥ 3.8, `user.max_user_namespaces > 0`, `kernel.unprivileged_userns_clone = 1` (Debian/Ubuntu); Fedora has this enabled by default.
- Claude Code session telemetry format: investigate `~/.claude/projects/<path>/<session>.jsonl` schema. Look for `usage` event entries.
- Gemini CLI token-tracking: is there a `--log-usage` flag or session export? Research needed.
- Codex CLI session/usage output: same.
- Mission Control reference implementation: https://github.com/MeisnerDan/mission-control — inspiration for CLI-agent dispatch patterns.
- HTTP allowlist proxy options: TinyProxy (https://tinyproxy.github.io/), Envoy's "Direct Response" filter (hostname allowlist), or a custom Elixir proxy (OTP-native).
- Elixir Port cleanup semantics: https://hexdocs.pm/elixir/Port.html — `:noshell`, `:exit_status`, signal propagation.
- `elixir:Process.alive?` + `MuonTrap` interaction with bwrap — does MuonTrap.Daemon cleanly kill the whole `bwrap` process tree on SIGTERM? (Phase 2 used MuonTrap; verify the cleanup path.)
- nftables vs HTTP proxy for `api-only` enforcement — tradeoffs.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable assets (from Plan 03-01 + Phase 2)
- **`Glorbo.Company.Supervisor`** — extend from Phase-2's 2-child to 6-child shape (AuditLog + Watcher already present; add Router + Scheduler + BudgetTracker + AgentSupervisor).
- **`Glorbo.Company.AuditLog`** — sole audit sink; just new `action:` keys (AUDIT_EVENTS.md registry).
- **`Glorbo.Filesystem.Watcher`** — already path-prefix routes; wire outbox events → Router, approval status events → Approvals.Gate, usage events → BudgetTracker.
- **`Glorbo.Budget`** schema (Plan 03-01) — exercised by new `Glorbo.Budget.Ledger` module.
- **`Glorbo.TasksApprovalState`** schema (Plan 03-01) — exercised by `Glorbo.Approvals.Gate`.
- **`Glorbo.Company.Router/Scheduler/BudgetTracker`** — Phase-1 stubs to fill in.
- **`Glorbo.Agent.Server`** — Phase-1 stub dir; fill with the per-agent GenServer design (D-25..D-28).

### Established patterns (from prior phases)
- **Dep-injection via keyword opts** — all new GenServers accept `opts` keyword for testability (mock filesystem, mock CLI adapter, mock budget ledger).
- **Integration test tags** — add `:bwrap` (requires bubblewrap binary + kernel unprivileged userns) and `:claude_code` (requires `claude` CLI on PATH). Doctor flags host gaps.
- **File-artefact + PubSub hook** — approval sentinels, budget alerts, rejection messages — all dashboard-consumable shapes to finalize now, Phase 4 reads them.

### Integration points
- **Phase 4 handoff:** Dashboard consumes approval sentinels + budget alerts + audit events + stdout tails; shapes must be stable post-Phase 3.
- **v0.0.2 container runtime handoff:** `ACLMapper` + `UidAllocator` + worker extensions already in tree; the container runtime phase adds the dispatch shell around them without revisiting foundations.

</code_context>

<specifics>
## Specific Ideas

- **bwrap is the right kernel isolation for the CLI-first approach.** Podman + POSIX ACL was the right isolation for an arbitrary-code Python runtime where the threat model includes "LLM-generated Python escapes its scope". For CLI tools whose executable code Glorbo doesn't control (the CLI tool itself is trusted, the LLM's *output* is what varies), bwrap's mount-namespace + netns isolation plus Elixir's Router checks are defence-in-depth at the right level. A malicious agent prompt can only do what the bwrap-permitted mounts + network policy allow.
- **Claude Code's session JSONL is a gift.** Token usage is already structured + persisted. Glorbo just has to point `CLAUDE_PROJECT_DIR` at the agent workspace and tail the JSONL. Gemini + Codex are the research unknowns — if neither has clean telemetry, Glorbo wraps them with a usage-tracking proxy that counts stdin/stdout tokens approximately and flags the imprecision to the Director.
- **"Filesystem is source of truth" stays 100% intact.** Every state change the agent cares about is a file write; Elixir mediates every file write across agent boundaries. The CLI tool works in its own sandboxed filesystem view and emits results there; the Router picks them up.
- **v0.0.2 is the "hardened" story.** v0.0.1 ships something the user can actually run with their existing CLI tools this week. v0.0.2 adds the full container-isolated Python runtime for agents where the user wants bulletproof isolation (e.g., running agents with LLM-generated tools, or running untrusted agent definitions). Both runtimes coexist — the `provider:` field picks which path.
- **Target feel for Phase 3:** Director writes `agents/engineer/agent.md` with `provider: claude-code`. Director starts Glorbo. Agent wakes on inbox event, Glorbo spawns `bwrap --ro-bind / / --bind workspace /workspace --unshare-net -- claude -p < task.md`, Claude does its thing with workspace access only, writes to outbox. Elixir routes outbox to CEO's inbox. Budget ledger shows `$0.12 this month`. All without any container, Podman, Python, or litellm — just Elixir + bwrap + the CLI tool Director already has.

</specifics>

<deferred>
## Deferred Ideas

- **Python-in-container agent runtime + litellm dispatch** — moved to `.planning/deferred/container-runtime-v0.0.2/`. Returns as a future phase.
- **POSIX ACL enforcement** — moved; `ACLMapper` sits dormant in `lib/` until revived.
- **Per-agent Linux user provisioning** — moved; `UidAllocator` sits dormant.
- **LLM-05 offline Ollama inference** — CLI tools need cloud endpoints. Offline returns with container runtime phase OR a future `provider: ollama-cli` that spawns `ollama run` as an agent. Not in Phase 3.
- **Anthropic/OpenAI/Google direct-SDK providers** — v0.0.2+ via litellm-in-container. v0.0.1 delegates auth to each CLI tool.
- **`api-only` via netavark / in-namespace nftables** — v0.0.1 ships proxy-based enforcement (D-17); netns + nftables deferred to iteration.
- **Agent-created agents** — permanently out of v1.
- **Router-level rate limiting** — OTP `max_restarts` handles pathological cases; explicit rate limiting deferred.
- **Websocket/SSE stdout streaming** — file-tail path still wins.
- **Time-based permission windows** — not in v1.
- **Per-message quotas** — USD-only in v1.

</deferred>

---

*Phase: 03-agents-routing-kernel-permissions-budgets*
*Context gathered: 2026-04-16 (CLI-agent pivot)*
*Supersedes: `.planning/deferred/container-runtime-v0.0.2/03-CONTEXT.md`*
