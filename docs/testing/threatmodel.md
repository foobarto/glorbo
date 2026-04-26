
## Overview
Glorbo is a self-hosted agent orchestration platform that runs external LLM CLI tools inside kernel-level `bwrap` sandboxes. All company data (agents, tasks, chat, approvals, audit logs) is stored as markdown/JSONL under `~/.glorbo/companies/<company>/`, with SQLite (`glorbo.db`) used only as a rebuildable index for the dashboard. Operators interact through a Phoenix LiveView dashboard (default `127.0.0.1:4000`) and a local MCP JSON-RPC endpoint (`/mcp`). The runtime launches agents via `Glorbo.Agent.Dispatch` and routes all agent-authored writes through `Glorbo.Company.Router`, enforcing permissions in both the application layer and the kernel layer (`Glorbo.Security.ACLMapper` + `Glorbo.Sandbox.PermissionMapper`).

Security goals in this codebase are: (1) contain untrusted agent/LLM output, (2) enforce per-agent and per-company isolation, (3) protect host secrets and provider credentials, (4) preserve append-only audit logs for forensics, and (5) prevent runaway cost or unsafe actions via budgets and approval gates.

## Threat model, Trust boundaries and assumptions
### Trust boundaries
- **Host ↔ sandbox boundary:** untrusted agent processes run inside `bwrap` (`lib/glorbo/sandbox/bwrap.ex`). The kernel namespace boundary is the primary security control.
- **Router boundary:** all agent writes must flow through `Glorbo.Company.Router` (`lib/glorbo/company/router.ex`) which validates sender identity and permissions.
- **Company boundary:** each company has its own directory tree; bwrap only mounts the active company’s directory to keep siblings invisible.
- **HTTP boundary:** dashboard and MCP requests are external inputs that can mutate the filesystem via `GlorboWeb.Actions` and MCP tools.
- **File-format boundary:** YAML frontmatter, markdown bodies, and JSONL logs are untrusted inputs parsed by the system.

### Attacker-controlled inputs
- Agent output files in `agents/<slug>/outbox/`, `workspace/`, and reply files; filenames and markdown bodies are fully attacker-controlled.
- Network egress from agents when `network: open` or `network: proxy` is configured.
- HTTP requests to the dashboard or MCP endpoint (if accessible on the host).
- Files and logs written by provider CLIs (usage JSONL, stdout, etc.).
- Any file placed under `~/.glorbo` by external processes running as the same OS user.

### Operator-controlled inputs
- `~/.glorbo/config.md` (secret_key_base, dashboard token, host/port), environment overrides, and file permissions.
- Agent/company frontmatter (permissions, budgets, network policy, approvals).
- Provider registry TOML (`auth_binds`, invocation args), network allowlists (`config/network_policy.exs`).

### Developer-controlled inputs
- Mix tasks, tests, CI scripts, release packaging, docs. These are not runtime attack surfaces but affect supply-chain integrity.

### Assumptions
- Default deployment is **local-only** (loopback binding). LAN exposure is opt-in and should set a dashboard token.
- `bwrap` and user namespaces are available on Linux; if unavailable (macOS), agents run unsandboxed with a warning (`lib/glorbo/sandbox/unsandboxed.ex`).
- The local OS user running Glorbo is trusted; if an attacker already has that user’s shell, they can bypass filesystem controls (out of scope).
- External LLM CLIs may be buggy or adversarial; the sandbox is expected to contain them.

## Attack surface, mitigations and attacker stories
### Agent runtime & sandbox
**Surface:** `Glorbo.Agent.Dispatch` + `Glorbo.Sandbox.Bwrap` spawn external CLIs inside a sandbox with per-permission mounts. Agent permissions are parsed in `Glorbo.Agent.Parser` and mapped to mounts by `Glorbo.Sandbox.PermissionMapper`.

**Mitigations:**
- `bwrap` baseline flags drop capabilities and isolate namespaces (`--unshare-user-try`, `--unshare-pid`, `--unshare-net`, `--cap-drop ALL`) and mount only a minimal `/etc` (`lib/glorbo/sandbox/bwrap.ex`).
- Per-permission mounts enforce **sibling invisibility**; only permitted project/channel paths are mounted (`lib/glorbo/sandbox/permission_mapper.ex`).
- Application-layer permission checks via `Glorbo.Security.ACLMapper` + `Company.Router` provide defense in depth.
- `Agent.Parser` uses allowlists, slug regexes, and avoids atom creation on user input; it rejects `agents:create` permissions (`lib/glorbo/agent/parser.ex`).
- `network: none` unshares the netns; `network: proxy` uses an allowlist proxy (`lib/glorbo/network/proxy.ex`) exposed inside a pasta-created private netns on Linux, so direct access to unrelated host loopback ports is blocked.
- Execution timeouts kill runaway CLI processes; reply file contracts and audit events capture failures.

**Attacker stories:**
- A malicious agent attempts to read or write outside its allowed project using path traversal in permission scopes or symlinks in its workspace.
- A compromised CLI with `network: proxy` is still limited by the proxy path on Linux, but `network: open` remains fully trusted egress and macOS stays in the documented unsandboxed degraded mode.
- On macOS, the unsandboxed fallback could allow full host access if a malicious agent runs.

### Router & filesystem routing
**Surface:** `Glorbo.Company.Router` handles outbox messages, tasks, and path requests; it is the central gate between agent-controlled files and host writes.

**Mitigations:**
- Sender identity is derived from the outbox path (anti-spoof), and control characters in `msg_id`/`to` are rejected to prevent YAML/frontmatter injection.
- `ACLMapper.check_action` enforces permission checks before routing; `agents:create` is explicitly blocked.
- Channel writes are append-only with `[:append, :sync]` to avoid interleaving races; rejections are audited and archived.
- Director actions use `GlorboWeb.Actions` with slug/path validation and symlink checks (`File.lstat!`) before writing.

**Attacker stories:**
- An agent tries to impersonate another sender by crafting an outbox file path; the router’s `verify_sender_slug` should reject it.
- An agent tries to send a message with embedded newlines to smuggle frontmatter or overwrite other files.
- A symlink swap attempt aims to redirect channel/task writes to arbitrary host paths.

### Path access requests
**Surface:** Agents can request temporary access to host paths via `path-request-<task_id>.md` handled by `Glorbo.PathRequestGate`.

**Mitigations:**
- Only absolute paths are accepted; `..` and `/proc|/sys|/dev` are rejected; request size and count are capped.
- Director approval is required and grants are stored in `PathGrantStore` and revoked after dispatch.

**Attacker stories:**
- An agent requests sensitive files or attempts to smuggle a forbidden path via symlink or path tricks.
- A race or validation bug could grant more access than approved.

### Web dashboard & LiveView
**Surface:** Phoenix LiveView routes, search API, and session cookies (`lib/glorbo_web/router.ex`).

**Mitigations:**
- CSRF protection and secure browser headers are enabled in the `:browser` pipeline.
- Optional bearer token gate (`lib/glorbo_web/plugs/dashboard_token.ex`) protects LAN exposure; constant-time compare avoids timing leakage.
- Slug validation (`GlorboWeb.Slug`) and write paths in `GlorboWeb.Actions` prevent path traversal.
- Default binding is loopback (`config/runtime.exs`), limiting remote access by default.

**Attacker stories:**
- If the operator binds to `0.0.0.0` without a token, any LAN user could approve tasks, create agents, or read audit logs.
- Token leakage via URLs, browser history, or referrers could grant access to the dashboard.

