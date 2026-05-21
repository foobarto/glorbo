# 2026-05-21 — Docs spring-cleaning + fact-check

## Task picked

Spring-clean `docs/`: delete historical-only documents after capturing
their essence (decisions/learnings) into durable stores, and fact-check
the remaining living docs against actual code state. (Also, earlier in
the session: sanitized engagement/tool-name leaks in tracked content and
fixed a flaky watcher test — separate commits `04e4059`, `d5a67c8`.)

## What shipped

**Essence capture** (into `knowledge-graph/notes.md`, new 2026-05-21
section) — seven multi-module gotchas lifted from the deleted session
logs: TaskScheduler-bypasses-Router; GEP-33 HomeHistory commit semantics
(no-op `sha:""`, audit-jsonl exists-filter + UTC month boundary, Tx
best-effort silence, timer anchoring); `serve`/`up` port-bind trap
(`:serve_starts_endpoint`); Tx-debounce poll-not-sleep test pattern;
Watcher `:ignore` handling; `role:` dead vs `headcount_budget` live;
`phoenix_live_reload` prod-manifest leak.

**Deletions** (all git-recoverable; essence captured first):
- 6 `docs/sessions/` autonomous-round / fix logs (kept README.md)
- `docs/superpowers/` (GEP-48 plan+spec — fully captured in GEP-48)
- `docs/archived/` (plan-2026-04-21, review-v0.0.3 — shipped/superseded)

**Fact-check fixes:**
- `DESIGN.md` — supervision tree named `Glorbo.Company.FileWatcher`
  (nonexistent) → `Glorbo.Filesystem.Watcher`; added missing children
  `AuditLog`, `DispatchSemaphore` (GEP-46), `PathRequestGate`; fixed two
  prose `FileWatcher` refs; updated stdout path to per-invocation
  `stdout-<id>.log` + `StdoutStreamer` (GEP-46).
- `architecture.md` — MCP "19 tools" → 23 (verified against
  `mcp/server.ex` @tools + `mcp/tools/`).
- **GEP-45 status `Draft` → `Implemented`** — all 4 phases verified
  shipped (audit_fun in `Acp.Client`, `stado_acp.ex` parser, 3 ACP
  variant TOMLs); updated index row + added history entry.
- `research/per-provider-model-params.md` — "GEP-27" mislabel fixed
  (number is taken by Agent Sandbox Path Requests).
- `research/gep-45-bench-acp.md` — trimmed now-shipped Phase-3 follow-ups.
- Captured two orchestration-benchmark follow-ups (`:reroute` verdict,
  `handoff.note:`) into `todo.md` P2.
- Fixed GEP-36 dangling pointer to a deleted session log.

**Regenerated** `knowledge-graph/GRAPH_REPORT.md` via `graphify update
lib` (was Apr-27 stale: 279 files/3479 nodes → 290/3669; now covers the
ACP/DependencyGate/DashboardToken/DispatchSemaphore modules). Cleaned up
stale 7MB `lib/graphify-out/`.

## Design calls I made without you

- **Kept all `docs/research/`** — three feed unshipped GEPs (per-provider
  params, glorbo-vs-localforge bridges #2–#5, crown-jewels backlog);
  point-in-time benchmarks kept too (low clutter, live forward-pointers
  captured to todo). Only sessions/superpowers/archived deleted.
- **Reverted a fact-check false positive** — the agent flagged README
  "Latest release v0.20.0" as stale vs `mix.exs` 0.20.1, but 0.20.1 is
  the in-dev version (not tagged); v0.20.0 is the latest *release*, so
  the README was correct.

## Gates

- Subagent triage (4 parallel agents) for the reading-heavy pass.
- All deletion candidates confirmed git-tracked (recoverable).
- Verified 05-05 fixes shipped + Watcher `:ignore` live before deleting.
- Dangling-reference sweep after deletion (1 found in GEP-36, fixed).
- GEP-45 phase claims verified against actual modules before flipping.

## Skipped / not done

- Did not delete `agent-templates/` (accurate self-labeled drafts) or
  `knowledge-graph/notes.md` (living, spot-checked accurate).
- README CLI Reference omits ~8 advertised verbs (`run`, `shell`,
  `history`, `templates`, `import`, `bench`, `migrate`, `version`) —
  cosmetic completeness gap, left for a follow-up.

## Commit(s)

- (pending) docs spring-cleaning + fact-check batch.

## Things I'd like your review

1. OK to keep all of `docs/research/` rather than pruning the two
   point-in-time benchmark docs? (I kept them; follow-ups are in todo.)
2. Want the README CLI Reference completed with the missing verbs now,
   or leave as a P2 todo?
