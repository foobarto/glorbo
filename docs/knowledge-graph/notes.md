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