### MCP server
**Surface:** The `/mcp` endpoint provides JSON-RPC tools that can mutate state (approve tasks, create agents, etc.).

**Mitigations:**
- `GlorboWeb.MCP.Plug` enforces origin allowlists to reduce DNS rebinding risk and validates protocol headers.
- `GlorboWeb.MCP.Args` validates slugs before any path construction.
- Tool implementations delegate to `GlorboWeb.Actions` or the Router for consistent validation.
- Default loopback binding is the outer boundary; MCP is intentionally not behind the dashboard token.

**Attacker stories:**
- A local malicious process (or remote attacker if bound to LAN) could call MCP tools to approve/deny tasks or create privileged agents.
- Origin checks could be bypassed if a client spoofs headers or if the operator exposes the endpoint beyond localhost.

### Markdown rendering & XSS
**Surface:** Agent-authored markdown in channels, task comments, and proposals displayed in the dashboard.

**Mitigations:**
- `GlorboWeb.Markdown` renders via Earmark and sanitizes with `HtmlSanitizeEx`; mention/linkification uses escaped tokens (`lib/glorbo_web/markdown.ex`).

**Attacker stories:**
- A malicious agent attempts to inject `<script>` or `javascript:` URLs to capture the dashboard token or modify UI behavior.

### Audit log integrity
**Surface:** Audit logs are the authoritative record of actions (`audit/YYYY-MM.jsonl`).

**Mitigations:**
- `Glorbo.Company.AuditLog` only appends JSON-encoded records with `fsync`; there is no update/delete API.
- SQLite is derived; failure to mirror doesn’t erase the JSONL entry.

**Attacker stories:**
- An attacker tries to inject newline-delimited JSON to forge or hide audit events, or manipulate the company slug to redirect log writes.

### Secrets, config, and provider bindings
**Surface:** `config.md` holds secret_key_base, dashboard token, and Erlang cookie; provider TOML can mount host auth directories into sandboxes.

**Mitigations:**
- `Glorbo.Config` writes secrets with mode `0600` via atomic rename and never logs secret values (`lib/glorbo/config.ex`).
- `Filesystem.Hierarchy` locks down `runtime/sockets` and `run` directories to `0700`.
- Provider registry loader validates `auth_binds` shapes; bwrap binds are read-only by default (`lib/glorbo/cli/registry/loader.ex`).

**Attacker stories:**
- A second local user reads `config.md` if permissions are weakened.
- Misconfigured `auth_binds` mount sensitive host paths into the sandbox, effectively bypassing isolation.

### Build/CI vs runtime
Mix tasks and release scripts (`lib/mix/tasks/*`, `rel/`) are developer-controlled and generally out of runtime scope. The main security concern here is supply-chain integrity of release binaries and external CLI tools.

## Criticality calibration (critical, high, medium, low)
### Critical
Vulnerabilities that break core isolation or enable unauthorized remote control.
- Examples: sandbox escape from `bwrap`, cross-company data access, bypass of Router permission checks to write arbitrary host paths, or unauthenticated remote access to dashboard/MCP with mutation capabilities.
- Tampering with or deleting audit logs to conceal actions also qualifies.

### High
Severe permission or secret exposure requiring some local access or misconfiguration.
- Examples: path traversal in permission scopes granting access to unintended projects, bypass of `network: none` or path-request approval, leakage of `config.md` or provider credentials, or XSS that steals a dashboard token when the UI is LAN-exposed.

### Medium
Impactful but constrained to local-only deployment assumptions or requiring user interaction.
- Examples: CSRF or XSS against a loopback-only dashboard, DoS via large files or inotify flooding (bounded by caps and watcher limits), or corruption of the SQLite index (non-authoritative).
- These rise to High/Critical if the operator exposes the service to LAN or runs on shared hosts.

### Low
Defense-in-depth gaps or minor disclosures without a clear exploitation path.
- Examples: overly verbose error messages, minor markdown rendering quirks, or non-sensitive metadata leakage (versions, uptime). These matter mostly for hardening, not direct compromise.

---

## Open findings

