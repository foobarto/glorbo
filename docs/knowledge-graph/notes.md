# Knowledge notes — Glorbo

Living document. Where `GRAPH_REPORT.md` is machine-generated
(graphify AST + clustering), this file is **hand-curated tacit
knowledge**: findings, gotchas, false-positive patterns, mental
models, and "things I learned that were non-obvious". Updated
whenever a session uncovers something worth preserving for the
next session's Claude (or human).

**Write here when you discover:**

- A graph signal that looks surprising but is actually benign (or
  the reverse — a flag that turned out to be a real bug).
- An invariant that spans several modules and isn't obvious from
  any single file.
- A non-trivial call chain that took time to untangle — leave a
  breadcrumb so the next session doesn't retrace.
- A dependency / tool behaviour that's easy to get wrong (bwrap,
  burrito, ecto_sqlite3 quirks, etc.).
- Anything a teammate would ask about in a code review.

**Keep entries short.** One paragraph per fact, dated. When an
entry becomes stale, update or remove it — this isn't a changelog,
it's a working memory.

---

## 2026-04-22 — Initial graph analysis (post wave c.2)

### Graph caveats (tree-sitter false positives)

The knowledge graph was built with
`graphify update lib` on the 220-file `lib/` tree (2478 nodes, 4478
edges, 103 communities, 81% EXTRACTED / 19% INFERRED). Signal
quality is good BUT:

- **Generic function names are not abstractions.** `parse()` shows
  up as the #2 god node (93 edges) — it's `Frontmatter.parse`,
  `TaskDefinition.parse_file`, `Agent.Parser.parse_file`,
  `Glorbo.CLI.Parsers.*.parse` and more, all collapsed into one
  node because tree-sitter doesn't qualify by module. Same for
  `get()`, `map()`, `lookup()`, `run()`, `inspect()`, `warning()`.
  Don't reason from these — they're name-space bleed.
- **Confirmed false-positive inferred edge:**
  `ProposalsSink.resolve_audit_server → PathGrantStore.lookup`.
  The real code calls `Elixir.Registry.lookup/2`. Generalizes:
  any INFERRED edge crossing subsystem boundaries (e.g.
  ProposalsSink into PathGrantStore) deserves a grep before you
  trust it.
- **Corpus scope matters.** Running `graphify update .` includes
  `deps/` and `_build/` and produces a ~22k-node graph dominated
  by SQLite C functions and Phoenix.LiveView internals. Always
  scope to `lib/` (or `lib/` + `test/support/` if tests are in
  scope for the question).

### Load-bearing utility: `default_root/0`

`Glorbo.Filesystem.Hierarchy.default_root/0` (74 edges, bridges 27
communities) is the entry point for every filesystem-touching
module. If you ever change its behaviour (env var lookup, default
path), the blast radius is the whole codebase. Treat it as a
public API even though it's a plain function.

### FileSpec modules flagged as "thin communities"

15+ `Glorbo.FileSpec.*Md` modules each form their own 6-node
cluster. The graph flags each as a "thin community - may be noise
or needs more connections." That's **by design** — the GEP-25
pattern is "each spec is independent; implements the FileSpec
behaviour via 5 callbacks." Not a refactoring opportunity.

### Isolated top-level modules (non-issue)

`Glorbo`, `Glorbo.Repo`, `Glorbo.Company`, `Glorbo.AuditEvent`,
`Glorbo.Agent` show as isolated nodes (≤1 connection). They're
thin namespace shells. Non-issue unless one of them starts
accumulating behaviour.

### Architectural hot-spots worth knowing

