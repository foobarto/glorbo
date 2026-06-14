# 2026-06-14 — GEP↔code gap implementation

Building the genuine *capability* gaps the 2026-06-14 reconciliation
(`/goal fix all the findings`, PRs #60–#65) had only **documented**. The
reconciliation made each finding no-longer-true on paper; this session makes the
code match the spec. Gap report itself is operator-local (uncommitted).

## Task picked

`/goal implement missing functionality (gaps between GEPs and the code)` — turn
the documented known-gaps into shipped code, one verified PR per gap.

## What shipped

| PR | GEP | Gap closed |
|---|---|---|
| #66 | GEP-36 | `Actions.Tasks.move/4` — kanban status flips through the single write channel (earlier in the effort) |
| #69 | GEP-3 | memory opt-in persisted to disk; **+ strict `enable/2`** (no cache when the disk write didn't land) **+ reindex cache reconcile** (purge stale cache rows for companies opted-out on disk) — both from codex P2 review |
| #68 | GEP-61 | restored the `GLORBO_CREDENTIALS_DIR` absolute/no-`..` guard via single-authority delegation |
| #67 | GEP-25 | `:type_filename_mismatch` validator check |
| #63 | — | reconciliation notes on 39 GEPs (landed after fixing a real blocker, below) |
| #70 | GEP-42 | peer-review sentinels no longer shadowed by `InboxMessageMd` in `classify_by_path` (registry reorder) |
| #71 | GEP-47 | `task.dependency_missing` validator finding (parse-time half of D1) |

## Design calls I made without you

- **GEP-3 strict `enable/2`** returns `{:error, :company_md_missing}` rather than
  caching an opt-in the disk never got. Index tests that only needed the cache
  flag got a module-level `company.md` fixture; the lifecycle tests exercise the
  real disk write. CLI surfaces the error as a non-zero exit.
- **GEP-3 reindex reconcile** added `Index.cached_companies/1` + `unmark_disabled/2`
  (cache-only inverse of `mark_enabled/2`) so reindex evicts companies opted-out
  on disk — the cache can't outlive the disk truth.
- **GEP-42** reorder is `PeerReviewFeedbackMd → PeerReviewRequestMd → InboxMessageMd`
  (most-specific-first; feedback before request because `peer-review-feedback-X`
  also matches the request regex). Resolution is `classify_by_path` only — the
  `kind:`-based `classify_by_kind` was never ambiguous.
- **GEP-47** resolves `depends_on` ids via `File.regular?` on literal filename
  components (never globs the id), charset-guards the id before any FS lookup,
  and derives the company-root by `dirname`-walking the canonical
  `projects/<proj>/tasks/<file>.md` depth — robust even if the base path itself
  contains a `projects/` segment (regression-tested). Severity = `error`.

## Gates

Every PR: `mix precommit` (compile-warn-as-err + format + docs + full suite,
3290–3300 passing), `mix credo --strict` (0), `mix sobelow --exit` (0). One
unit + several regression tests per gap. GEP body updated append-only
(`RESOLVED (2026-06-14)` notes per GEP-1) + CHANGELOG entry each time.

## The #63 red-CI false-flake

`#63`'s `test (x86_64)` was red across ~6 reruns and assumed to be the known
Ecto-sandbox flake. It was **deterministic**: `PrivacyCheckTest` caught a leaked
absolute home path embedded in a GEP-21 reconciliation note. The
`cannot find ownership process (Glorbo.Company.AuditLog)` audit output is caught,
non-fatal **noise** — never the failure. Lesson saved to auto-memory:
extract the numbered `N) test …` failure, don't blind-rerun. Fix = repo-relative
path; #63 went green on the first run after.

## Skipped / not done — remaining capability gaps (need focused sessions)

Deliberately deferred — each is prod-code or security-sensitive and deserves
fresh context + per-PR codex review rather than an end-of-long-turn rush:

- **GEP-36 `Actions.Tasks.update/4`** — route the `save_task` (kanban) + task-editor
  (`task_live`) handlers through Actions. Touches the **approval-gate bypass
  protections** (codex-hardened `refuse_if_bypasses_approval_gate` /
  `refuse_if_clears_required_approval`) — rushing risks reopening the exact bypass.
- **GEP-41 standalone peer-review trigger** (HIGH) — fire peer review on
  `severity: major|critical` / `peer_review_required: true` independent of the
  Director-approval path (intercept the `done` transition in the Router). Today
  it only engages under `requires_approval: director`.
- **GEP-23 egress** (HIGH) — emit the six `egress.*` audit events from the proxy
  decision paths + the strict/smart pending-approval sentinel + `503 Retry-After`
  (currently a permanent 403). Largest; proxy + GEP-19 approval-queue wiring.
- **GEP-46** — the two mandated integration tests (`concurrent_dispatch_test.exs`,
  `cross_company_concurrent_test.exs`) driving real Agent.Servers; the cross-company
  one codifies a GEP-2 isolation invariant with zero current coverage. Test-only
  but harness-heavy + flake-prone (the dispatch/audit subsystem).

## Things I'd like your review

- For **GEP-47** I made `task.dependency_missing` an `error` (fails
  `glorbo validate` exit code). The GEP doesn't pin a severity. If you'd rather a
  forward-reference to a not-yet-created task be a `warning`, say so.
- Order for the remaining four: I'd take **GEP-46** next (no prod/security risk),
  then **GEP-36 update**, then the two HIGH proxy/router gaps. Push back if you
  want the HIGH ones first.