Codex scan (2026-04-22 / 2026-04-23 sweep, 126 findings). **56 open** ·
58 dropped: waves 1–3 on 2026-04-22 closed 26; wave 4 on 2026-04-23
closed 6 highs (dispatcher reply lstat, router slug validation,
approval-gate director mark, dispatch task_id validation); wave 5
closed 3 mediums (Kanban list_projects lstat+slug, AgentLive io
preview lstat, TaskDefinition.write regular-file guard); wave 6 on
2026-04-23 closed 4 mediums (ACLMapper scope validation, skills
resolver lstat, watcher/reindex lstat, config/log 0600 + doctor
warning) and verified 3 more mediums were already fixed at HEAD
(MCP create_agent YAML injection, proposal key injection, restore
symlink-target guard); wave 7 on 2026-04-23 closed 4 mediums
(Kanban open_task strict path+lstat guard, release formula SHA
validation, agent budget block enforcement, backup temp+rename
0600 flow); post-wave-7 follow-up fixes on 2026-04-23 closed 6 more
mediums (proxy acceptor mailbox DoS, console cookie argv exposure,
stdout streamer buffer cap, search title-cache cap, archive list
metadata-only refresh, stuck sentinel row validation); post-v0.4
budget-scoping fixes on 2026-04-23 closed 1 medium
(cross-company budget/company-cap bleed); wave 8 on 2026-04-23 closed
the final 3 mediums (MCP session idle reap + subscription cap +
capacity 503, file-only CLI binary binds, GitHub Action SHA pinning);
wave 5 also discovered 6 more mediums were
already fixed by earlier waves
(false-positive Codex flags; verified against HEAD); **wave 9 on
2026-04-25** verified 4 lows already fixed at HEAD (MCP initialize
list-params guard, InboxLive path-approval defensive flat_map,
ProposalsSink "proposal-file" sentinel actor, AgentLive
find_agent_server pinned to (company, slug) tuple) and closed 1
more low (FileSpec.Validator now uses `:file.read_link_info`
instead of `File.stat`, refusing to follow symlinks during
walk + dir-expand); **wave 10 on 2026-04-25** closed 2 more lows
(Kanban return_to open-redirect tightened — `same_origin_path?/1`
rejects `//evil.com` + `/\\windows`-style protocol-relative URLs;
Scheduler.default_heartbeat_lookup/3 lstat'd to refuse symlinks +
non-regular files, blocking DoS-via-/dev/zero pivot); **wave 11 on
2026-04-25** verified 1 low already fixed at HEAD (TaskLive
`delete_task` now delegates to `Actions.Tasks.trash/3` which
emits the `task.trash` audit entry through the home-history Tx)
and closed 2 more lows (Channels.create's `guard_not_exists/1`
switched from `File.exists?` to `:file.read_link_info` so a
dangling symlink at `channels/<n>.md` no longer lets an attacker
clobber an arbitrary path via `File.write`; Companies.update's
`atomic_write/2` now lstat-gates the destination + uses a
unique-per-call temp filename to defeat the predictable-tmpfile
race that let attackers redirect the rename target); **wave 12
on 2026-04-25** closed 3 more lows (TaskDefinition's `as_string/1`
now refuses to coerce maps/lists — agent-controlled YAML can no
longer crash parsing on `schedule: {foo: bar}` or `goal: [a, b]`,
which fixes both the recurring-schedule and goal-frontmatter
findings; AuditLog's `entry_company/1` validates the company
against the canonical slug regex and buckets path-traversal
attempts like `company: "../../etc"` into the `_system` bucket
rather than scribbling outside `companies/`); **wave 13 on
2026-04-25** verified 1 low already fixed at HEAD (Reindex's
`safe_markdown_files/1` already calls
`AgentWritableFile.any_symlink_in_path?/1` to reject symlinked
ancestors — the lexical-only check the finding mentioned was
fortified after the wave-6 sweep) and closed 3 more lows
(`Glorbo.CLI.Dispatcher.strip_ansi/1` now coerces invalid UTF-8
to printable bytes via `:unicode.characters_to_binary/3` before
calling `String.replace/3`, blocking the dispatcher-crash on
attacker-controlled CLI stdout; `Glorbo.Agent.RunLog` switched
from `String.to_integer/1` to `Integer.parse/1` for `duration_ms`
so a tampered audit row no longer crashes every reader of the run
log; `Glorbo.CLI.Lifecycle.Distribution.ensure_epmd/0` no longer
falls back to a bare `"epmd"` PATH search if the bundled ERTS
binary is missing — closes the local-PATH-hijack vector); **wave
14 on 2026-04-25** verified 1 low already fixed at HEAD
(`Glorbo.Restore.run/2` already extracts to a sibling
`<base>.restore-<ts>/` staging dir + verifies symlinks before
moving anything into base, so the "rejection leaves modified
files" path is structurally impossible — the staging tree gets
`File.rm_rf`'d in the `after` regardless) and closed 3 more lows
(bwrap prompt tempfile now uses `:file.open(..., [:exclusive])`
+ an 8-byte `crypto.strong_rand_bytes` suffix + 0600 mode,
blocking the predictable-tmpfile-symlink-redirect race;
`maybe_log_run_output/4` switched from `String.slice/3` to
`binary_part/3` so a non-UTF-8 stdout doesn't crash the warning
path; the three CLI parsers — claude_jsonl, codex_jsonl,
gemini_stdout — now coerce token counts via `coerce_int/1`
before summing, so a malicious or buggy CLI emitting strings or
lists in `input_tokens`/`output_tokens`/etc no longer raises an
ArithmeticError out of the dispatcher's accumulator); **wave 15
on 2026-04-25** verified 1 low already fixed at HEAD
(OverviewLive's `safe_goal_slug/1` already filters non-scalar
goal slugs — the threatmodel finding's wording matched a prior
version) and closed 2 more lows (BudgetTracker.write_alert_file
now slug-validates `agent_slug` via `Glorbo.Actions.Support`
before joining it into the alert path, refusing path-traversal
attempts; sidebar `count_memory_files/2` caps the
`Stream.filter` walk at 999 entries via `Enum.take` so an agent
spamming thousands of memory files can't slow every sidebar
render); **wave 16 on 2026-04-25** verified 1 low already fixed
at HEAD (StdoutStreamer's pending-buffer is already capped at
@line_max_bytes=8192 via `cap_partial_buffer/1`, so the
unlimited-line-buffer DoS is already mitigated) and closed 2
more lows (`Glorbo.Agent.Memory.compose/3` now lstats every
memory body + the MEMORY.md index before reading, skipping
files past 1 MiB or non-regular shapes — defends the BEAM heap
against attacker-uploaded huge memory files; `glorbo run` CLI
verb now consults `TaskDefinition.requires_approval?/1` and
refuses to dispatch a director-required task whose status
isn't `"approved"` — closes the back-door bypass of the
dashboard approval gate); **wave 17 on 2026-04-25** verified
3 lows already fixed at HEAD (Kanban's `kanban:move` validates
the task path against the strict `\Aprojects/[a-z0-9-]+/tasks/
[a-z0-9-]+\.md\z` regex + lstat — not the loose `starts_with?
("projects/")` the finding mentioned; Reindex.cleanup_vanished
already chunks the `where ... in` deletes at 500 to stay below
SQLite's 999-bind-variable cap; FrontmatterWriter.yaml_scalar
already escapes backslash / quote / NL / CR / TAB and strips
C0 controls, not just double-quotes) and closed 3 more lows
(TaskLive.load_usage_totals, AgentLive.load_history, and
InboxLive.load_recent_audit all switched from `File.read +
String.split + Enum.reverse` to `File.stream!([], :line) +
rolling-window reduce` so memory stays bounded by the visible-
row cap (50–200) regardless of audit-log size — closes the
"unbounded-audit-read OOMs the BEAM" DoS family); **wave 18 on
2026-04-25** verified 2 lows already fixed at HEAD
(SmartClassifier rule order — `private_ip?/1` runs BEFORE the
allowlist check per threatmodel T8, so an explicitly-allowlisted
host that's also a private IP still gets denied; Proxy
`safe_classify/3` already validates classifier verdicts via
`normalise_classifier_result/1` and degrades non-tuple returns
to `{:unknown, :classifier_malformed}` per threatmodel T14) and
closed 2 more lows (Agent.Server's `reply_target/1` +
`format_reply_hint/1` now match BOTH the legacy
`kind: task_assignment` and the current
`kind: inbox-message/v1, subkind: task_assignment` envelope —
closes the regression that broke task-assignment reply routing
after the inbox-message file-format rev; Company.Supervisor's
boot-time `read_smart_egress/1` and `agent_network_allow_list/1`
now lstat-gate agent.md at 256 KiB before reading, so an agent
with a 1 GB agent.md can't OOM the supervisor init); **wave 19
on 2026-04-25** verified 4 lows already fixed at HEAD
(Glorbo.Schedule.NL.compile/1 already handles `Regex.run`
trailing-nil captures via `split_rest/[0|1|2]`; Costs
`history_for_agents/1` keys by the `{company, agent}` MapSet,
not just agent_slug, so cross-company collisions don't merge;
TaskComments `Regex.scan(:all_names)` returns alphabetical
order — the destructure `[author, body, ts]` matches; Model
alias parsing's `to_string/1` exposure no longer applies after
the GEP-32 native-config refactor) and closed 3 more lows
(AgentLive `do_config_save/2` now whitelists `network` against
the parser's loopback/proxy/full vocabulary so a tampered form
can't write garbage to AGENT.md; ScheduleNL.dispatch now
recognises `every weekday at <time>` / `every weekend at <time>`
via a `parse_weekday_bucket/4` helper — closes the
"documentation says supported but parser only matches bare
`weekday`/`weekend`" gap; ProvidersLive.read_toml masks
secret-shaped values via a regex over
`api[_-]?key|secret|token|password|auth(orization)?` keys so
user-authored providers.toml with literal credentials doesn't
leak via the dashboard's collapsible TOML view); **wave 20 on
2026-04-25** closed 2 more lows (Chat rotation's
`split_at_tail_boundary/2` switched from `String.split_at/2`
to `binary_part/3` — `Regex.scan(:index)` returns byte offsets
so the grapheme-aware split was corrupting messages with
multibyte UTF-8; TaskScheduler.maybe_emit_invalid now cancels
the prior `timer_ref` before stashing a minimal invalid-stub
entry, preventing the orphan timer from firing against a
now-invalid schedule); **wave 21 on 2026-04-25** verified 3
lows already fixed at HEAD (MCP post_message mention fanout
already propagates the actor via `safe_actor_tag/1` so MCP-
originated mentions land with `from: "mcp:<client>"` not
`from: "director"` — threatmodel T6; Task budget audit's
`cost_cents_from_usage/2` rescues to 0 on a nil
`spec.provider`, and `Dispatch.reconcile_task_provider/2`
already enforces M10 — task.provider mismatches are pinned
to spec.provider, so the cost computation always matches the
provider that actually ran; the `/mcp` JSON-RPC endpoint is
now wrapped in the `:dashboard` pipeline per threatmodel T11
— if `dashboard_token` is configured, MCP clients must
authenticate via `Authorization: Bearer <token>` just like
the dashboard) and **moved 2 to "accepted risk / by-design"**
(Stdout spoofed dispatch/exit markers — the audit log's
`agent.complete` event is the authoritative exit_status; UI
marker spoofing is cosmetic, fix would require a UI-side
audit cross-reference; Release boot check
`validate_compile_env: false` — deliberate per the rationale
in mix.exs:113-124, CI always builds with MIX_ENV=prod, the
LV / endpoint compile-env keys aren't load-bearing at runtime).

**Codex import: fully closed.** All 39 originally-imported lows
have been either fixed (37) or moved to documented accepted-
risk status (2). The 24 informational entries remain as a
correctness/UX backlog; they are not direct security gaps and
will be triaged into general bug-fix waves rather than security
sweeps.

**Codex re-scan #3 2026-04-25 22:30** (post-v0.11.1, raw at
`.reports/codex-security-scan-2026-04-25-2230.md`) surfaced 9
more findings (3 high, 6 medium). Plus the v1 scan output that
landed late (`2026-04-25-2154.md`) had 6 findings. All closed
in **wave 23**:

  * **High** — TaskDefinition `atomic_write` predictable temp
    path TOCTOU race (now uses crypto-random suffix +
    `:file.open([:exclusive])`).
  * **High** — Actions.Projects `update/4` predictable temp +
    lstat-then-write race (same fix).
  * **High** — Unsandboxed prompt tempfile predictable + non-
    exclusive (mirrors the bwrap helper now: random suffix, O_EXCL,
    0600).
  * **High** — `AgentWritableFile.read/1` had no size cap —
    closed by adding a default 10 MiB ceiling via
    `read_bounded/2` and routing all callers through it.
  * **High** — Task/project dashboard readers (project_live,
    overview_live, goals_live) were doing raw `File.read` on
    agent-RW paths — switched all to
    `AgentWritableFile.read_bounded(path, 1_048_576)`.
  * **Medium** — FrontmatterWriter.atomic_write predictable
    `tmp-<monotonic>` path (random suffix + exclusive open).
  * **Medium** — `mcp` synthetic-sender slug was scaffoldable
    as a real agent — added `@reserved_agent_slugs` block in
    both `Glorbo.CLI.Scaffold.Agent` and the
    `glorbo.create_agent` MCP tool.
  * **Medium** — Audit JSONL readers still slurping
    (`audit_live.load_tail/load_older`, `audit_export_controller`,
    `audit/query.for_task`, `mcp/tools/query_audit.read_month`)
    — all four switched to `File.stream!([], :line) +
    Enum.reduce` rolling-window pattern.
  * **Low** — `to_string/1` on agent-controlled metadata in
    overview_live + goals_live (`safe_scalar`/`safe_scalar_str`
    helpers refuse maps/lists).

**Codex re-scan #2 2026-04-25 22:00** (raw at
`.reports/codex-security-scan-2026-04-25-2200.md`) had surfaced 4
findings (1 high, 3 medium) all closed in **wave 22**:

  * **High — TaskDefinition.parse_file follows symlinks.**
    `read_file/1` did a bare `File.read/1` against an agent-RW
    `projects/*/tasks/*.md` path. A planted symlink could
    cross-company-leak task content via MCP / LiveView. Added
    a `:file.read_link_info` lstat gate; refuses non-regular
    shapes with `{:error, {:read_error, :not_regular_file}}`.
    Existing 10 MiB Frontmatter cap continues to enforce size.
  * **Medium — Search.scan_tasks follows symlinks.** Ctrl+K
    indexer used `File.stat` (follows links) + `File.read` on
    the same RW-mounted task tree. Switched to
    `:file.read_link_info` with a 1 MiB cap; non-regular /
    oversized files are skipped silently.
  * **Medium — Router task-materialise lstat→write race.**
    `perform_outbox_task_materialise/4` did
    `ensure_regular_file_lstat/1` then `File.write/3`,
    leaving a TOCTOU window for an attacker to swap the dest
    for a symlink. Replaced with `exclusive_write/2` —
    `:file.open([:exclusive])` opens with O_EXCL semantics so
    the check + write are one syscall.
  * **Medium — Actions.Tasks.write_task_file predictable
    tempfile.** `path.tmp-<monotonic_int>` was guessable; an
    attacker pre-planting a symlink at the next-integer name
    could redirect the host-side write. Same pattern as the
    earlier bwrap fix: 8-byte `crypto.strong_rand_bytes` suffix
    + `:file.open([:exclusive])`.

After wave 22 the re-scan finds no further new issues at HEAD
within the prompted scope. Full breakdown: 0 critical, 0 high,
0 medium, 0 low, 24 informational (plus 2 lows accepted by-design).

**Codex re-scan #4 2026-04-25 23:00** (raw at
`.reports/codex-security-scan-2026-04-25-2300.md`) plus a
project-wide grep for the predictable-`<> ".tmp"` pattern caught
**11 more findings** in **wave 24** (1 high, 3 medium, 1 low from
the codex output + 6 additional `<> ".tmp"` sites the grep
found):

  * **High** — `Actions.Attachments.ingest/6` could write
    through agent-planted project symlinks. Added
    `refuse_symlink_ancestors/1` (any-symlink-in-path walk) +
    leaf-lstat refuse-existing-non-regular guard.
  * **Medium** — TaskComments.append/4 lstat-then-append race;
    added ancestor-symlink check via
    `AgentWritableFile.any_symlink_in_path?/1`.
  * **Medium** — Activity.Rollup `to_string/1` on agent-
    authored YAML scalars (status, priority); switched to a
    safe-scalar helper that defaults non-scalars. Also routed
    the read through `read_bounded`.
  * **Medium** — Search.scan_tasks `to_string/1` on title +
    schedule fields; same safe-scalar helper.
  * **Low** — CLI harness `read_file` tool was unbounded;
    routed through `AgentWritableFile.read_bounded/2` (1 MiB
    cap) so a model can't pull host-readable secrets via the
    sandbox-visible path.
  * **6 grep-found sites** — `brain_dump.write_atomic/3`,
    `brain_dump` remove_section path, `config.atomic_write_secret!/2`,
    `Actions.Audit.do_scaffold/3`, `Router.atomic_write/2`,
    `Company.Goals.do_add_goal_write/5` — all switched from
    `<> ".tmp"` to `crypto.strong_rand_bytes(8)` suffix +
    `:file.open([:exclusive])`. Updated the H6 audit-test to
    reflect the new behaviour: a planted symlink at the OLD
    predictable path is irrelevant with random-suffix; the
    test now asserts scaffold succeeds (writing to a non-
    colliding random path).

**Codex re-scan #5 2026-04-25 23:30** (raw at
`.reports/codex-security-scan-2026-04-25-2330.md`) surfaced 5
more findings — 1 already-fixed (PathRequestGate sentinels, just
done in this wave) + 2 highs + 2 mediums. All closed in
**wave 25**:

  * **High** — DNS rebinding via Proxy.open_and_splice. Hostname
    allowlists were resolved at connect-time inside
    `:gen_tcp.connect/4`, so an attacker controlling DNS for an
    allowlisted host could return loopback/RFC1918/link-local
    and reach host-internal services. New `resolve_public_ip/1`
    pre-resolves A/AAAA, runs `public_ip?/1` against the result
    (rejects 0.0.0.0, 127/8, ::1, RFC1918, 169.254/16, fe80::/10,
    ULA fc00::/7, CGNAT 100.64/10), and connects to the vetted
    IP literal. New test `P10b` verifies loopback-via-allowlist
    is now refused with 403.
  * **High** — PathRequestGate sentinels predictable + unbounded.
    `state/path-pending-<task_id>-<seq>.md` was an attacker-
    guessable name in agent-RW state dir. Now uses
    `crypto.strong_rand_bytes(8)` suffix +
    `:file.open([:exclusive])` for the write, and
    `read_bounded(_, 64 KiB)` for sentinel parsing. Same fix
    applied to the inbox `path-request-denied-<task_id>-<ts>.md`
    notification path.
  * **Medium** — TaskScheduler reads task files unbounded. Both
    `scan_one/2` and `fire/3` switched from raw `File.read/1` to
    `AgentWritableFile.read_bounded(_, 1 MiB)`.
  * **Medium** — MCP `get_company_health` reads task md + audit
    files unbounded. `read_task_status/1` now uses
    `read_bounded(_, 1 MiB)` + `safe_status/1` scalar coercion;
    `last_line_timestamp/2` switched from `File.read +
    String.split + Enum.reverse` to `File.stream!([], :line) +
    Enum.reduce` (memory bounded by line length);
    `company_headcount_budget/1` uses `read_bounded`.
  * **Medium** — MCP `get_channel` slurped before applying limit.
    Switched to `AgentWritableFile.read_bounded(_, 5 MiB)` so
    a runaway channel write can't OOM MCP clients.

**Codex re-scan #6 2026-04-26 00:10** (raw at
`.reports/codex-security-scan-2026-04-26-0010.md`) surfaced 5
more findings — 2 highs + 2 mediums + 1 low. All closed in
**wave 26**:

  * **High** — Project-writable directory symlinks redirect host
    task writes across companies. An agent with
    `projects:write:<p>` could replace `projects/<p>/tasks` with
    a symlink and have outbox-routed tasks land in another
    company's tree. `Glorbo.Company.Router.handle_outbox_task/_`
    now refuses symlinked ancestors before `mkdir_p` /
    `exclusive_write`. Same guard added to
    `Glorbo.Actions.Tasks.do_next_task_id/3` (director-side
    create) and `build_trash_dest/4` (soft-delete rename).
  * **High** — IPv4-mapped IPv6 addresses bypass Proxy private-
    address filtering. The wave-25 `public_ip?/1` IPv6 catch-all
    treated `::ffff:127.0.0.1` as public. New clauses extract
    the embedded IPv4 octets from `::ffff:a.b.c.d` and
    `::a.b.c.d` and recheck against the IPv4 ruleset.
  * **Medium** — `Glorbo.TaskDefinition.read_file/1` slurped
    full agent-RW task files before `Frontmatter.parse/1`
    capped at 10 MiB. Now routed through
    `AgentWritableFile.read/1`; the bounded reader's
    `:file_too_large` is mapped back to `:size_limit_exceeded`
    so the public error taxonomy is unchanged. Same fix in
    `Glorbo.Actions.wake_task_assignee/7`.
  * **Medium** — Path-request archive followed agent-controlled
    state symlinks. `Glorbo.PathRequestGate.archive_request/3`
    walked into `agents/<slug>/state/path-request-archive` via
    plain `mkdir_p`/`File.rename`. Now lstat-refuses symlinked
    ancestors first.
  * **Low** — `Glorbo.Agent.Parser.validate_models_aliases/1`
    and `parse_host_list/2` raised `Protocol.UndefinedError` on
    nested-map YAML (e.g. `models: {fast: {nested: true}}`) via
    `to_string/1`. Now refuse non-binary keys/values up front
    and return structured `:invalid_models_aliases` /
    `:invalid_egress_host` errors.