- **`Glorbo.Company.Router` (96 edges, #1)** — policy enforcement
  choke point. Every agent mutation goes through it. If you see a
  new write path that bypasses it, *that's a design bug*
  (GEP-5 / GEP-19 / GEP-28).
- **ACL + Router in Community 3** — Router and `ACLMapper` cluster
  together. Consistent with the kernel-is-the-policy-engine
  invariant from GEP-5.
- **MCP tools in Community 0** — wave c.1 + c.2 write tools
  (ApproveTask, CaptureBrainDump, etc.) form a 72-node community.
  Good cohesion. Don't let that cluster start pulling in
  dashboard internals; it should stay thin.

---

## Session rhythm — graphify + this notes file

1. **Session start (new feature):**
   `graphify update lib` — rebuild. Then skim `GRAPH_REPORT.md`
   and this file for anything relevant to the task.
2. **Mid-session / post-compaction:**
   `graphify query "<current task>"` — bounded 2k-token answer
   instead of rereading 20 files.
3. **Before ending a session that touched non-trivial code:**
   - `graphify update lib && mv lib/graphify-out/GRAPH_REPORT.md
     docs/knowledge-graph/ && rm -rf lib/graphify-out`
   - Append any new learning to this file under today's date
     heading (append — don't rewrite old entries).
4. **Stale entries:** rather than delete, annotate with a
   superseding note. History tells future Claude how a belief
   evolved.

---

## 2026-04-22 — Wave (e) finding: MCP version negotiation is two-sided

Learned while wiring `MCP-Protocol-Version` header validation
(GEP-29 wave e). The MCP lifecycle has **two** version hooks that
must agree, not one:

1. Transport-level: `MCP-Protocol-Version` HTTP header on every
   request after `initialize` (spec §"Protocol Version Header").
2. Lifecycle-level: `initialize.params.protocolVersion` in the
   JSON body, which the server MUST echo back in the response so
   the client can confirm the negotiated version.

Adding the header validator without also making the `initialize`
reply echo the client's requested version (when supported) breaks
negotiation for older clients: they send `2025-03-26` in the
body, the server validates their later `MCP-Protocol-Version:
2025-03-26` header as supported, but the `initialize` response
comes back as `2025-06-18` (our internal latest). Client sees a
version mismatch and disconnects.

**Fix:** `Server.handle_initialize/1` now reads
`params["protocolVersion"]` and echoes it back if it's in
`@supported_protocol_versions`; otherwise falls back to
`@protocol_version`. Codex caught this in review — would've
slipped through otherwise because all existing tests had
clients requesting the current version.

Takeaway for the next time we add spec-compliance features:
check for *pairs* of hooks. Transport-layer handshake + payload-
layer negotiation are frequently linked in network protocols,
and each half is independently testable but needs the other to
actually work.

## How to use `graphify query` effectively

- Phrase questions in graph-y terms: "where is X defined?",
  "what calls Y?", "which modules bridge A and B?". The query
  engine does BFS traversal; it's literal.
- Cap budget with `--budget 1500` for cheap queries; default 2000
  is fine for exploration.
- When a query returns less than you expect, the graph may be
  stale — rebuild with `graphify update lib`.
- For "explain this module" use
  `graphify explain "Glorbo.Company.Router"` — denser than a
  query and better anchored on one node.

---

## 2026-04-22 — threatmodel waves 2 + 3 gotchas

Three security waves in one session closed 30 findings from the
Codex scan. A few load-bearing patterns worth keeping in mind:

- **Agent-writable → lstat or die.** Anything under
  `agents/<slug>/{outbox,workspace,state,memory}` is
  agent-controlled. Before `File.read` / `File.write` /
  `File.rename` on a path inside that tree (or *derived from a
  file inside that tree* — M02/M11 sentinel `task_path` is the
  canonical example), the caller must `File.lstat` and refuse
  anything that isn't a regular file or `:enoent`. We now have
  `ensure_regular_file/1`-style helpers in at least 7 modules;
  when adding a new write path inside an agent-writable tree,
  reach for lstat first.
- **ACL check lives at the Router, not the outbox scanner.**
  `handle_outbox_comment/4` (M14) was the exception that proved
  the rule — it bypassed `ACLMapper.check_action/2` because the
  author thought "it's just appending to a task, not creating
  one". Every outbox classifier branch in `Company.Router` must
  check permissions before writing. When adding a new outbox
  subkind, search existing `ACLMapper.check_action` call sites
  and mirror the pattern.
- **Default network is `:none`, not `:proxy`.** M16 flipped the
  `validate_network/1` default because `:proxy` is advisory
  until GEP-31 lands netns+pasta enforcement. Templates that
  need egress set `network: proxy` explicitly. CLI-backed
  templates (claude-code, codex, gemini, opencode) + editor /
  researcher / provenance-auditor / ceo / critiqueops already
  declare it.
- **Task frontmatter is agent-authored — provider overrides are
  an escalation vector.** M10: `task.provider` cannot pin a
  different provider than the agent's spec, because doing so
  would swap in that provider's `auth_binds` (which may mount
  host secrets). `reconcile_task_provider/2` enforces equality.
  Same pattern to consider for any future per-task override that
  touches bwrap mount flags.
- **Command palette is a stored-XSS magnet.** M06/M25:
  `assets/js/app.js` `paletteHtml` + `renderList` use `innerHTML`
  with escaped interpolations (`escapeHtml/1`). Any new palette
  source — search hits from a new API, recent items, etc. —
  must flow through `escapeHtml` for label/hint/href. Task
  titles and audit fields are agent-authored.
- **Sentinel path regex is the isolation boundary for
  loop-detector.** `@sentinel_task_path_re` in LoopDetector +
  `@sentinel_path_re` in TaskLive + InboxLive — three copies of
  the same regex. If you edit one, edit all three (or extract
  to a shared module; intentionally not done yet because the
  regex is small and divergence is flagged loudly by negative
  tests).

---

## 2026-04-23 — threatmodel waves 4 + 5 + GEP-32

### Approvals.Gate invariant — Director writes MUST mark first

`Glorbo.Approvals.Gate` keeps a short-lived `director_pending` map
(10 s TTL) of task_paths that the Director has just flipped through
`GlorboWeb.Actions.set_approval`. The watcher-driven resolver
consults this before advancing an awaiting row to approved/denied
— **unmarked transitions are treated as agent self-approval
attempts, reverted to `awaiting`, and audited as
`approval.self_approval_rejected`**.

Call-site rule: any new code path that writes `status: approved` /
`status: denied` to a task file **must** call
`Glorbo.Approvals.Gate.mark_director_decision/2` first. This
includes tests — `test/support/gate_helpers.ex`
`resolve_approval/3` marks automatically; bare
`send(pid, {:file_event, ...})` does not.

Why it exists: wave 4 threatmodel row 16 — `tasks:update`
permission grants rwx on `projects/<scope>/tasks`, so an agent can
edit its own task frontmatter. Before this gate, the file-watcher
resolver trusted `status: approved` regardless of who wrote it.

### `File.lstat` vs `File.stat` — consistent discipline across all
write-path seams

Wave 4 added two more lstat guards on the host-write seams of
agent-reachable files:

- `Glorbo.CLI.Dispatcher.read_reply/3` — lstat the reply path
  before `fs.stat/fs.read`; refuse non-regular.
- `Glorbo.TaskDefinition.write/atomic_write` — lstat the target
  AND the `<file>.tmp` side before write; refuse non-regular on
  either.

Plus wave 5:

- `GlorboWeb.KanbanLive.list_projects` — lstat replaces `File.dir?`
  (which follows symlinks) when enumerating the project picker.
- `GlorboWeb.AgentLive.io_card_from_file` — lstat before
  `File.read` of inbox/outbox previews.

Pattern across the code: **`File.lstat` is the default for any path
that crosses the agent-writable → host-read / host-write boundary.**
Use `File.stat` only when you specifically want symlink-following
semantics (rare).

### Router slug discipline — chat + agent targets are Path.join fuel

`Glorbo.Company.Router.parse_to/1` now validates both `chat:<name>`
and `agent:<slug>` segments through `GlorboWeb.Slug.valid?/1`
(canonical `\A[a-z0-9-]+\z`) before the strings reach `Path.join`
for channel / inbox writes. Wave 4 threatmodel rows 15 & 18 —
the outbox `to` field had only a control-char filter, so
`to: chat:../../otherco/channels/general` or
`to: agent:../audit` flowed through as path-traversal.

Rule: every Router-facing slug-shaped input must clear
`Slug.valid?` before joining a filesystem path. The previous
control-char filter was necessary but insufficient.

### task_id validation in Dispatch

`Glorbo.Agent.Dispatch.prepare_run_dir_path/3` now raises if
`task.task_id` doesn't match `\A[a-z0-9][a-z0-9._-]*\z`. The
existing `ensure_safe_run_dir!` lstat check is defense-in-depth,
but `..` would have slipped past it (lstat resolves the dotdot,
sees a legit directory). Both layers are kept.

### GEP-32 — native OpenAI-v1 harness runs inside bwrap

Accepted 2026-04-23. Key invariant added: the `glorbo harness`
subcommand is a **first-party wrapped CLI** bind-mounted as
`/usr/bin/glorbo-harness` into the same bwrap tree CLI agents
use. It is NOT an in-process SDK client — that would collapse
GEP-5 two-layer enforcement. Adding native agents extends
GEP-2 pillar 5 rather than softening it.

Credentials live at `~/.local/etc/glorbo/credentials/<provider>.toml`
— deliberately **outside** `~/.glorbo/` so a naïve
`tar cf backup.tgz ~/.glorbo` does not sweep API keys into the
backup.

The model catalog is file-backed at
`~/.glorbo/cache/providers/<alias>.json` with a SQLite
`provider_models` projection. `glorbo reindex` rebuilds the
SQLite table from the cache files without network traffic —
same GEP-7 D6 discipline as every other SQLite projection.

### Codex threat-model scan noise ratio

The fresh 126-finding Codex sweep against `cc99146` contained
many false positives — code was fixed in waves 1–3 but Codex
re-flagged against old commit hashes. Systematic approach:

1. `git log --oneline` the named file to see if it was touched
   in wave-1/2/3 commits (`27f2118`, `d6aaec5`, `d8d1e90`).
2. Grep HEAD for the fix pattern named in the finding
   description (`ensure_regular_file_lstat`, `Slug.valid?`,
   `@contract_files`, `sanitize_yaml_scalar`, etc.).
3. If the fix is present at HEAD, mark as false-positive and
   drop from the list.

Wave-5 discovered 6 false-positives this way (rows 24, 27, 31,
41, 42, 46). Don't blanket-trust Codex's "new" status.

### Threatmodel wave 6 — stale open rows can lag HEAD

Wave 6 closed 4 real mediums (`ACLMapper` scope slug gate,
`Skills.Resolver` lstat-before-copy, `Reindex.process_file/1`
lstat, `Hierarchy` 0600 private files + doctor warning) BUT 3
queued "open" rows were already fixed before the session started:
`glorbo.create_agent` YAML scalar validation landed in `7948a55`,
proposal extra-key filtering in `Company.Router.serialize_proposal/2`
landed with `@proposal_extra_key_re`, and restore symlink-target
rejection landed in `ae7e3fc` / `b5fa9f8`. For future threatmodel
waves, grep HEAD for the named fix pattern and existing regression
test before assuming the row still needs code.

### Threatmodel wave 7 — AGENT.md budget readers must honor the file spec

The canonical `agent/v1` shape in `docs/file-formats/agent_v1.md`,
the default `glorbo new agent` scaffold, and every built-in agent
template all use `budget.monthly_usd`, not the legacy top-level
`budget_usd_cents_month`. Before wave 7, `Agent.Parser` and
`Company.BudgetTracker` still only read the legacy field, so
scaffolded/template agents silently ran uncapped. Future code that
reads an agent budget directly from frontmatter should treat the
nested `budget.monthly_usd` block as authoritative and only fall
back to `budget_usd_cents_month` for compatibility.

### GEP-32 phase 1 — the harness must not trust built-ins as the only registry

Inside the sandbox, `glorbo harness` already receives the authoritative
runtime contract from `Dispatcher.build_env/6`: endpoint, auth mode,
reply path, usage path, and the per-provider credentials bind at
`/creds/provider.toml`. A built-in registry lookup is useful for manual
invocation, but it cannot be the only source of truth because
user-declared native providers from `~/.glorbo/providers.toml` are not
mounted into the sandbox. Rule: the harness may consult built-ins, but
must fall back to the env-driven runtime contract or user-defined native
providers will fail despite host-side registry resolution succeeding.

### GEP-32 dependency — native credentials need one canonical home path

By 2026-04-23 there were already three call sites that needed to agree
on where native credentials live: `Agent.Dispatch` (bind the file into
the sandbox), `CLI.Harness` (load it inside the sandbox), and `Doctor`
(`private_files` warning/fixer). Duplicating the fallback
`GLORBO_CREDENTIALS_DIR || ~/.local/etc/glorbo/credentials` in each
module is drift bait. `Glorbo.Filesystem.Hierarchy.native_credentials_dir/0`
is now the single source of truth; future native-provider work should
reuse it instead of re-encoding the path policy.

### GEP-32 phase 2a — usage JSON is still untrusted input

Phase 2a extends native `usage.json` with `audit_events` so the
harness can report per-tool activity back to `Agent.Dispatch`, but the
file still lives under the sandbox-visible run dir. That means the
parser must treat it like any other agent-adjacent artifact, not like a
trusted host-side control channel. `NativeV1.parse/1` now allowlists
both tool-count names and audit action names the harness itself emits,
and strips `detail` values down to simple scalar keys; anything else is
dropped before Dispatch can replay it into the company audit log.

### GEP-31 implementation — `network: proxy` enforcement lives in the launcher, not argv

`Glorbo.Sandbox.Bwrap.build_argv/1` still does **not** show the whole
proxy isolation story. The Linux enforcement lives in `Bwrap.start/2`,
which now wraps the existing bwrap command in `pasta -q -f --splice-only
-T <proxy_port> ...` and normalizes the proxy env to
`http://127.0.0.1:<port>`. Future reviews should not conclude "`proxy`
is still advisory" just because the pure argv builder lacks
`--unshare-net` for that mode; the network boundary moved to the outer
launcher process, while bwrap still owns the filesystem sandbox inside
that netns.

### GEP-32 phase 2b — runtime knobs cross the process boundary via env

The native harness cannot "just read opts" from `Agent.Dispatch`: in
production it runs as a subprocess inside bwrap, so every runtime knob
that matters to phase 2b (`http_timeout_s`, `http_max_retries`,
`web_fetch_timeout_s`, `max_tool_calls_per_turn`) has to survive the
`Dispatch.build_ctx/7 -> Dispatcher.build_env/5 -> glorbo harness`
hop. The load-bearing boundary is the native env contract, not the
in-memory Elixir call stack.

### GEP-32 phase 2b — tool payloads must stay JSON-safe

`bash` stdout and `web_fetch` bodies are arbitrary bytes, but the
harness serializes tool results back into JSON messages and stores
audit replay metadata in `usage.json`. That means phase 2b needs a
UTF-8 guard, not just a byte cap: invalid text now falls back to
base64 fields instead of crashing `Jason.encode!/1` on binary output.

### Network.Proxy — `async_nolink` is wrong for fire-and-forget accept loops

`Task.Supervisor.async_nolink/2` is only safe when the caller will
actually receive the task's `{ref, result}` and `:DOWN` messages. In
`Network.Proxy.accept_loop/3`, the acceptor task never drains those
messages, so using `async_nolink` for per-connection handlers quietly
turns every CONNECT request into mailbox growth. Fire-and-forget tunnel
handlers should use `Task.Supervisor.start_child/2`; keep
`async_nolink/2` only for the one acceptor task the GenServer itself
monitors and re-arms.

### CLI.Console — keep the Erlang cookie off argv

`iex --cookie ...` leaks the distribution cookie into process listings
on many systems. `iex` and `elixir` both honor `ERL_AFLAGS`, so
`CLI.Console` can inject `-setcookie ...` through the environment and
keep the remote-shell flow unchanged without exposing the cookie in
`ps`/`/proc` argv. That is a useful hardening step, but not a secrecy
boundary against the same OS user.

---

## What belongs in this file vs elsewhere

| Kind of fact | Where it lives |
|---|---|
| "This is the current architecture" | `docs/architecture.md` |
| "We decided X because Y" | `docs/geps/NNNN-*.md` |
| "Watch out for this gotcha in <dep>" | this file |
| "The graph flags this but it's fine" | this file |
| "This function has a weird call chain" | this file (short) or the function's moduledoc (full) |
| "We had an incident and learned Z" | this file → eventually a GEP if it shapes future design |
| Rolling punch list of TODOs | `docs/todo.md` |
