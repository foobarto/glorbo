# Phase 3: Agents, Routing, Kernel Permissions, Budgets — Research

**Researched:** 2026-04-16
**Domain:** Multi-agent runtime + kernel-layer POSIX ACL enforcement + per-agent network policy + per-agent USD budget ledger + Director approval gates (Elixir/OTP + rootless Podman + Python/litellm)
**Confidence:** HIGH on budget + cron + Ecto upsert; HIGH on ACL mechanics inside rootless Podman; **MEDIUM on per-container network egress allow-list** (no native netavark primitive — requires iptables/nftables fallback inside the container); HIGH on litellm error taxonomy + usage schema.

## Summary

Phase 3 is where four formerly-independent runtime layers interlock: (1) a per-company 6-child OTP supervision tree, (2) a declarative-YAML → POSIX-ACL compiler reconciling `agent.md:permissions[]` into `setfacl` calls inside a rootless Podman container, (3) a Router GenServer that mediates every outbox→inbox/channel write and does Elixir-layer permission checks before the kernel layer even gets to say no, and (4) a BudgetTracker that ingests `litellm.completion_cost()` output from usage-report files and hard-stops dispatch before any further LLM spend.

Three findings drive planning:

- **POSIX ACLs inside rootless Podman with `--userns keep-id` DO work for multiple in-container users**, but only if the in-container users are allocated UIDs from the host's subordinate UID range (the 524288–589823 block on this dev host). `setfacl -m u:<uid>:rwx` applied host-side is what the container kernel sees via shared VFS — the userns only remaps the root UID, not everyone. `[VERIFIED: host test, /tmp/acl_test setfacl + getfacl succeeded; subuid range present at /etc/subuid].`
- **Netavark (v1.17.2 present on dev host) has NO per-container egress allow-list.** This is [tracked upstream](https://github.com/containers/netavark/issues/875) and closed without implementation; the only built-in is `--internal` (all-or-nothing). The only viable `api-only` network policy is **in-container nftables/iptables rules set by the entrypoint**, OR a userspace proxy, OR DNS-resolving the LLM endpoint allow-list into IP ranges and injecting them as `--add-host`. This is the single biggest deviation from CONTEXT.md's D-10/D-11 as stated, and the planner needs to pick a concrete enforcement path.
- **`litellm.completion_cost(completion_response=resp)` returns USD as a float and maps Ollama to $0** because the model isn't in the cost DB — safe for D-25 ("Ollama reports `cost_usd: 0.0`"). `response.usage` is `{prompt_tokens, completion_tokens, total_tokens}` on every provider via the OpenAI-compat wrapper. `[CITED: docs.litellm.ai/docs/completion/output, docs.litellm.ai/docs/completion/token_usage]`

**Primary recommendation:** structure Phase 3 as 5 plans across 3 waves — Wave 0 scaffolds new Ecto schemas + ACL mapper pure module + crontab dep + usage-report schema (no runtime coupling); Wave 1 implements Router + Agent.Server + Scheduler + BudgetTracker; Wave 2 wires network-policy + kernel-ACL reconciliation + the three `W3/W4/W5` kernel-observed integration tests and extends the worker to emit usage reports + accept `skills_resolved:`.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

All 45 decisions D-01 through D-45 are locked (see `03-CONTEXT.md`). Key anchors planning must honour verbatim:

- **D-01/D-02/D-03:** Username scheme `glorbo-<co>-<ag>`; per-company 100-UID blocks starting at `100000 + 100*company_ordinal` recorded in `~/.glorbo/runtime/.companies-uid.json`; users exist inside the container only (tmpfs-backed `/etc/passwd` overlay), never on the host.
- **D-05/D-06/D-07/D-08:** ACLs reconciled on container start (idempotent `setfacl -b` + declarative re-apply); resource:action:scope → ACL via central table in `lib/glorbo/security/acl_mapper.ex`; default baseline `rwx` own outbox/workspace/state, `r` own inbox, deny everything else; channels are `r` for `chat:read:*` holders and `---` (denied write) for every agent — Elixir is sole writer.
- **D-09:** SC-4 is a KERNEL-observed denial test (not an Elixir-layer rejection): spawn container, exec as agent user, attempt write, assert `EACCES`.
- **D-10/D-11/D-12:** Network policy ladder `none` / `api-only` / `open` → podman `--network` modes; `api-only` enforced with netavark firewall + fallback to in-container iptables/nftables; allow-list is static base + per-company `network_allow:` override.
- **D-14/D-15/D-16/D-17/D-18:** Single per-company `Glorbo.Company.Router` GenServer; triggered by Filesystem.Watcher outbox events; permission check → copy to inbox or append to channel OR reject with `.rejected.md` suffix + rejection inbox message; channels use `[:append, :sync]`; `@name` detection writes synthetic `agents/<name>/inbox/mentions/<timestamp>-<channel>.md`.
- **D-19/D-20/D-21/D-22/D-23:** One `Glorbo.Company.Agent` GenServer per agent under per-company `DynamicSupervisor` (`max_restarts: 3, max_seconds: 60`); `wake/3` is a short call that spawns a Task.Supervisor child for execution; Scheduler uses `crontab` lib + `Process.send_after`; task-in-flight state serialised to `state/current-task.json`; ephemeral containers by default, persistent when `lifecycle: persistent`.
- **D-24/D-25/D-26/D-27/D-28/D-29:** Worker writes `outbox/usage/<task_id>.json` after result; litellm's `cost_per_token`/`completion_cost` canonical; BudgetTracker upserts `budgets` schema `{agent_slug, year_month, prompt_tokens, completion_tokens, cost_usd_cents}`; pre-dispatch hard-stop via `check_budget/1` returning `:ok | {:alert, ...} | {:stop, ...}`; alert threshold writes `alerts/<agent>-budget.md` + PubSub-ready broadcast; UTC month boundary, no mid-month top-ups.
- **D-30/D-31/D-32/D-33:** Approval sentinels via `state/awaiting-approval-<task_id>.md`; `status: approved` in task frontmatter triggers wake with `director-approval` trigger; `status: denied` moves to history with reason; Phase 4 consumes these markers.
- **D-34/D-35/D-36:** Skills injected by Elixir at dispatch time as `skills_resolved:` key in request body (full markdown, not path); missing skill → warn + drop + emit `skill.missing`; order preserved from `agent.md`.
- **D-37/D-38/D-39/D-40:** API keys in `~/.glorbo/config.md` (chmod 0600), injected per-request in `/run` body field (NEVER env vars); provider must be in the fixed whitelist; one provider+model per agent.
- **D-41/D-42/D-43:** AGT-05 enforced via the permission system (no agent has `agents:create`); Director writes agent.md directly; Router rejects outbox-origin agent creation + audits `permission.denied`.
- **D-44/D-45:** Per-company supervisor extends Phase 2's 2-child shape to **6 children**: `AuditLog, Filesystem.Watcher, Router, Scheduler, BudgetTracker, AgentSupervisor (DynamicSupervisor)`. All child state rebuildable from filesystem + SQLite.

### Claude's Discretion

- ACL mapping table structure (Map vs behaviour module) — **research recommends: plain module with pure functions returning `[{String.t, :rwx | :rx | :r | :---, Path.t}]`; keeps compile-time errors for typos and is trivially testable.**
- Router file-routing queue shape (direct `handle_info` vs work queue with job struct) — **research recommends: direct handle_info with state counter for auditability; switch to job struct only if concurrency demands emerge.**
- BudgetTracker internal state caching (in-memory cache + SQLite refresh vs SQLite-direct) — **research recommends: in-memory ETS cache keyed `{agent_slug, year_month}`, refreshed on crash recovery from SQLite; the hard-stop path must hit ETS (microsecond latency) because every dispatch calls it.**
- Scheduler cron library (`crontab` recommended) — **research confirms: `{:crontab, "~> 1.2"}` is the right choice. Quantum is 10× bigger and stores jobs in a separate supervisor tree — overkill for 1 expression per agent, ≤dozens of agents per company.**
- Per-agent `Task.Supervisor` as its own Company child, or child of each Agent GenServer — **research recommends: per-Agent (one `Task.Supervisor` started inline inside `Agent.Server.init/1`), so Agent crash takes the Task with it per D-19's crash-isolation goal.**
- Audit event key names for new Phase 3 events — **research proposes a stable set in "Audit event naming" below.**
- `budgets` table uses cents or fractional USD — **research: STRONGLY cents (integer math, avoids float drift in SUM aggregations, matches `cost_usd_cents` already named in D-26).**
- Skill files schema validation at Director-commit vs dispatch — **research: dispatch-time only in v1; add a Doctor check later for pre-flight warning.**
- Inbox cleanup policy (TTL / archive-to-history-on-read / never) — **research recommends: archive-to-history on successful read by agent; 30-day TTL on `history/` is out of scope.**

### Deferred Ideas (OUT OF SCOPE)

- Agent-spawn-agent (permanently v2).
- Mid-run budget rebalancing / top-ups.
- Fine-grained time-based permissions (weekdays-only etc).
- Per-message quotas separate from USD.
- Remote skills marketplace / cross-company skills.
- Router-level rate limiting (max N msgs/min) — relying on OTP `max_restarts`.
- Host-side `~/.glorbo/` ACL enforcement (multi-user trust model is out).
- `agents:create` permission (template marketplace).
- Websocket-level stdout streaming (file-tail remains).
- Per-company HTTP proxy for corporate egress.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| **AGT-01** | Per-company OTP supervision tree — crashing agent restarts only that agent; crashing company restarts only that company; dashboard and other companies unaffected | 6-child per-company supervisor design (§Architecture Patterns 1); DynamicSupervisor `max_restarts: 3, max_seconds: 60`; per-agent `Task.Supervisor`; crash surface documented (D-45) — all state rebuildable from FS + SQLite. |
| **AGT-02** | Agent wake triggers: inbox inotify, cron heartbeat, channel `@agent` mention, Director request | Four wake-sources unify through `Agent.Server.wake(company, agent, trigger)`; Scheduler uses `crontab` lib + `Process.send_after` (§Architecture Patterns 3); Router `@name` scan writes mentions file that fires same inbox watcher (§Architecture Patterns 2). |
| **AGT-03** | Inbox/outbox one-way flow — Elixir writes inbox, agent writes outbox, Router mediates every transfer | Single choke-point Router; denial emits rejection message back to sender's inbox (audible); channel append via `[:append, :sync]`. Kernel ACLs (`rwx` outbox, `r` inbox) enforce invariant at kernel layer. |
| **AGT-04** | Skills injected into agent context at runtime | Elixir reads `~/.glorbo/skills/<name>.md`, passes full markdown as `skills_resolved:` key in `/run` body. Worker (Phase 2) must be extended to inject into system prompt. Additive API change (Phase 2 D-36 allows). |
| **AGT-05** | Agent creation Director-only in v1 | No agent has `agents:create` permission → Router rejects any outbox file addressed to `agents/<new>/agent.md`; `permission.denied` audit (D-41/D-43). |
| **SEC-01** | Application-layer permission enforcement in Elixir Router | Router calls `ACLMapper.check(permissions, resource_tuple, path)` before every route; denial emits `.rejected.md` + inbox notice + `permission.denied` audit (D-16). |
| **SEC-02** | Kernel-layer permission enforcement via POSIX ACLs inside the container | ACL reconciliation at container start: `setfacl -b` + declarative re-apply from `acl_mapper.ex`; baseline (own outbox `rwx`, own inbox `r`) + scope-specific opens. SC-4 test is a kernel-observed denial (D-09). |
| **SEC-03** | Per-agent network policy `none`/`api-only`/`open` | `none` → `--network none`; `open` → `--network slirp4netns`; `api-only` → **in-container nftables/iptables rules** (netavark has no per-container egress allow-list; see Common Pitfall 1). Allow-list derived from static base + `company.md:network_allow:`. |
| **SEC-04** | Director-approved approval gates for `requires_approval: director` tasks | Sentinel file `state/awaiting-approval-<task_id>.md`; Director flips `status: approved` in task frontmatter; Watcher triggers Router trigger that wakes agent with `director-approval`; denial symmetric. |
| **SEC-05** | Per-agent monthly budget in USD with alert + hard-stop | Worker writes `outbox/usage/<task_id>.json`; BudgetTracker upserts `budgets` schema via Ecto `on_conflict: {:replace_all_except, ...}` (SQLite supports since 3.24); hard-stop is PRE-dispatch (worst case one call grazes cap, next refuses). |
| **LLM-03** | Anthropic/OpenAI/Google via per-agent config | Keys read from `~/.glorbo/config.md` (chmod 0600), injected per-request in `/run` body (Phase 2 D-37); litellm dispatches `anthropic/claude-...`, `openai/gpt-...`, `gemini/...` from same `completion()` call. |
| **LLM-04** | One provider+model per agent | Enforced at `agent.md` parse time; `provider:` must be in `[ollama, huggingface, anthropic, openai, google]`; multiple models → validation error. |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **The kernel is the policy engine.** Phase 3 OPERATIONALISES this invariant — "application-only checks are a design bug." ACL reconciliation is not optional; SC-4 tests kernel-observed denial, not Elixir-layer rejection.
- **Filesystem is the source of truth.** All Phase 3 state (budgets, approval markers, rejection messages, usage reports, ACL source) must be reconstructable from disk. `budgets` table state rebuildable from `outbox/usage/*.json` + audit log (D-45 crash surface invariant).
- **One-way inbox/outbox flow.** Agents NEVER touch other agents' directories; Router mediates EVERY transfer. Enforced at BOTH layers (Router + ACL).
- **Audit log is append-only.** `audit/YYYY-MM.jsonl` — Phase 3 adds new `action:` keys, does not introduce mutation primitives. AuditLog module exposes only `append/2`.
- **Python never runs on the host.** Usage reports, ACL commands, network policy rules — all execute inside the container via the existing worker or an entrypoint shim. No new host Python.
- **Company isolation is absolute.** No cross-company Router path exists; each company has its own Router/Scheduler/BudgetTracker instance.
- **Crash isolation follows OTP supervision tree.** 6-child supervisor design preserves this; new `Agent.Server` siblings fail independently.

## Standard Stack

### Core (new dependencies)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `crontab` | `~> 1.2` (1.2.0 latest) | Parse `heartbeat:` cron expressions; compute next run date for `Process.send_after` | Pure-Elixir, no job store, MIT, actively maintained by @maennchen, used as the parser underneath Quantum. `[VERIFIED: mix hex.info crontab]` |

### Core (existing — already in mix.exs, reused)

| Library | Version | Purpose | Why Reused |
|---------|---------|---------|------------|
| `ecto_sqlite3` | `~> 0.22` | `budgets`, `tasks_approval_state` new schemas; `on_conflict` upsert for monthly rollup | Already the project's persistence layer; supports `on_conflict` via SQLite 3.24+ `ON CONFLICT DO UPDATE` — `inc:` atomic increment NOT guaranteed portable (see Pitfall 4). Use `{:replace_all_except, ...}` or a manual SELECT+UPDATE in a transaction. |
| `jason` | `~> 1.4` | Parse `outbox/usage/*.json` reports; encode audit events | Already used; no change. |
| `yaml_front_matter` | `~> 1.0` | Parse `agent.md` permissions + task `status:` + company `network_allow:` | Phase 2 dep; reused for new frontmatter fields. |
| `finch` | `~> 0.21` | Existing UDS worker client | Unchanged in Phase 3. |
| `file_system` | `~> 1.0` | Existing Filesystem.Watcher | Router subscribes via existing watcher (Phase 2 D-33 path-prefix). |

### Supporting (no new Python deps)

Phase 2 already pinned `litellm` in the `glorbo-runtime` image. Phase 3 adds **no** Python dependencies. Extensions to the worker are additive:

- New `/run` body field: `skills_resolved: [markdown_text, ...]` (injected into system prompt).
- New worker step: write `outbox/usage/<task_id>.json` AFTER writing result file, using `litellm.completion_cost(completion_response=resp)` + `resp.usage.model_dump()`.

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `crontab` lib | Quantum 3.5 | Quantum adds its own supervisor tree + job store — overkill for one expression per agent. `crontab` is just a parser + next-run calculator. `[VERIFIED: hex.pm]` |
| In-container nftables for api-only | Userspace HTTP proxy (e.g. tinyproxy on a UDS) | Proxy is OSI-layer-7 so it can allow by *hostname* — more robust to LLM-endpoint IP rotation than static CIDR. Downside: another moving part and an extra port inside the container. **Research recommends starting with nftables + short-TTL DNS pre-resolution; escalate to proxy only if IP drift becomes a problem.** |
| Per-company UID range in host /etc/subuid | In-container `/etc/passwd` fragment + `--userns keep-id` (CONTEXT.md D-03) | Locked by D-03. Research-confirmed: keep-id adds the host user to in-container `/etc/passwd` but **does NOT add additional users** — Phase 3 must overlay-mount the tmpfs passwd fragment AFTER container start OR use a `useradd` wrapper in the entrypoint. See Architecture Pattern 4. |

**Installation (mix.exs delta):**

```elixir
# Add to deps():
{:crontab, "~> 1.2"}
```

**Version verification:**

```bash
mix hex.info crontab    # → 1.2.0 latest, MIT, maennchen/crontab
```

`[VERIFIED: mix hex.info crontab 2026-04-16 — 1.2.0 latest]`

Ecto 3.13.5 and ecto_sqlite3 0.22.x are already locked in mix.lock from Phase 1/2 — no bump needed.

## Architecture Patterns

### Recommended Project Structure

```
lib/glorbo/
├── company/
│   ├── supervisor.ex          # Extended to 6 children (D-44)
│   ├── router.ex              # NEW: full implementation (was stub)
│   ├── scheduler.ex           # NEW: full impl (crontab-based)
│   ├── budget_tracker.ex      # NEW: full impl with ETS + Ecto upsert
│   ├── agent_supervisor.ex    # NEW: DynamicSupervisor
│   └── audit_log.ex           # Existing, unchanged
├── agent/
│   ├── server.ex              # NEW: fill in Phase-1 stub
│   └── dispatch.ex            # NEW: pre-dispatch pipeline (skills resolve, budget check, ACL hash)
├── security/
│   ├── acl_mapper.ex          # NEW: permission → ACL command list (pure)
│   ├── acl_reconciler.ex      # NEW: IO side — runs setfacl inside container
│   ├── network_policy.ex      # NEW: resolve policy → podman flags + nftables rules
│   └── user_provisioner.ex    # NEW: UID allocation + in-container /etc/passwd fragment
├── budget/
│   └── ledger.ex              # NEW: Ecto upsert helpers + monthly rollover
├── approvals/
│   └── gate.ex                # NEW: sentinel read/write + status-flip detection
├── skills/
│   └── resolver.ex            # NEW: read ~/.glorbo/skills/<n>.md, compose into list
├── llm/
│   └── provider.ex            # NEW: validate provider + resolve api_key from config.md
└── runtime/
    └── uid_allocator.ex       # NEW: read/write .companies-uid.json sidecar

priv/repo/migrations/
├── 20260416120001_create_budgets.exs
├── 20260416120002_create_tasks_approval_state.exs
└── 20260416120003_add_permissions_hash_to_agents.exs
```

### Pattern 1: Six-child per-company supervisor (AGT-01, D-44)

**What:** Extend `Glorbo.Company.Supervisor` to supervise `AuditLog, Filesystem.Watcher, Router, Scheduler, BudgetTracker, AgentSupervisor` with `strategy: :one_for_one` so any single child's crash doesn't cascade. `AgentSupervisor` is a `DynamicSupervisor` spawning per-agent `Agent.Server` children.

**When to use:** Every `Glorbo.Company.<slug>.Supervisor` instance. One per company.

**Example:**

```elixir
# Source: extension of lib/glorbo/company/supervisor.ex (Phase 2 shape)
@impl Supervisor
def init(opts) do
  company = Keyword.fetch!(opts, :company)
  base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))

  children = [
    {Glorbo.Company.AuditLog,       [name: child_name(company, :audit_log), company: company, base: base]},
    {Glorbo.Filesystem.Watcher,     [name: child_name(company, :file_watcher), company: company, base: base]},
    # Phase 3 additions:
    {Glorbo.Company.BudgetTracker,  [name: child_name(company, :budget), company: company, base: base]},
    {Glorbo.Company.Router,         [name: child_name(company, :router), company: company, base: base]},
    {Glorbo.Company.Scheduler,      [name: child_name(company, :scheduler), company: company, base: base]},
    {DynamicSupervisor, strategy: :one_for_one, max_restarts: 3, max_seconds: 60,
     name: child_name(company, :agent_sup)}
  ]

  Supervisor.init(children, strategy: :one_for_one)
end
```

**Ordering note:** BudgetTracker MUST start before Router (Router calls BudgetTracker on every route for cost attribution) and before AgentSupervisor (agents call BudgetTracker pre-dispatch). `:one_for_one` doesn't enforce startup order beyond list order, so list order matters.

### Pattern 2: Router as single choke-point (AGT-03, SEC-01, D-14..D-18)

**What:** Every outbox file the Filesystem.Watcher detects routes to `Router.route_outbox/2`. Router reads frontmatter `to:`, applies `ACLMapper.check_action/3` against sender's permissions, and either copies to recipient inbox (or appends to channel file with `[:append, :sync]`) or rejects with `.rejected.md` suffix + audible inbox notice.

**When to use:** Every outbox→inbox, outbox→channel, and `@mention`-derived channel→inbox transfer. Literally every agent-originated IO that crosses the agent's own subdirectory boundary.

**Example:**

```elixir
# Source: new lib/glorbo/company/router.ex
def handle_info({:outbox_event, path}, state) do
  with {:ok, msg} <- Glorbo.Filesystem.Frontmatter.parse_file(path),
       {:ok, sender_agent} <- Glorbo.Company.Agents.load(state.company, msg.from),
       {:ok, action} <- classify_action(msg),
       :ok <- Glorbo.Security.ACLMapper.check_action(sender_agent.permissions, action) do
    route(state, msg, path)
    Glorbo.Company.AuditLog.append(state.company, %{
      action: "message.route", from: msg.from, to: msg.to, msg_id: msg.id, actor: msg.from
    })
  else
    {:error, {:permission_denied, missing}} ->
      reject(state, path, missing)
      Glorbo.Company.AuditLog.append(state.company, %{
        action: "message.reject", actor: msg.from || "unknown",
        reason: "missing_permission", missing: missing, path: path
      })
  end
  {:noreply, state}
end
```

**Anti-pattern:** DO NOT have the Agent.Server write directly to another agent's inbox. Every transfer goes through Router (CLAUDE.md one-way-flow invariant) — even if both agents are in the same company, in the same OS process, the file-mediated round-trip is load-bearing for the audit log.

### Pattern 3: Scheduler with crontab + Process.send_after (AGT-02, D-21)

**What:** `Glorbo.Company.Scheduler` reads each agent's `heartbeat:` cron expression at start, parses with `Crontab.CronExpression.Parser.parse!/1`, computes next run with `Crontab.Scheduler.get_next_run_date/2`, and schedules a `Process.send_after(self(), {:heartbeat, agent_slug}, ms_until_next)`. On timer fire, calls `Agent.Server.wake(..., :heartbeat)` and reschedules.

**When to use:** Every agent with a `heartbeat:` field in agent.md.

**Example:**

```elixir
# Source: new lib/glorbo/company/scheduler.ex (adapted from crontab README)
defp schedule_next(state, agent_slug, cron_expr) do
  {:ok, cron} = Crontab.CronExpression.Parser.parse(cron_expr)
  {:ok, next_run} = Crontab.Scheduler.get_next_run_date(cron)

  ms_until_next =
    next_run
    |> NaiveDateTime.diff(NaiveDateTime.utc_now(), :millisecond)
    |> max(1_000)   # floor at 1s to avoid tight-loop if clock skews

  ref = Process.send_after(self(), {:heartbeat, agent_slug}, ms_until_next)
  put_in(state.timers[agent_slug], ref)
end

def handle_info({:heartbeat, agent_slug}, state) do
  Glorbo.Agent.Server.wake(via(state.company, agent_slug), :heartbeat)
  state = schedule_next(state, agent_slug, state.crons[agent_slug])
  {:noreply, state}
end
```

`Process.send_after/3` uses the BEAM's monotonic clock — safe against wall-clock jumps (NTP steps) but DOES pause when the VM is fully stalled. For Phase 3's agent-wake use case (minute-scale heartbeats), this is acceptable.

`[CITED: hexdocs.pm/crontab/Crontab.Scheduler.html, hexdocs.pm/crontab/Crontab.CronExpression.Parser.html]`

### Pattern 4: Per-company in-container /etc/passwd overlay (D-03)

**What:** At `ContainerManager.start_container/2` time, write a tmpfs-backed fragment of `/etc/passwd` + `/etc/group` containing the agent users for that company, then bind-mount it read-only over the container's `/etc/passwd`. Users are at UIDs in the per-company 100-block (D-02). The container entrypoint uses those users (via `runuser` / `su` / `exec --user`) to run worker logic; `setfacl` refers to these UIDs.

**When to use:** Every company container start. Idempotent — regenerated from `.companies-uid.json` + `agents/*/agent.md` at each start.

**Example:**

```bash
# Host-side preparation (Elixir runs before podman run)
mkdir -p ~/.glorbo/runtime/passwd/acme
cat > ~/.glorbo/runtime/passwd/acme/passwd <<EOF
root:x:0:0:root:/root:/bin/bash
glorbo-acme-ceo:x:100000:100000:CEO:/company/agents/ceo:/bin/sh
glorbo-acme-engineer:x:100001:100001:Engineer:/company/agents/engineer:/bin/sh
EOF

# podman run additions
podman run \
  --userns keep-id \
  --volume ~/.glorbo/runtime/passwd/acme/passwd:/etc/passwd:Z,ro \
  --volume ~/.glorbo/runtime/passwd/acme/group:/etc/group:Z,ro \
  ...
```

**Subordinate-UID requirement:** The 100-UID blocks (D-02) assume UIDs ≥100000 are within the host user's subordinate range. Confirmed on this dev host: `/etc/subuid` has `foobarto:524288:65536` → range 524288–589823. **The D-02 formula `100000 + 100*company_ordinal` starts BELOW the host's subordinate range — this is the primary open issue in the decision set.** Either: (a) change D-02 to start at `HOST_SUBUID_BASE + 100*ord` and read from `/etc/subuid` in the uid allocator, OR (b) document the assumption that a specific `/etc/subuid` entry exists and have Doctor check it. Research recommends (a): read `/etc/subuid` at allocation time.

`[CITED: docs.podman.io/en/latest/markdown/podman-run.1.html#userns, redhat.com/en/blog/rootless-podman-user-namespace-modes]`

### Pattern 5: Pre-dispatch budget hard-stop (SEC-05, D-27)

**What:** Before `ContainerManager.start_container/2`, `Agent.Server` calls `BudgetTracker.check_budget(company, agent)`. BudgetTracker reads ETS cache for `{agent_slug, current_year_month}`, returns `:ok | {:alert, used_cents, cap_cents} | {:stop, used_cents, cap_cents}`. On `:stop`, abort the wake, emit `budget.hard_stop` audit, append a rejection message to the agent's own inbox explaining which cap was hit. On `:alert`, proceed AND write `alerts/<agent>-budget.md` if not already present.

**When to use:** Every dispatch path. Router-triggered dispatch, scheduler-triggered dispatch, approval-triggered dispatch — all share the same entry into `Dispatch.run/2`.

**Example:**

```elixir
# Source: new lib/glorbo/agent/dispatch.ex
def run(company, agent, trigger) do
  with {:ok, _} <- Glorbo.Company.BudgetTracker.check_budget(via(company, :budget), agent),
       {:ok, task} <- pick_next_task(company, agent),
       {:ok, skills} <- Glorbo.Skills.Resolver.resolve(task.agent.skills),
       {:ok, api_key} <- Glorbo.LLM.Provider.resolve_key(task.agent.provider),
       :ok <- write_current_task_state(company, agent, task),
       {:ok, result} <- Glorbo.Container.WorkerClient.post_run(company, agent, %{
         task_path: task.path, provider: task.agent.provider, model: task.agent.model,
         api_key: api_key, skills_resolved: skills
       }) do
    {:ok, result}
  else
    {:error, {:budget_stop, used, cap}} ->
      emit_budget_stop_audit(company, agent, used, cap)
      append_rejection_to_own_inbox(company, agent, :budget_exceeded, used, cap)
      {:error, :budget_stop}
    err -> err
  end
end
```

### Anti-Patterns to Avoid

- **Calling `setfacl` from the host on user-data directories.** D-07 says default baseline is fail-closed DENY on everything except own dirs. If `setfacl -m u:<uid>:---` is applied host-side, the *Director* (who owns `~/.glorbo/`) loses write access to those dirs too (ACL mask trumps owner's permission class in edge cases). **Always run `setfacl` from INSIDE the container.** The kernel sees the same VFS either way, but running from inside preserves the "host is user data, untouched by Glorbo" invariant.
- **Checking permissions in Agent.Server before Router.** Router is the choke-point. Agent.Server sees only tasks/messages already in its inbox, which Router already validated. Double-checking adds a second source of truth that will drift. Keep `Agent.Server` permission-naïve.
- **Running `setfacl -R` on `/company/` at every ACL change.** The tree can have tens of thousands of files. Recursive setfacl is O(n). Reconcile ONLY on container start (D-05) and only for directories explicitly listed in the ACL mapping table (project dirs, agent dirs). Files inherit via default ACLs on the parent.
- **Polling for approval.** D-30/D-31 says the Watcher detects the `status:` frontmatter flip via inotify; the Router wakes the agent. NO polling loop anywhere.
- **Putting the api_key anywhere except the /run body.** `--env GLORBO_ANTHROPIC_KEY=...` would show up in `podman inspect` and `ps`. Phase 2 D-37 is load-bearing and Phase 3 must preserve it: api_key in request body only, in-memory request-scope only, never written to company dir.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Cron expression parsing | A regex for `*/30 * * * *` | `crontab` hex lib (`Crontab.CronExpression.Parser.parse!/1`) | Cron has 5–7 fields, step values, ranges, names (JAN–DEC, MON–SUN), `@hourly`/`@daily` aliases. Hand-rolled parsers get this wrong. |
| LLM cost attribution | A `case provider do "claude-..." -> 0.000015 * tokens end` cost table | `litellm.completion_cost(completion_response=resp)` in Python worker | litellm maintains `model_prices_and_context_window.json` across 100+ models; prices change monthly. Static table drifts in weeks. |
| LLM error classification | `case http_status do 429 -> ... end` per-provider | `except litellm.exceptions.RateLimitError` in Python, `{:error, {:rate_limit, _}}` → Elixir | litellm unifies Anthropic 529s, OpenAI 429s, Google quota errors, Ollama ECONNREFUSED into a single taxonomy (`[CITED: docs.litellm.ai/docs/exception_mapping]`). |
| In-container UID-to-username resolution | `chmod`/`chown` with numeric UIDs | `setfacl -m u:<username>:rwx` with passwd overlay | POSIX ACL tools accept either UID or username; using names makes `getfacl` output self-documenting for debugging. |
| YAML frontmatter parsing | Regex on `^---$` | `YamlFrontMatter.parse_file/1` (already in deps) | Multi-line values, escaping, `---` inside strings. YAML parser exists; use it. |
| Unix socket HTTP client | A raw `:gen_tcp` + HTTP framing | `Finch` with `unix_socket:` option (already in WorkerClient) | Phase 2 already solved this. Don't re-solve. |
| Task re-entry / idempotency of wake | Manual mutex around agent state | OTP GenServer serialisation + `current-task.json` durable state | GenServer's message queue IS the mutex. `current-task.json` is the crash-recovery durability layer. |
| Permission mini-language | Regex matching `projects:write:foo` | Pattern-match on `{"projects", "write", scope}` tuple from `String.split(":", 3)` | Keep it flat. No nesting, no wildcards beyond `*`, no regex. |

**Key insight:** The PRIMARY Phase 3 risk is reinventing the three layers that already exist — crontab parsing (use lib), LLM unification (use litellm), and permission-check-before-transfer (use Router at single choke-point). Custom versions of any of these are 2-week tangent debt.

## Runtime State Inventory

**Not applicable — Phase 3 is a greenfield implementation of stub modules, not a rename/refactor/migration. Phase 1 stubs return `:not_implemented`; Phase 3 replaces their bodies. No renaming of public function names (e.g. `Glorbo.Company.Router.route/2` stays, changes behaviour).**

However, a short inventory of what Phase 3 adds to runtime state for planners to trace in later phases:

| Category | New state | Where |
|----------|-----------|------|
| Stored data | `budgets` rows (one per agent per year_month); `tasks_approval_state` rows | SQLite `glorbo.db` — rebuildable from `audit/*.jsonl` + `outbox/usage/*.json` per D-45. |
| Live service config | Per-company Podman container, now running FastAPI worker for N agents (was 0 in Phase 2) | `podman ps` — ephemeral per-task OR persistent per-agent. |
| OS-registered state | **None.** D-03 locks users INSIDE container only; no host-side useradd. | N/A. |
| Secrets/env vars | `~/.glorbo/config.md` frontmatter holds provider API keys (one file, chmod 0600) — NEW file created by Director | Host filesystem only. Never in git (`.gitignore` for `~/.glorbo/` is implicit — it's not the project repo). |
| Build artifacts | None new — `glorbo-runtime` image from Phase 2 unchanged | Container registry / local Podman image cache. |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `setfacl` / `getfacl` | SEC-02 ACL reconciliation | ✓ | 2.3.2 | — (kernel feature; ext4/btrfs/xfs all support) |
| `podman` | RT-03 container runtime | ✓ | 5.8.1 | Phase 2 handled bootstrapping |
| `netavark` | SEC-03 `api-only` policy (partial) | ✓ | 1.17.2 | Falls back to in-container nftables |
| `slirp4netns` | `api-only` + `open` policies | ✓ | 1.3.1 | — |
| `nftables` | `api-only` in-container egress rules | ✓ (host-side; must also be in container image) | 1.1.3 | `iptables-nft` (1.8.11) fallback |
| `/etc/subuid` entry | Per-company UID blocks (D-02) | ✓ | `foobarto:524288:65536` | Doctor check required; init should guide Director to set it. |
| `crontab` hex lib | Scheduler | ✗ (not yet in mix.lock) | 1.2.0 avail | — just add it |
| Ollama daemon | Phase 2 airplane-mode test; Phase 3 uses via litellm | Director-managed | — | — |
| Python `litellm` + `openai`/`anthropic`/`google-genai` | Cloud dispatch + usage reporting | ✓ (in glorbo-runtime image per Phase 2 D-12) | pinned | — |

**Missing dependencies with no fallback:** None blocking.

**Missing dependencies with fallback:** None critical.

**Doctor additions required (Phase 3):**

- Check `setfacl` / `getfacl` binaries inside the `glorbo-runtime` image (add `acl` package to Containerfile).
- Check `nftables` OR `iptables-nft` inside the image (probably need to add; Ubuntu 24.04 base ships `iptables` but nftables package needs verification).
- Check `/etc/subuid` has an entry whose range covers `100000 + 100*N` for N companies present (or change D-02 to use real subuid base).

## Common Pitfalls

### Pitfall 1: Netavark has no per-container egress allowlist (SEC-03 planning blocker)

**What goes wrong:** CONTEXT.md D-10 says `api-only` → "netavark firewall allow-list restricting destination IPs/CIDRs to the known LLM provider endpoints." **This feature does not exist in netavark 1.17.2.** Upstream issue [containers/netavark#875](https://github.com/containers/netavark/issues/875) is closed without implementation. The only built-in is `--internal` (drops ALL outbound) which matches `none`, not `api-only`.

**Why it happens:** Assuming network backends in 2026 support the granular egress rules that firewalld/nftables supports on bare metal. They don't for rootless slirp4netns/pasta paths.

**How to avoid:** Three viable alternatives, ranked:

1. **In-container nftables rules applied by entrypoint.** Add `nftables` package to `glorbo-runtime` image; entrypoint script runs `nft add rule inet filter output ip daddr != { 1.2.3.4, ... } drop` for `api-only` agents. Requires `--cap-add=NET_ADMIN` OR `--sysctl net.ipv4.conf.all.forwarding=1` — **which conflicts with the no-`--cap-add` invariant in invocation.ex**. Solution: cap-add only on `api-only` containers (negotiated exception), guard in `Invocation.build_argv/4`.
2. **Userspace HTTP proxy inside container (e.g., tinyproxy on a local UDS).** litellm's `api_base` parameter makes every provider call go through the proxy. Proxy enforces allow-list by hostname (robust to IP rotation). Downside: extra moving part, init-race between proxy and worker.
3. **Pre-resolve LLM endpoint DNS to CIDR at container-start time + inject via `--add-host` + `nft` on the bridge.** Fragile to IP rotation.

**Research recommends option 2 (userspace proxy)** for `api-only` because LLM providers rotate IPs behind CDNs (Anthropic/OpenAI/Google all do) — hostname-based enforcement is the only sustainable choice. The v1.0 plan can ship option 1 (nftables + pre-resolved CIDR) and defer option 2 to v1.1 if flakes emerge.

**Warning signs:** `api-only` test passes on day 1, fails on day 30 when Anthropic rotates its ingress IPs; container cap-add leak into `none` containers (invocation test must have a NEGATIVE assertion that `--cap-add` does NOT appear for `none` or `open`).

`[VERIFIED: host inspection — netavark 1.17.2 CLI has no outbound firewall subcommand; issue #875 confirmed closed without implementation]`

### Pitfall 2: `--userns keep-id` doesn't create the in-container agent users by itself

**What goes wrong:** D-03 says "users exist inside the container only… declarative `/etc/passwd` fragment into a tmpfs-backed overlay at container start." Without this, `--userns keep-id` only adds THE HOST USER (the Director) to `/etc/passwd` inside. Attempts to `su glorbo-acme-engineer` or reference UID 100001 inside the container fail with "user not found" or "permission denied" even though the UID is mapped.

**Why it happens:** `keep-id` is about mapping, not user-creation. The image's `/etc/passwd` is baseline; Podman adds one line for the current user. Phase 3's 3-agent-per-company case needs 4 users in that file (root + 3 agents).

**How to avoid:** Always bind-mount a per-company passwd fragment as per Architecture Pattern 4. Generate it in `Glorbo.Runtime.UserProvisioner` before `podman run`. Include the fragment path in `Invocation.build_argv/4` via the `extra_volumes:` mechanism Phase 2 added. Integration test must `podman exec` as a non-Director agent UID and assert the shell works.

**Warning signs:** `podman exec --user glorbo-acme-engineer ... id` fails with "unknown user"; ACL `getfacl` output shows numeric UIDs instead of names.

`[CITED: redhat.com/en/blog/rootless-podman-user-namespace-modes]`

### Pitfall 3: `setfacl` inside rootless container may need `mount_acl`

**What goes wrong:** `setfacl` requires the target filesystem to be mounted with `acl` option. ext4 has it by default; tmpfs and overlayfs support it; certain bind mounts over fuse-overlayfs (rootless Podman's default storage driver) may not propagate the option. The container's `/company` mount inherits from the host's filesystem — if the host is ext4/btrfs this works; if it's an older XFS volume without `noattr2`, could fail.

**Why it happens:** Assuming ACL support is universal. It is on modern defaults, but the container storage driver layer is one more abstraction.

**How to avoid:** Doctor check: `setfacl -m u:root:rwx /company/.acl-probe && getfacl /company/.acl-probe | grep -q 'user:root:rwx'` runs at container start, fails fast with a clear error. Also add an `acl` package check in the runtime image Containerfile. On this dev host, ACLs on `/tmp` work fine (verified).

**Warning signs:** `setfacl: Operation not supported` in container logs.

`[VERIFIED: host test on Fedora 43 kernel 6.17.7 confirmed setfacl works on /tmp]`

### Pitfall 4: ecto_sqlite3 `on_conflict: [inc: [counter: 1]]` behaviour is not portable

**What goes wrong:** Postgres supports `INSERT ... ON CONFLICT DO UPDATE SET counter = budgets.counter + 1`. SQLite 3.24+ supports the same syntax; ecto_sqlite3 passes `on_conflict: [inc: [x: 1]]` through, BUT because SQLite distinguishes "ON CONFLICT REPLACE" (delete+insert) from "ON CONFLICT DO UPDATE", the adapter's behaviour with `inc:` across versions is NOT documented. Empirical reports on elixirforum show `inc:` works in recent ecto_sqlite3 but there's no test-suite coverage at the adapter level.

**Why it happens:** SQLite's OR-REPLACE semantics and Ecto's abstraction of upsert can disagree; the `UNIQUE` constraint target must be explicitly named for `DO UPDATE` to fire.

**How to avoid:** Use the safer pattern — explicit `conflict_target: [:agent_slug, :year_month]` + `on_conflict: {:replace_all_except, [:id, :agent_slug, :year_month, :inserted_at]}`. For atomic increment, use a query-based on_conflict:

```elixir
# Source: extrapolation of ecto on_conflict docs + ecto_sqlite3 README pattern
query =
  from b in Glorbo.Budget,
    update: [
      inc: [prompt_tokens: ^usage.prompt_tokens,
            completion_tokens: ^usage.completion_tokens,
            cost_usd_cents: ^usage.cost_usd_cents]
    ]

Glorbo.Repo.insert!(
  %Glorbo.Budget{
    agent_slug: agent,
    year_month: ym,
    prompt_tokens: usage.prompt_tokens,
    completion_tokens: usage.completion_tokens,
    cost_usd_cents: usage.cost_usd_cents
  },
  on_conflict: query,
  conflict_target: [:agent_slug, :year_month]
)
```

Integration-test this on the Phase 3 `budgets_test.exs` against a real ecto_sqlite3 repo. Add a concurrent-writer test (spawn 10 Tasks inserting to the same row, assert final sum is exact) — this is the real risk. SQLite's single-writer serialisation means no row-level conflicts, but transaction backoff matters.

**Warning signs:** Final budget sum drifts from hand-calculated total by fractions of cents; concurrent updates silently clobber each other; tests flake on CI.

`[VERIFIED: mix hex.info ecto_sqlite3 — 0.22.x current; CITED: hexdocs.pm/ecto/Ecto.Repo.html#c:insert/2, elixirforum.com threads confirm `inc:` works with ecto_sqlite3 in recent versions]`

### Pitfall 5: Approval-flip race — Director approves while agent is already executing

**What goes wrong:** D-30 says agent writes sentinel `awaiting-approval-<task_id>.md` and returns to idle. D-31 says Director flips `status: approved`, Watcher fires, Router wakes the agent with `director-approval`. **Race:** what if the agent is ALREADY running (dispatched via heartbeat, working on a different non-approval task) when approval arrives? The `Agent.wake/3` implementation must dedupe: if already running, queue the approval trigger, don't double-dispatch.

**Why it happens:** Concurrent file-events and scheduler-events are independent. Assuming serialisation at the agent level isn't automatic.

**How to avoid:** Agent.Server state machine: `%{current_task: nil | task_id, pending_wakes: []}`. `wake/3` enqueues if `current_task != nil`, dispatches otherwise. On `{:task_complete, task_id}`, check pending queue and dispatch next. GenServer mailbox serialises message processing for free.

**Warning signs:** Double-dispatch (container started twice for same approval); budget double-decrement; duplicate audit events for the same approval.

### Pitfall 6: `audit/YYYY-MM.jsonl` multi-writer under concurrent Router activity

**What goes wrong:** Phase 2's AuditLog opens with `[:append, :sync]` — safe for single-process-single-file writes. Phase 3 introduces 4 new writers: Router (message.route + message.reject), BudgetTracker (budget.usage + budget.hard_stop + budget.alert), Agent.Server (approval.requested + wake.trigger), Dispatch (provider.unknown + skill.missing). All hit the same AuditLog GenServer, which DOES serialise — no issue IF every writer goes through `Glorbo.Company.AuditLog.append/2` and not direct `File.write!`.

**Why it happens:** A well-meaning contributor adds `File.write!(audit_path, line, [:append])` for performance, bypassing the GenServer. Two processes then race with partial line writes.

**How to avoid:** AuditLog is the SOLE writer. Enforce via code review and a negative test (`test/glorbo/stubs_test.exs` already has the "no AuditLog.update/AuditLog.delete" assertion — extend to "AuditLog is only module with `File.write!` targeting `audit/`"). Document in module docstring.

### Pitfall 7: Scheduler cron drift when BEAM VM pauses

**What goes wrong:** `Process.send_after(self(), _, ms)` uses BEAM monotonic time. If the VM is suspended (machine sleep, ERTS blocked on a huge GC, container paused), the timer fires when BEAM resumes — potentially hours late, all at once. Multiple agents' heartbeats collide.

**Why it happens:** Laptops sleep. Servers get OOM-killer'd and restarted. It happens.

**How to avoid:** After firing a heartbeat, ALWAYS recompute next run from current wall-clock via `Crontab.Scheduler.get_next_run_date(cron, NaiveDateTime.utc_now())` — don't increment by a fixed delta. This self-heals: a 3-hour pause still fires ONE heartbeat on wake, then schedules the next one correctly. Do NOT fire "missed" heartbeats.

**Warning signs:** 5-minute agent heartbeat fires 12 times in a row after laptop wake.

## Code Examples

### crontab: parse expression + compute next run

```elixir
# Source: https://hexdocs.pm/crontab/Crontab.Scheduler.html
iex> {:ok, cron} = Crontab.CronExpression.Parser.parse("*/30 * * * *")
iex> {:ok, next} = Crontab.Scheduler.get_next_run_date(cron, ~N[2026-04-16 10:00:00])
{:ok, ~N[2026-04-16 10:30:00]}
```

### litellm: completion + cost + usage (Python worker side)

```python
# Source: https://docs.litellm.ai/docs/completion/token_usage
# Lives in the existing worker/main.py (Phase 2), additive extension
from litellm import completion, completion_cost

resp = completion(
    model=f"{agent.provider}/{agent.model}",   # e.g. "anthropic/claude-3-5-sonnet-20241022"
    messages=[{"role": "system", "content": system_prompt_with_skills},
              {"role": "user", "content": task_content}],
    api_key=api_key,             # from /run body, NOT env var (D-37)
    api_base=api_base_override,  # for Ollama UDS: "http://localhost:11434"
)

usage = {
    "task_id":          task_id,
    "timestamp":        datetime.utcnow().isoformat() + "Z",
    "provider":         agent.provider,
    "model":            agent.model,
    "prompt_tokens":    resp.usage.prompt_tokens,
    "completion_tokens": resp.usage.completion_tokens,
    "total_tokens":     resp.usage.total_tokens,
    "cost_usd":         completion_cost(completion_response=resp) or 0.0,
}
# Ollama models return cost 0.0 because they're not in the litellm cost DB — this is correct.
# D-25 says "Ollama reports cost_usd: 0.0" — matches research.

# D-24: write AFTER the result file.
Path(f"/company/agents/{agent.slug}/outbox/usage/{task_id}.json").write_text(json.dumps(usage))
```

### Ecto upsert with atomic increment via query

```elixir
# Source: complete-guide-to-upserts-with-ecto (Peter Ullrich)
# + ecto docs + safer-for-SQLite pattern
@spec record_usage(BudgetTracker.t(), %{...}) :: :ok
def record_usage(state, usage) do
  ym = Date.utc_today() |> Date.to_string() |> String.slice(0..6)  # "2026-04"

  query =
    from b in Glorbo.Budget,
      update: [
        inc: [
          prompt_tokens: ^usage.prompt_tokens,
          completion_tokens: ^usage.completion_tokens,
          cost_usd_cents: ^usage.cost_usd_cents
        ]
      ]

  Glorbo.Repo.insert!(
    %Glorbo.Budget{
      agent_slug: usage.agent_slug,
      year_month: ym,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd_cents: usage.cost_usd_cents
    },
    on_conflict: query,
    conflict_target: [:agent_slug, :year_month]
  )
  :ok
end
```

### setfacl inside container (reconciliation)

```bash
# Source: DESIGN.md §7.2 + setfacl(1) man page
# Runs INSIDE the glorbo-runtime container, invoked by entrypoint after passwd overlay

# Fail-closed baseline
setfacl -b -R /company                               # clear all existing ACLs
find /company -type d -exec setfacl -m u:glorbo-acme-engineer:--- {} \;

# Grant baseline self-access
setfacl -R -m u:glorbo-acme-engineer:rwx /company/agents/engineer/outbox/
setfacl -R -m u:glorbo-acme-engineer:rwx /company/agents/engineer/workspace/
setfacl -R -m u:glorbo-acme-engineer:rwx /company/agents/engineer/state/
setfacl -R -m u:glorbo-acme-engineer:r   /company/agents/engineer/inbox/

# Apply declared permissions (projects:read:*, projects:write:website-redesign)
find /company/projects -maxdepth 1 -type d -exec setfacl -m u:glorbo-acme-engineer:rx {} \;
setfacl -R -m u:glorbo-acme-engineer:rwx /company/projects/website-redesign/

# Channel ACLs (chat:read:* — agent can read; NEVER write)
find /company/channels -type f -exec setfacl -m u:glorbo-acme-engineer:r {} \;
# No write ACL written — Elixir is sole writer per D-08.
```

### Network policy argv construction

```elixir
# Source: new lib/glorbo/security/network_policy.ex
@spec podman_flags(String.t()) :: [String.t()]
def podman_flags("none"),     do: ["--network", "none"]
def podman_flags("open"),     do: ["--network", "slirp4netns"]
def podman_flags("api-only") do
  # Pitfall 1: no native netavark egress allowlist; rely on in-container nftables.
  # slirp4netns with default options; entrypoint inside container applies nftables rules.
  # The CAP_NET_ADMIN grant is NARROWLY scoped to api-only containers only.
  ["--network", "slirp4netns:allow_host_loopback=false",
   "--cap-add", "NET_ADMIN"]
end
```

## Audit event naming (Phase 3)

Stable event keys for `audit/YYYY-MM.jsonl`, additive to Phase 2's set:

| `action` | Actor | Fired by | Payload keys |
|----------|-------|----------|--------------|
| `message.route` | sender agent | Router | `from, to, msg_id, path` |
| `message.reject` | sender agent | Router | `from, to, msg_id, reason, missing_permission` |
| `permission.denied` | sender agent | Router | `from, target, requested_action, missing_permission` |
| `skill.missing` | system | Dispatch | `agent, skill_name` |
| `provider.unknown` | system | Dispatch | `agent, provider` |
| `budget.usage` | agent | BudgetTracker | `agent, task_id, prompt_tokens, completion_tokens, cost_usd_cents, model` |
| `budget.alert` | system | BudgetTracker | `agent, year_month, used_cents, cap_cents, pct` |
| `budget.hard_stop` | system | BudgetTracker | `agent, year_month, used_cents, cap_cents, attempted_task` |
| `approval.requested` | agent | Agent.Server | `agent, task_path, task_id` |
| `approval.granted` | director | Router (on status flip) | `agent, task_path, approved_at` |
| `approval.denied` | director | Router (on status flip) | `agent, task_path, denied_at, reason` |
| `agent.wake` | system | Agent.Server | `agent, trigger` (trigger ∈ `inbox,heartbeat,mention,director-approval,director-request`) |
| `agent.dispatch` | system | Dispatch | `agent, task_path, provider, model, container_id` |
| `agent.complete` | agent | Dispatch | `agent, task_path, duration_ms, exit_status` |
| `acl.reconcile` | system | Container startup | `company, agent_count, rules_applied` |
| `network.policy_applied` | system | Container startup | `company, agent, policy, allow_list_hash` |

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Provider-specific SDK error handling | Unified `litellm.exceptions.*` taxonomy | litellm 1.x onward (2024) | Single error-handling code path in Router; retry/budget logic is provider-agnostic. |
| `chmod`/`chown` numeric UID for isolation | POSIX ACL (`setfacl -m u:<user>:rwx`) | POSIX.1e (mainline Linux ~2002) | Fine-grained per-user permissions without splitting into groups; DOES require filesystem mount with `acl` option. Supported by default on ext4/btrfs/xfs. |
| iptables chains for per-container egress | **Still no clean netavark/slirp4netns primitive in 2026.** | — | Phase 3 workaround: in-container nftables rules applied at entrypoint (pitfall 1). |
| Scheduler as background job framework (Quantum, Oban) | Pure-Elixir `Process.send_after` + `crontab` parser | Works for ≤dozens of agents per company | Avoids new supervisor tree; trivial to test. |
| Env-var API keys in containers | Per-request body field (Phase 2 D-37) | — | Prevents `podman inspect` leaks; key is request-scope memory only. |

**Deprecated / outdated:**

- **`kube-hack` / sidecar-proxy patterns for egress filtering.** Not needed for single-machine Podman; use in-container nftables directly.
- **Ollama `/api/generate` (legacy endpoint).** litellm docs recommend `ollama_chat/` prefix which uses `/api/chat` — already handled by litellm provider string, no code change needed.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `ecto_sqlite3 0.22.x` supports query-based `on_conflict` with `inc:` over composite `conflict_target: [:agent_slug, :year_month]` | Pitfall 4, Code Examples | If wrong, fall back to explicit `SELECT ... WITH ... UPDATE` in a transaction. Low-risk — SQLite 3.24+ supports this and ecto_sqlite3 ≥ 0.15 claims parity. Mitigation: add an integration test that concurrently upserts 1000 rows and verifies the final sum matches the contribution total. |
| A2 | `litellm.completion_cost(completion_response=resp)` returns `0.0` or `None` for Ollama models (safe to coerce to 0) | Code Examples, Standard Stack | If `None` is returned, the Python worker must coerce to `0.0` before writing the usage report; otherwise the Ecto insert will fail on NULL → integer. Mitigation: add `or 0.0` in the worker; verify in airplane-mode integration test. |
| A3 | Adding `--cap-add NET_ADMIN` ONLY to `api-only` containers does not leak into `none` containers when `Invocation.build_argv/4` is called sequentially | Pitfall 1, Code Examples | Invocation is pure — no shared state between calls — so this is low-risk provided the tests assert absence on `none`/`open`. |
| A4 | `/etc/subuid` range `foobarto:524288:65536` is sufficient for D-02's 100-UID-per-company blocks when starting from some configured base, NOT from `100000` | Pattern 4, Environment Availability | If the literal `100000` in D-02 is taken at face value, it's BELOW the host's subordinate range and setfacl via in-container UID 100000 will silently fail (map to something else). Mitigation: read `/etc/subuid` at UID-allocator init; treat D-02's formula as relative to the real base. Needs user confirmation. |
| A5 | The "Ollama response includes usage" claim from litellm docs holds for the Ollama UDS transport used in Phase 2 airplane-mode | Code Examples | If Ollama's `/api/chat` doesn't populate `eval_count`/`prompt_eval_count` on certain model/version combos, `resp.usage.completion_tokens` could be 0, which is fine numerically but misleading in the ledger. Mitigation: note it in Phase 2 Q-A3 disposition; add a unit-test assertion against a recorded Ollama response fixture. |
| A6 | `setfacl -b` applied from inside the container clears the ACLs on `/company/` for the RUNNING container's userns view AND persists to the host-visible filesystem | Pattern 4, Pitfall 2 | This is how POSIX ACLs normally work (they're filesystem-level xattrs) but rootless Podman + fuse-overlayfs could buffer writes. Mitigation: verify with `getfacl` from the host immediately after a container-side `setfacl`. Add this to the Doctor check set. |
| A7 | `podman` accepts `--userns keep-id` + a `/etc/passwd` overlay bind-mount that contains UIDs OUTSIDE the subordinate-UID range's mapping, and `su`/`runuser` to those UIDs works without additional `--uidmap` | Pattern 4 | If UIDs above the mapped range just fail to resolve inside the container, Phase 3 must pass explicit `--uidmap` args for every agent. This is likely needed anyway and should be verified in a Wave 0 spike. |
| A8 | In-container nftables rules applied by the entrypoint survive the full container lifetime (no netavark teardown/reload interferes) | Pattern 5, Pitfall 1 | Netavark re-applies its own rules on `podman network reload`; if Director ever reloads, in-container rules may get clobbered. Mitigation: run nftables rules in the container's own netns (which slirp4netns isolates) — container-level rules are independent of host netavark rules. |

**If this table is empty:** Not applicable — 8 assumptions identified. All are testable in Wave 0 spike tasks.

## Open Questions

1. **D-02's `100000 + 100*company_ordinal` formula vs real `/etc/subuid` base.**
   - What we know: host has `foobarto:524288:65536`; UIDs below 524288 are NOT in subordinate range on this host.
   - What's unclear: whether D-02 meant "literal 100000" or "base-relative 100000"; D-01 says "stable across restarts" which is true either way, but portability across hosts matters.
   - Recommendation: Wave 0 spike task that reads `/etc/subuid`, treats "100000" in D-02 as an offset into the subordinate range, and documents the actual starting UID as computed. Raise with user if interpretation differs.

2. **Is `--cap-add NET_ADMIN` on `api-only` containers acceptable, or does it violate RT-04/no-`--cap-add` too severely?**
   - What we know: RT-04 says no cap-add in the default (none) path; invocation.ex has a NEGATIVE test for no cap-add.
   - What's unclear: CONTEXT.md D-11 mentions "fallback to in-container `iptables`/`nftables`" which implies accepting NET_ADMIN for that policy; but no explicit user sign-off.
   - Recommendation: plan splits network-policy argv into three build paths; negative test asserts no cap-add for `none` and `open`; positive test asserts cap-add is NARROWLY applied only for `api-only`. Flag at plan-review time for explicit user approval.

3. **User proxy (tinyproxy on UDS) vs nftables CIDR for `api-only` — decide now or defer?**
   - What we know: LLM providers rotate IPs; hostname-based filter is sturdier.
   - What's unclear: whether the Director's test harness + CI rig can run a proxy daemon.
   - Recommendation: Phase 3 ships nftables-based CIDR allow-list (simpler, fewer moving parts); document "upgrade to tinyproxy if allow-list drift becomes operational overhead" as a Phase 3.1/v1.1 follow-up.

4. **Does `Agent.Server` dequeue the `pending_wakes` in FIFO or priority order (approval > mention > heartbeat > inbox)?**
   - What we know: D-20 says dedupe via GenServer serialisation.
   - What's unclear: if a Director approval arrives while the agent is running a routine heartbeat, does approval jump the queue?
   - Recommendation: FIFO in v1.0; user-observable reordering is surprising. If approval latency becomes a UX issue, add a priority enum in Phase 4 with dashboard.

5. **Container-lifetime: per-agent ephemeral vs per-company persistent — does Phase 3 mix?**
   - What we know: D-23 says "ephemeral by default, persistent when `agent.md` declares `lifecycle: persistent`."
   - What's unclear: if two agents in the same company have different lifecycles, do they share a container or run in separate containers?
   - Recommendation: one container per PER-AGENT lifecycle — simpler bookkeeping; matches "company isolation" invariant at a finer grain. Add to plan's key-decisions.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | ExUnit (built-in) + Ecto.Adapters.SQL.Sandbox (Phase 2 set up `DataCase`) |
| Config file | `config/test.exs` (existing) |
| Quick run command | `mix test --exclude integration --exclude inotify --exclude airplane --exclude acl --exclude netavark` |
| Full suite command | `mix test` (host with inotify-tools + podman + nftables + /etc/subuid configured) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AGT-01 | 6-child supervisor; agent crash restarts only that agent | unit (start_supervised + Process.exit + assert sibling PID unchanged) | `mix test test/glorbo/company/supervisor_test.exs` | ❌ Wave 0 |
| AGT-02 | Heartbeat fires Agent.Server.wake; inbox event fires wake; mention writes synthetic mention file | unit (mock Agent.Server.wake, assert called with correct trigger) | `mix test test/glorbo/company/scheduler_test.exs test/glorbo/company/router_test.exs` | ❌ Wave 0 |
| AGT-03 | Router permitted path copies to inbox; denied path writes `.rejected.md` + inbox notice | unit (tmp dirs + frontmatter fixtures) | `mix test test/glorbo/company/router_test.exs` | ❌ Wave 0 |
| AGT-04 | Dispatch resolves skills; missing skill → warn + audit; unknown skill dropped | unit | `mix test test/glorbo/agent/dispatch_test.exs` | ❌ Wave 0 |
| AGT-05 | Agent-creation outbox message rejected with `permission.denied` | integration + unit | `mix test test/integration/agent_create_denial_test.exs --include integration` | ❌ Wave 0 |
| SEC-01 | Router calls ACLMapper.check_action; denial flows through rejection path | unit (ACLMapper pure tests) | `mix test test/glorbo/security/acl_mapper_test.exs` | ❌ Wave 0 |
| SEC-02 | SC-4 kernel denial test: spawn container, exec as agent, attempt restricted write, assert EACCES | integration `:acl` + `:podman` | `mix test test/integration/kernel_acl_denial_test.exs --include acl --include podman` | ❌ Wave 0 |
| SEC-03 | api-only denies non-allowlisted egress (concrete HTTP GET rejected) | integration `:netavark` + `:podman` | `mix test test/integration/network_policy_test.exs --include netavark --include podman` | ❌ Wave 0 |
| SEC-04 | Approval sentinel appears on `requires_approval`; status flip wakes agent | integration `:inotify` + unit | `mix test test/glorbo/approvals/gate_test.exs test/integration/approval_flow_test.exs` | ❌ Wave 0 |
| SEC-05 | BudgetTracker hard-stops at cap; alerts at 80%; monthly rollover | unit + property (10 concurrent upserts, sum matches) | `mix test test/glorbo/company/budget_tracker_test.exs test/glorbo/budget/ledger_test.exs` | ❌ Wave 0 |
| LLM-03 | Worker receives api_key via /run body; litellm dispatches to Anthropic/OpenAI/Google | integration `:cloud` (skipped by default; needs keys) | `mix test test/integration/cloud_provider_test.exs --include cloud` | ❌ Wave 0 |
| LLM-04 | `agent.md` with two models → parse error; one provider+model → OK | unit | `mix test test/glorbo/agent/definition_test.exs` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `mix test --exclude integration --exclude inotify --exclude airplane --exclude acl --exclude netavark --exclude cloud` — should run in < 30 seconds.
- **Per wave merge:** `mix test --include inotify` (local suite on dev host with inotify-tools).
- **Phase gate:** `mix test --include inotify --include acl --include netavark --include podman --include airplane --include integration` — requires all host deps installed + `glorbo-runtime` image present. Excludes `:cloud` unless API keys are available in env.

### Wave 0 Gaps

- [ ] `test/glorbo/security/acl_mapper_test.exs` — pure unit tests for permission → ACL-entry mapping (no container needed).
- [ ] `test/glorbo/company/router_test.exs` — needs frontmatter fixtures + tmp dirs; dep-injected file ops.
- [ ] `test/glorbo/company/scheduler_test.exs` — mock time via `Process.send_after` override.
- [ ] `test/glorbo/company/budget_tracker_test.exs` — DataCase + in-memory SQLite.
- [ ] `test/glorbo/budget/ledger_test.exs` — Ecto concurrent-upsert property test.
- [ ] `test/glorbo/agent/server_test.exs` — GenServer state machine (idle/dispatching/awaiting-approval).
- [ ] `test/glorbo/agent/dispatch_test.exs` — end-to-end with all services mocked.
- [ ] `test/glorbo/approvals/gate_test.exs` — sentinel lifecycle.
- [ ] `test/glorbo/skills/resolver_test.exs` — skills injection.
- [ ] `test/glorbo/llm/provider_test.exs` — api_key resolution from config.md; provider whitelist.
- [ ] `test/integration/kernel_acl_denial_test.exs` — :acl + :podman (SC-4 kernel denial).
- [ ] `test/integration/network_policy_test.exs` — :netavark + :podman (api-only egress rejection).
- [ ] `test/integration/approval_flow_test.exs` — :inotify end-to-end.
- [ ] `test/integration/agent_create_denial_test.exs` — AGT-05 end-to-end.
- [ ] `test/integration/six_child_supervisor_test.exs` — :inotify (B5 update: 2 → 6 children).
- [ ] Update `test/glorbo/application_test.exs` — assert 6-children shape (Phase 2 asserted 2).
- [ ] Framework install: none — ExUnit + DataCase already in place.
- [ ] Add `:acl`, `:netavark`, `:cloud` module tags to `test/test_helper.exs` with auto-exclusion when host binaries/keys are absent (pattern from Phase 2's `:inotify` tag).

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V1 Architecture | yes | Defence in depth at 3 layers (Router + ACL + network policy); documented threat boundaries in this RESEARCH + plan threat_model sections. |
| V2 Authentication | no | N/A — single-Director trust model; no multi-user auth in v1 (PROJECT.md Out of Scope). Dashboard in Phase 4 runs on localhost-only by default. |
| V3 Session Management | no | No sessions in Phase 3 (host-bound file-ownership auth). |
| V4 Access Control | **yes — primary** | POSIX ACL enforcement at kernel layer (SEC-02); `resource:action:scope` permission system; Router as single choke-point for authorisation; AGT-05 agent-creation restriction via permission system (no agent has `agents:create`). |
| V5 Input Validation | yes | `agent.md` frontmatter parser MUST validate `permissions:`, `provider:` (enum whitelist), `model:`, `heartbeat:` (cron parse must succeed), `network:` (enum); task frontmatter `status:` (enum: pending, in-progress, approved, denied, complete); channel append text (no literal inbound HTML; preserve as markdown). |
| V6 Cryptography | no | No new crypto in Phase 3. API keys stored in `config.md` at `chmod 0600`; disk-at-rest encryption is OS-level (Director's responsibility). |
| V7 Error Handling & Logging | yes | Append-only audit log is the security-event sink; new Phase 3 actions (`permission.denied`, `budget.hard_stop`, `approval.*`) are security-relevant. Actor, action, target, timestamp captured per event (DESIGN.md §8.3). |
| V8 Data Protection | yes | API keys never cross container boundary as env vars (D-37); never written to company dir; request-scope memory only. |
| V9 Communication | yes | Unix Domain Socket for worker transport (network: none by default); no TLS/network-layer crypto inside the host-↔-container channel. |
| V10 Malicious Code | **yes — primary** | LLM-generated Python runs INSIDE the glorbo-runtime container with restricted ACLs + restricted network; even a fully-compromised LLM can't escape without kernel CVE. No trusted-code/untrusted-code mixing in the same namespace. |
| V11 Business Logic | yes | Approval gate (SEC-04) is a business-logic enforcement point; pre-dispatch budget check is another (SEC-05). |
| V12 Files & Resources | yes | POSIX ACL + `--read-only` container root FS + `--tmpfs /tmp` bound writes to workspace/outbox/state only. |
| V13 API | yes | Python worker `/run` + `/cancel` POST endpoints over UDS; schema additive from Phase 2 (adds `skills_resolved:`); no breaking changes. |
| V14 Configuration | yes | `config.md` keys secure-by-default (`chmod 0600` enforced by init; Doctor checks post-hoc); `agent.md` validation rejects unknown providers, malformed permissions, non-cron heartbeat. |

### Known Threat Patterns for {Elixir/OTP + rootless Podman + Python/litellm in container}

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| LLM-generated Python writes outside its permitted scope | Tampering | POSIX ACL enforcement (SEC-02); SC-4 integration test assertion. |
| Agent sends message it lacks `chat:write:<channel>` for | Elevation of Privilege | Router permission check (SEC-01); denied message emits `.rejected.md` + audit event. |
| Prompt injection tricks agent into egressing to attacker HTTP | Information Disclosure | `api-only` network policy via in-container nftables allow-list (Pitfall 1 mitigation). Default `network: none` means even a compromised LLM has no egress. |
| API key leaks into container env vars → `podman inspect` exposes it | Information Disclosure | D-37 per-request body injection; Invocation test has NEGATIVE assertion that no API-key env vars appear in argv. |
| Runaway agent burns through cloud budget | Denial of Service (self-inflicted) | Pre-dispatch budget hard-stop (SEC-05); hard-stops before the first call in a minute that would exceed cap. |
| Agent spawns rogue agent.md via its outbox | Elevation of Privilege | AGT-05: no agent has `agents:create` permission; Router rejects any outbox-originated `agents/<new>/agent.md` write. |
| Concurrent usage-report writes clobber each other | Integrity | Router-serialised audit writes; BudgetTracker is single-process upsert (GenServer mailbox serialises); concurrent-upsert property test. |
| Compromised agent reads another agent's inbox | Information Disclosure | POSIX ACL `u:<victim>:---` on sibling inbox; kernel denies regardless of Python exploit. |
| Symlink attack: agent symlinks its outbox to another agent's inbox | Tampering | Router MUST `File.lstat` and reject symlinks before copy; ACL on sibling inbox prevents symlink traversal anyway (ACL checked at the TARGET inode, not the symlink source). Add a unit test. |
| Approval-file edit-race: agent's outbox writes `status: approved` to its own task | Elevation of Privilege | ACL `u:agent:---` on `projects/*/tasks/*.md` for agents without `tasks:update:*` permission; Director-only writes honoured. For agents WITH write permission, Router/Gate filters out `status:` field changes originating from non-Director outbox messages. |
| Container escape via kernel CVE | Elevation of Privilege | Rootless Podman + user namespaces + `--read-only` + dropped caps (except narrow `NET_ADMIN` on `api-only`). No mitigation beyond defense-in-depth; accept as residual risk per CLAUDE.md's threat model. |

**Prompt-injection specific note:** The Phase 3 design is deliberately aligned with the "policy-based access control beats pure sandboxing" thread in current AI-safety literature (`[CITED: multikernel.io/2026/04/03/ai-agent-sandboxes-got-security-wrong, medium.com/@adnanmasood sandboxed-mind]`). Agents are sandboxed PLUS constrained by per-tool, per-path, per-host policy. A prompt-injected agent hitting `projects:write:<scope>` can only write to `<scope>` — the kernel says no to anything else, regardless of the injection's content.

## Sources

### Primary (HIGH confidence)

- `crontab` hex package — https://hex.pm/packages/crontab (VERIFIED via `mix hex.info crontab` on dev host, 1.2.0 latest)
- `Crontab.Scheduler` / `Crontab.CronExpression.Parser` — https://hexdocs.pm/crontab/ (official)
- Podman rootless user-namespace modes — https://docs.podman.io/en/latest/markdown/podman-run.1.html#userns and https://www.redhat.com/en/blog/rootless-podman-user-namespace-modes
- litellm token usage & cost — https://docs.litellm.ai/docs/completion/token_usage
- litellm response schema — https://docs.litellm.ai/docs/completion/output
- litellm exception mapping — https://docs.litellm.ai/docs/exception_mapping
- Ecto `on_conflict` constraints docs — https://hexdocs.pm/ecto/constraints-and-upserts.html
- Netavark upstream issue: per-container outbound rules — https://github.com/containers/netavark/issues/875 (closed without implementation)
- Dev host verification — Fedora 43, kernel 6.17.7, setfacl 2.3.2, podman 5.8.1, netavark 1.17.2, slirp4netns 1.3.1, nftables 1.1.3 (all VERIFIED via local bash probe)

### Secondary (MEDIUM confidence)

- Ecto upsert practice (Peter Ullrich) — https://peterullrich.com/complete-guide-to-upserts-with-ecto
- ecto_sqlite3 limitations — https://hexdocs.pm/ecto_sqlite3/Ecto.Adapters.SQLite3.html (does not explicitly document `inc:` behaviour — confidence MEDIUM)
- litellm Ollama provider docs — https://docs.litellm.ai/docs/providers/ollama (usage schema verified; cost=0 for Ollama INFERRED from model_cost DB absence)
- Netavark firewalld interaction — https://www.mankier.com/7/netavark-firewalld
- Netavark nftables changeset — https://fedoraproject.org/wiki/Changes/NetavarkNftablesDefault

### Tertiary (LOW confidence — flagged for validation)

- Per-container egress allowlist workarounds (discussion threads) — https://lists.podman.io/archives/list/podman@lists.podman.io/thread/NKVFO4JQO5JLYKWXHHODC2WHQRG7A2KO/ (unresolved thread; workarounds reported but not canonical)
- Prompt-injection mitigation state-of-the-art — multikernel.io, medium (@adnanmasood), Trail of Bits blog (opinion pieces; use for direction, not design contract)

## Metadata

**Confidence breakdown:**

- Standard stack (crontab, ecto, jason, finch): HIGH — versions verified via `mix hex.info`; usage patterns match project conventions established Phases 1–2.
- Architecture patterns (6-child supervisor, Router choke-point, cron via send_after, pre-dispatch budget check): HIGH — all patterns align with CONTEXT.md decisions verbatim and cite either hexdocs or existing Phase 2 code.
- Pitfalls (netavark egress, userns user provisioning, ACL mount compat, SQLite upsert, approval race, audit concurrency, cron drift): HIGH on netavark (upstream issue cited), MEDIUM-HIGH on SQLite upsert (empirical community reports; spike needed in Wave 0 to confirm), HIGH on the rest.
- Security domain (ASVS V4/V10 primary; threat table): HIGH — aligns with DESIGN.md §12 and CLAUDE.md invariants; `prompt-injection as SQL-injection of 2026` framing is current.
- Validation architecture: HIGH — tags follow Phase 2 pattern; dep injection for testability is established project convention.

**Research date:** 2026-04-16

**Valid until:** 2026-05-16 (30 days — stable domain; longer valid for Elixir stack, shorter for network-policy research which is actively evolving).

---

*Phase: 03-agents-routing-kernel-permissions-budgets*
*Research gathered: 2026-04-16*