**Codex re-scan #7 2026-04-26 00:19** (raw at
`.reports/codex-security-scan-2026-04-26-0019.md`) surfaced 6
more findings — 0 highs + 3 mediums + 3 lows. All closed in
**wave 27** (proxy-token attribution finding deferred — see
"Accepted risks" below):

  * **Medium** — `Glorbo.Actions.Agents` workspace writers had a
    lstat→write TOCTOU. `create_workspace_file/4` now uses
    O_EXCL create; `write_workspace_file/4` writes through a
    random-suffix exclusive temp + atomic rename;
    `trash_workspace_file/3` refuses symlinked
    `agents/<slug>/history/deleted` ancestors before mkdir_p.
  * **Medium** — Inbox delivery and `@mention` writes did not
    refuse symlinked ancestors. Added
    `any_symlink_in_path?/1` guards to
    `Glorbo.Actions.write_mention/8`,
    `Glorbo.Actions.Inbox.deliver_task_assignment/6`,
    `Glorbo.Company.Router.perform_routing({:agent, _}, …)` /
    `do_write_mention/4`, and
    `Glorbo.PathRequestGate.notify_agent_denied/3`. Each path
    either rejects with a tagged error or silently skips
    (durability is preserved upstream).
  * **Medium** — `Glorbo.Search.scan_audit/2` slurped each
    monthly audit JSONL into BEAM memory before applying the
    500-row limit. Switched to `File.stream!([], :line) +
    rolling-window reduce`; lstat-gates and rescues IO errors
    silently (search must remain noiseless on missing data).
  * **Low** — `Glorbo.Company.Proposals.read_one/1`,
    `Glorbo_web.MCP.Tools.GetProposal`, and
    `ListProposals.load/2` used raw `File.read/1` on the agent-
    RW `proposals/` tree. Routed through
    `AgentWritableFile.read/1` so symlinks are refused and
    bodies are capped at 10 MiB.
  * **Low** — `Glorbo.Chat.Rotation` used a predictable
    `<channel>.md.rotate.tmp` and `mkdir_p!` on
    `archive/<channel>/`. Now refuses symlinked ancestors for
    both archive and live paths and uses random-suffix
    exclusive open for the temp.

Deferred:
  * **Low** — Proxy token plumbing breaks egress attribution
    (`agent/dispatch.ex:521`, `sandbox/bwrap.ex:785`,
    `cli/harness/http.ex:123`). This is an attribution
    accuracy gap, not an exploit primitive. Tracked as a non-
    security follow-up; see issue notes.

**Wave 28** 2026-04-26 ~02:20 (no codex scan — both v8 and
v8b hung past 30 min and were killed; closure driven by a
manual sweep instead). Three defense-in-depth hardenings:

  * **Medium** — `Glorbo.Actions.Reviews.atomic_write/2` and
    `Glorbo.FileSpec.Formatter.atomic_write/2` both used
    `path <> ".tmp." <> Integer.to_string(unique_integer)` —
    attacker-plantable as a symlink in agent-RW directories.
    `Reviews` writes peer-review request sentinels into
    `agents/<reviewer>/inbox/`; `Formatter` operates on
    agent-RW project / agent.md files. Both switched to
    `crypto.strong_rand_bytes(8)` random suffix +
    `:file.open([:exclusive])` — the canonical wave-22+ pattern.
  * **Low** — `lib/glorbo_web/router.ex` `:browser` pipeline now
    sets a Content-Security-Policy header via the
    `put_secure_browser_headers` map argument:
    `default-src 'self'; script-src 'self'; style-src 'self'
    'unsafe-inline' cdnjs.cloudflare.com; font-src 'self'
    cdnjs.cloudflare.com data:; img-src 'self' data:;
    connect-src 'self'; frame-ancestors 'none'; base-uri
    'self'; form-action 'self'`. Defense-in-depth on top of
    `HtmlSanitizeEx` for agent-rendered chat / task content;
    blocks external-script-load XSS vectors. `unsafe-inline`
    retained for HEEx-inlined styles — known gap, can tighten
    later via CSP nonce.
  * **Low** — `Glorbo.CLI.Scaffold.Skill.scaffold_default/3`
    and `scaffold_from_template/4` walked into
    `companies/<co>/skills/` via plain `mkdir_p!`. Per GEP-22
    the skills dir is RW for agents holding `skills:install`,
    so an agent compromise could plant a `skills ->
    ../../audit` symlink and have Director-side scaffolds land
    elsewhere. Now refuses symlinked ancestors first.

**Wave 28 follow-up** 2026-04-26 ~02:50 (continuing the manual
sweep after the codex scans were abandoned):

  * **Low** — `Glorbo.Backup.write_archive/2` `tmp = output <>
    ".tmp." <> Integer.to_string(unique_integer)`. Backup
    tarballs include `config.md` (carries
    `secret_key_base`); the predictable temp name in a user-
    chosen output dir (e.g. `/tmp` on a shared box) was
    attacker-plantable as a symlink before the chmod 0o600
    + rename gate locked the file private. `:erl_tar.create/3`
    doesn't expose O_EXCL, so the 8-byte random suffix
    is the load-bearing defense.

Cumulative tally: **100 security findings closed across 34
waves** — 39 from the 2026-04-22 import + 4 wave 22 + 15 wave 23
+ 11 wave 24 + 11 wave 25 + 5 wave 26 + 5 wave 27 + 4 wave 28
+ 1 wave 29 + 1 wave 30 + 1 wave 31 + 1 wave 32 + 1 wave 33
+ 1 wave 34.
Two findings remain accepted-by-design (plus the wave-27
proxy-token attribution gap deferred as non-security).

### Wave 29 closure (post-v0.12.0 self-review, 2026-04-26)

Found by reviewing the GEP-34 reindex code I just shipped in
v0.12.0 — the audit-dir walks in `Reindex.rebuild_audit_events/1`,
`rebuild_tasks_approval_state/1`, and `rebuild_budgets/1` were
calling `File.dir?/1` on `companies/<co>/audit/` and
`<base>/audit/_system/` without lstat'ing first. `File.dir?`
follows symlinks, so an agent that planted a symlink at
`companies/<co>/audit/` (kernel sandbox prevents this today,
but defense-in-depth at the application layer should mirror
the kernel boundary) could redirect the reindex walk into an
arbitrary directory. The reader skips malformed JSON, but
attacker-controlled valid JSON-Lines would be imported into
the SQLite mirror with attacker-chosen `actor`/`action`/
`target` values. Closed by introducing a single
`safe_audit_dir/1` helper that calls
`AgentWritableFile.any_symlink_in_path?/1` (same pattern as
`safe_markdown_files/1` already uses for the markdown walk)
and routing all three call sites through it. 2 new tests in
`reindex_test.exs` confirm that a symlinked
`companies/<co>/audit/` AND a symlinked `<base>/audit/_system/`
both result in zero rows imported across all three projections.
*Paths:* `lib/glorbo/filesystem/reindex.ex,
test/glorbo/filesystem/reindex_test.exs`.

### Wave 34 closure (post-v0.12.4 cross-area review, 2026-04-26)

**Low severity — alert filename vs frontmatter mismatch in
`Company.BudgetTracker.parse_alert_key/2`.**

Adjacent-area review after the GEP-34 reindex closures (waves
29-33) found the same dirname-vs-content discipline gap in
`BudgetTracker.rehydrate_alerts_fired/2`. The function reads
`<base>/companies/<co>/alerts/*.md` files and extracts the
agent slug from the frontmatter `agent:` field. The writer
(`do_write_alert_file/5`) names the file `<agent>-budget.md`
AND puts `agent: "<agent_slug>"` in frontmatter — they always
match in production. But on a hand-edited alert file (operator
tampering or path-grant misconfiguration) the two could
disagree.

If the disagreement happens, the MapSet of fired alerts gets
the wrong key. An attacker writing `editor-budget.md` with
`agent: "ceo"` in frontmatter could silently suppress ceo's
real alert for that month — when ceo legitimately crosses the
threshold, the tracker sees `{ceo, <month>}` already in the
fired set and skips the alert.

Severity Low: agents are bwrap-prevented from writing to
`alerts/`, so the threat surface is operator-only.

Closed by inverting the parse priority: filename is now
canonical (`agent_from_alert_filename/1` extracts the prefix
of `<agent>-budget.md`), and the frontmatter is read only for
the `month:` field. Same dirname-canonical discipline as
waves 31-33 in the GEP-34 reindex paths — the lesson
generalized.

1 new test: tampered alert file (filename `editor-budget.md`,
frontmatter `agent: "ceo"`) → MapSet contains `{editor,
<month>}`, NOT `{ceo, <month>}`.
*Paths:* `lib/glorbo/company/budget_tracker.ex,
test/glorbo/company/budget_tracker_test.exs`.

### Wave 33 closure (post-v0.12.3 self-review, 2026-04-26)

**Medium severity — JSONL `company:` spoof remained open in
Phase 1 (`audit_events`) after wave 32.**

Fifth self-review of the GEP-34 reindex code (after wave 32).
Wave 32 closed the cross-company spoofing path for Phase 2 +
Phase 3 by introducing `dirname_company_slug/1`, but left
Phase 1 on the wave-30 lenient `safe_company_slug/2` with the
rationale "audit_events legitimately stores cross-routed
events." On reflection, that argument applied only to the
writer side: `Company.AuditLog.entry_company/1` uses the JSONL
field to ROUTE the event to the correct dir at write time. By
the time the reader iterates `companies/<co>/audit/`, the
dirname IS the canonical company; accepting a JSONL `company:`
override still let an attacker who could write into one
company's audit dir pollute another company's audit feed in
the dashboard.

Closed by introducing `audit_company_slug/1` and routing
`build_audit_row/2` through it. The dirname is now canonical
for Phase 1 too, with `_system` allowance for the system audit
dir (`<base>/audit/_system/` has dirname == "_system" already).
`safe_company_slug/2` is removed (no remaining callers); the
moduledoc-style comment block traces the wave 30 → 32 → 33
evolution for future readers.

1 new test in Phase 1's section: an attacker-crafted line in
acme's audit dir with `company: "beta"` lands as a row
attributed to acme, not beta.

This closes the JSONL-`company:`-field-spoof attack surface
across all three GEP-34 projections in a unified way; every
phase now derives the row's company from its on-disk
location.
*Paths:* `lib/glorbo/filesystem/reindex.ex,
test/glorbo/filesystem/reindex_test.exs`.

### Wave 32 closure (post-v0.12.2 self-review, 2026-04-26)

**Medium severity — cross-company spoofing via JSONL `company:`
field in approval/budget replay.**

Fourth self-review of the GEP-34 reindex code (after wave 31
shipped) found that wave 30's `safe_company_slug/2` helper
preferred the JSONL `company:` field over the dirname when the
JSONL field was a valid slug. Wave 31 added the `company_slug`
column to `tasks_approval_state` and made the schema enforce
`(company_slug, task_path)` uniqueness — but the FOLD that
populated `company_slug` was using `safe_company_slug`, which
let a JSONL line in `companies/acme/audit/` set `company:
"beta"` and synthesize a row attributed to beta.

Defeats wave 31's isolation guarantee. An attacker who could
write a single line into one company's audit JSONL (operator
path-grant misconfiguration, hand-edited backup restore, agent
escape that reaches the audit dir, etc.) could spawn rows in
arbitrary other companies' approval/budget projections.

Closed by introducing `dirname_company_slug/1` which validates
the iteration's on-disk company dirname only and ignores the
JSONL `company:` field. Routed Phase 2 (`apply_approval_event`,
`update_resolution`) and Phase 3 (`apply_budget_usage`) through
it. Phase 1 (`build_audit_row`) keeps the wave-30 helper
because `audit_events` stores cross-routed events the writer
intentionally tags via `Company.AuditLog.entry_company/1`.

2 new tests:
  * Phase 2: line in acme's audit dir with `company: "beta"`
    → row attributed to acme.
  * Phase 3: line in acme's audit dir with `company: "beta"`
    → row attributed to acme.

Plus an updated wave-30 test ("traversal-shaped `company:` is
ignored") whose semantics shifted from "non-slug falls back to
dirname" to "JSONL field is ignored regardless of shape" —
same on-the-wire behaviour, clearer intent.
*Paths:* `lib/glorbo/filesystem/reindex.ex,
test/glorbo/filesystem/reindex_test.exs`.

### Wave 31 closure (post-v0.12.1 self-review, 2026-04-26)

**Medium severity — cross-company bleed in `tasks_approval_state`.**
Third self-review of the GEP-34 reindex code surfaced a
load-bearing invariant violation that long predated v0.12.0:
the `tasks_approval_state` schema had a unique index on
`task_path` alone, with no `company_slug` column. If two
companies had awaiting tasks at the same relative path,
`Approvals.Gate.upsert_awaiting` (with
`conflict_target: [:task_path]` + `on_conflict: :nothing`)
silently no-op'd the second insert; `find_awaiting_row(state,
task_path)` returned the wrong company's row. Director
clicking "approve" on the wrong company's dashboard would
flip the *other* company's task state.

Violates CLAUDE.md "Company isolation is absolute" — the
invariant the security model relies on. Pre-v0.12.0 the
silent no-op would have been masked by the absence of a
JSONL-replay path; v0.12.0's GEP-34 Phase 2 made the bug
observable across reindex roundtrips.

Closed by migration `20260426170000`: drop the table, recreate
with `company_slug NOT NULL` and a composite
`(company_slug, task_path)` unique index. SQLite doesn't
support ALTER COLUMN to make an added column NOT NULL after
backfill, so drop+recreate is the correct path; pre-fix rows
are wiped — `glorbo reindex` regenerates the table from
on-disk audit JSONL via the GEP-34 Phase 2 fold (which now
keys by `{company, task_path}`).

Three Gate write paths updated: `upsert_awaiting`,
`upsert_resolved`, `find_awaiting_row` all carry
`company_slug` from `state.company`. Reindex Phase 2 plumbs
company through `apply_approval_event/4` + `update_resolution/6`.
2 new isolation tests (gate-side + reindex-side) confirm
that two companies with the same relative path yield two
isolated rows.
*Paths:* `priv/repo/migrations/20260426170000_scope_tasks_
approval_state_by_company.exs, lib/glorbo/tasks_approval_
state.ex, lib/glorbo/approvals/gate.ex, lib/glorbo/filesystem/
reindex.ex, test/glorbo/tasks_approval_state_test.exs,
test/glorbo/approvals/gate_test.exs, test/glorbo/filesystem/
reindex_test.exs`.

### Wave 30 closure (post-v0.12.0 self-review, 2026-04-26)

Second self-review pass on the GEP-34 reindex code. The writer
side (`Company.AuditLog.entry_company/1`) validates JSONL
`company:` fields against the canonical slug regex, falling
back to the `_system` bucket on garbage. The replay side did
not — Phase 1/2/3 inserted whatever JSONL claimed verbatim
into `audit_events.company`,
`tasks_approval_state.agent_slug`, and
`budgets.{company_slug,agent_slug}`. Hand-edited or
backup-restored JSONL with `company: "../../etc"` or
`agent: "../etc"` would write garbage cell values used later
by lookup queries (`find_awaiting_row` / budget scoping). No
SQL injection — `Repo.insert_all` parameterizes — but the
column data was untrusted.
Closed by introducing two helpers in `Reindex` that mirror
the writer-side discipline: `safe_company_slug/2` validates
the JSONL `company:` against `Actions.Support.valid_slug?/1`
and falls back to the on-disk dirname (allows `_system`);
`safe_agent_slug/1` returns nil on non-slug input so callers
skip the row. Phase 3 additionally rejects `company:
"_system"` because budget events are strictly per-company.
6 new tests cover bad-`company`-fallback, non-slug-`agent`-skip
across all three projections, granted-resolution synthesis
with bad agent, and the `_system` rejection.
*Paths:* `lib/glorbo/filesystem/reindex.ex,
test/glorbo/filesystem/reindex_test.exs`.

Format per row: **title** — short gist. *Paths:* touched files.
See `git log -- docs/testing/threatmodel.md` for the raw Codex import (with per-finding URLs) and the wave-1/2/3 closure log.

### Medium (constrained exploit — local access or misconfig) — 0

### Low (defense-in-depth / bounded DoS / integrity gaps) — 0


### Accepted risks (by-design / out-of-scope for v1) — 2

These findings are documented as deliberate trade-offs rather
than open lows. Re-evaluate during the v1 cut.

- **Stdout-streamer dispatch/exit marker spoofing**.
  StdoutStreamer regex-classifies stdout lines as `:header` /
  `:exit` / `:body`. An attacker-controlled agent can emit
  literal `=== glorbo dispatch <ts> ===` / `=== exit 0 ===`
  lines mid-output, which the LV renders as styled dispatch
  cards. Impact is purely cosmetic — the audit log's
  `agent.complete` event carries the authoritative exit_status,
  and KanbanLive / TaskLive surface the audit-derived state.
  A true fix requires UI-side cross-reference between the
  marker stream and audit events; deferred to the GEP-37 shell
  redesign which already has a stronger event-bus boundary.
  *Paths:* `lib/glorbo_web/stdout_streamer.ex,
  lib/glorbo_web/components/stdout_tail.ex`.

- **Release boot check `validate_compile_env: false`**.
  `mix.exs:113-124` documents this as a deliberate trade-off —
  the LV / endpoint compile-env keys (code_reloader,
  debug_errors, force_ssl, enable_expensive_runtime_checks)
  aren't load-bearing at runtime, and the validator was
  emitting confusing "compile-time vs runtime" errors against
  Burrito-cached releases when _build/ contained any non-prod
  compile artefacts. CI always builds with `MIX_ENV: prod`
  (.github/workflows/ci.yml), so the dev-flag-leak path the
  finding describes can't actually occur in shipped artefacts.
  *Paths:* `mix.exs, config/dev.exs`.

### Informational (correctness / UX — not a direct security gap) — 24

- ~~**TaskComments parse swaps capture order**~~ — Closed
  wave 19 (verified: `Regex.scan(:all_names)` returns
  alphabetical capture order, matching `[author, body, ts]`).
- ~~**Overview goals parsing crashes on non-string goal slug**~~ —
  Closed in wave 15 (verified `safe_goal_slug/1` already filters
  non-scalar values).
  *Paths:* `lib/glorbo_web/live/overview_live.ex`
- ~~**Proxy classifier lacks validation**~~ — Closed wave 18:
  `safe_classify/3` already validates verdict tuples via
  `normalise_classifier_result/1`.
- ~~**SmartClassifier allows private IPs when allowlisted**~~ —
  Closed wave 18: rule order has `private_ip?/1` BEFORE the
  allowlist check.
  *Paths:* `lib/glorbo/network/smart_classifier.ex`
- ~~**Task assignment kind change breaks agent reply routing**~~ —
  Closed wave 18: `reply_target/1` + `format_reply_hint/1` now
  recognise both the legacy `kind: task_assignment` envelope and
  the current `kind: inbox-message/v1, subkind: task_assignment`.
  *Paths:* `lib/glorbo_web/live/kanban_live.ex, lib/glorbo/agent/server.ex`
- ~~**NL schedule parser ignores 'every weekday at <time>'**~~ —
  Closed wave 19: `parse_weekday_bucket/4` parses the optional
  `at <time>` suffix.
  *Paths:* `lib/glorbo/schedule_nl.ex`
- ~~**Invalid schedule stash drops timer_ref**~~ — Closed wave 20:
  `maybe_emit_invalid/5` cancels the prior timer_ref.
  *Paths:* `lib/glorbo/company/task_scheduler.ex`
- ~~**Task budget audit ignores task-level provider override**~~ —
  Closed wave 21 (verified: M10 enforcement at
  `Dispatch.reconcile_task_provider/2` pins task.provider
  mismatches to spec.provider, so the cost computation always
  matches the provider that ran).
  *Paths:* `lib/glorbo/agent/dispatch.ex`
- ~~**Costs ledger merges across companies**~~ — Closed wave 19
  (verified: history_for_agents/1 keys by `{company, agent}`).
- ~~**NL heartbeat parsing crashes on `every 9am`**~~ — Closed
  wave 19 (verified: split_rest handles trailing-nil captures).
  *Paths:* `lib/glorbo/schedule/nl.ex, lib/glorbo/agent/parser.ex`
- **Model alias parsing crashes on non-string YAML values** — The added model alias support converts each alias key/value with `to_string/1` without guarding against values that lack the String.Chars protocol (e.g., nested maps or lists of strings in YAML). When such a malformed `models:` block is parsed, `to_string/1`…
  *Paths:* `lib/glorbo/agent/parser.ex`
- **AgentLive config form writes unsupported network value** — `config_save` now writes the network field from the form directly into AGENT.md. The form only offers `none` and `outgoing`, yet `Glorbo.Agent.Parser` only recognizes `none`, `api-only`, and `open`. If a director saves the form, the file is updated with an…
  *Paths:* `lib/glorbo_web/live/agent_live.ex, lib/glorbo/agent/parser.ex`
- **Hot-reload ignores legacy agent.md causing stale specs** — Agent.Server now triggers a reload for both AGENT.md and agent.md edits, but maybe_reload_spec hardcodes the canonical AGENT.md path. On installations that still only have agent.md, the reload attempt reads a non-existent file and keeps the old spec. This…
  *Paths:* `lib/glorbo/agent/server.ex`
- **Workspace ignore rule skips reindex for agent slug "workspace** — The commit adds a classify/1 rule that ignores any path under "agents/" containing the substring "/workspace/". This is intended to skip the agent workspace directory, but it also matches all paths for an agent whose slug is exactly "workspace" (e.g.,…
  *Paths:* `lib/glorbo/filesystem/watcher.ex`
- **Approval reassignment writes task files without symlink checks** — The commit adds reassign_task/3 calls during approval request and grant. reassign_task builds an absolute path from task_path and calls TaskDefinition.write without validating that the target is a regular file or rejecting symlinks. An agent with tasks:update…
  *Paths:* `lib/glorbo/approvals/gate.ex, lib/glorbo/task_definition.ex`
- **Dashboard now accepts underscore slugs but routing rejects them** — This commit updates the client-side slug pattern for new agents to allow underscores and require a leading letter. However, the LiveView routing guard still uses GlorboWeb.Slug.valid?/1, which only allows [a-z0-9-]+. As a result, agents created with…
  *Paths:* `lib/glorbo_web/live/company_live.ex, lib/glorbo_web/slug.ex, lib/glorbo_web/live/agent_live.ex`
- **Company dashboard crashes when CLI registry is unavailable** — CompanyLive now calls provider_options() at mount time to populate the new-agent provider dropdown. provider_options/0 calls CLIRegistry.list/0 and rescues only exceptions. CLIRegistry.list/0 uses Agent.get/2; when the registry process is not running (e.g.,…
  *Paths:* `lib/glorbo_web/live/company_live.ex, lib/glorbo/cli/registry.ex`
- **Heartbeat inbox scans now skip drain/reply due to trigger tagging** — The commit threads the wake trigger into inbox scans and stores it in the task map. For heartbeat wakes, this now produces tasks with trigger=:heartbeat instead of :inbox. Downstream logic only routes replies and drains inbox files for :inbox or :mention…
  *Paths:* `lib/glorbo/agent/server.ex`
- **AuditLive realtime append leaves pagination offset stale** — AuditLive now handles {:audit_append, record} by appending to the in-memory tail and incrementing total_lines, but it never updates offset or beginning. When the tail is capped to 500 entries, the oldest entry is dropped and the offset should be incremented;…
  *Paths:* `lib/glorbo_web/live/audit_live.ex`
- **Kanban editor YAML writer fails to escape backslashes** — The save_task handler now takes raw user input (title/assigned_to/priority/etc.) and writes it via TaskDefinition.write_frontmatter. That writer constructs YAML lines with yaml_scalar, but yaml_scalar only escapes double quotes and leaves backslashes…
  *Paths:* `lib/glorbo_web/live/kanban_live.ex, lib/glorbo/task_definition.ex`
- **Unbounded parallel version probes allow local DoS** — The new detection module runs version probes in parallel using Task.async_stream with max_concurrency set to the full provider list length. The provider list is loaded directly from ~/.glorbo/providers.toml without any cap, so a locally writable providers…
  *Paths:* `lib/glorbo/cli/registry/detection.ex, lib/glorbo/cli/registry/loader.ex`
- **GEP validator crashes on non-numeric frontmatter values** — Gep.Validator normalizes numeric frontmatter fields (gep, requires, supersedes, superseded-by, extended-by, see-also) by calling String.to_integer/1 on any binary value. If a GEP file contains a non-numeric string (e.g., "GEP-0001" or "foo") in one of these…
  *Paths:* `lib/gep/validator.ex`
- **Inotify follow can skip log bytes during concurrent writes** — Glorbo.CLI.Logs.handle_modification/3 reads from the previous size to EOF, then sets the next offset using a second File.stat!/1. If the log grows between the read and that stat, last_size jumps past unread bytes. Subsequent events see new_size <= last_size…
  *Paths:* `lib/glorbo/cli/logs.ex`
- **TaskDefinition prefix check allows traversal outside company** — `relative_task_path/3` trusts `String.starts_with?/2` on the raw `file_path` to decide if a task lives under the target company. Because the path is not normalized or resolved, an attacker who can influence the task path (or place a symlink in the tasks…
  *Paths:* `lib/glorbo/task_definition.ex`
