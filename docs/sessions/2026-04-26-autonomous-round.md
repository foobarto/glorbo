# 2026-04-26 — autonomous session log

Round started after v0.11.3 + the GEP-34 Phase 1 ship. User
asked "what's next?" then "continue with GEP-34 unless there
are some security issues still open." No High/Medium open in
threatmodel — only lows — so picked Phase 2.

Autonomy level: **L3** (L2 + status promotions when settled;
no push).

---

## Task — GEP-34 Phase 2: `tasks_approval_state` rebuild from audit JSONL

**Task picked.** Phase 2 of GEP-34 was the next open phase
listed in the spec (Phase 1 `audit_events` shipped today as
commit `b6fb71c`). The schema's lifecycle fields
(`status`, `requested_at`, `resolved_at`, `reason`,
`agent_slug`) all derive from `approval.requested` /
`approval.granted` / `approval.denied` lines that already exist
in `companies/<co>/audit/YYYY-MM.jsonl`, so reindex can rebuild
the table by replaying those lines chronologically.

**What shipped.** `lib/glorbo/filesystem/reindex.ex`:

  * `rebuild_tasks_approval_state/1` — wipes the table, walks
    every `companies/<co>/audit/` dir, folds the three approval
    actions into a `task_path => state` map, bulk-inserts the
    final fold-state.
  * `fold_approval_dir/2` — sorts `*.jsonl` filenames
    lexicographically before folding (writer's `Date.to_string`
    + slice-7 yields zero-padded `YYYY-MM`, so lex sort =
    chronological).
  * `fold_approval_file/2` + `fold_approval_line/3` — same
    streaming + 64-KiB-line cap + JSON-decode skip-with-warn
    discipline as Phase 1's audit replay.
  * `apply_approval_event/3` for each of the 3 actions, plus a
    shared `update_resolution/5` helper for `granted` / `denied`.
  * `insert_approval_rows/1` — chunks of 100 (7 columns × 100 =
    700 binds, well under SQLite's 999 ceiling), provides
    explicit `inserted_at`/`updated_at` (the schema uses
    `timestamps(:utc_datetime)` which `insert_all` doesn't
    auto-populate).
  * `do_run/1` calls the new rebuild after `rebuild_audit_events/1`
    and adds `:tasks_approval_state` to the result map.
  * Moduledoc updated; the "two of three gaps remain" comment is
    now "one (`budgets`) remains."

**Tests** — 8 new in `reindex_test.exs`:

  * awaiting-only request → `status: "awaiting"`,
    `resolved_at: nil`
  * request → granted folds into `status: "approved"` with
    original `requested_at` preserved + `approved_at` →
    `resolved_at`
  * request → denied carries `denial_reason` and `denied_at`
  * resolution without prior request synthesizes a row using
    resolution ts as `requested_at` (handles
    retention-truncated audit logs)
  * cross-month fold (request in 2026-03.jsonl, grant in
    2026-04.jsonl) — verifies the lexicographic-filename-sort
    assumption end-to-end
  * idempotent re-run (wipes before re-import; row count stays
    1, not 2)
  * non-approval lines (`task.create`, `agent.error`) ignored
  * 64-KiB oversized-line cap drops the bad line + emits warn
    log

**Design calls I made without you.**

  * **Sentinel-retention question — went audit-only.** GEP-34
    Phase 2 left this open ("Probably yes for forensic clarity
    even though audit is sufficient — write decision when this
    phase ships"). Decided audit-only: the gate continues to
    delete `awaiting-approval-<id>.md` on resolution; no
    resolved sentinel is written. Audit JSONL already carries
    every field the schema needs, the dashboard already streams
    audit lines for forensics, and adding a second on-disk
    write at resolution time would couple the gate to a
    redundant artifact. Captured as GEP-34 D4. The §"Open
    questions" entry got flipped to "Resolved 2026-04-26."

  * **Chronological-fold relies on filename + line order, not
    explicit ts-sort.** The audit log writer (`Company.AuditLog
    .month_bucket/1`) uses `Date.to_string/1` then `String
    .slice(0, 7)`, which always produces zero-padded `YYYY-MM`.
    Lex sort = chrono sort, and `File.stream!` preserves append
    order within a file. Verified the writer; documented as
    GEP-34 D5. An explicit ts-sort would force the fold to
    materialize every line first — defeating the bounded-memory
    goal. The cross-month test exercises the assumption.

  * **Resolution-without-request synthesizes a row.** Audit
    logs may be retention-truncated; if a `granted` line shows
    up without its `requested` counterpart, we still record
    the row using the resolution ts as `requested_at` (since
    `requested_at` is `null: false` in the migration). Better a
    slightly wrong `requested_at` than dropping the entire
    approval lifecycle.

  * **`reason` only set on `denied`.** `granted` events don't
    carry a reason; the `update_resolution/5` helper passes
    `nil` from the `granted` branch. If a granted row had a
    reason from a prior `denied` (impossible in practice — the
    gate's lifecycle is request → resolved), the latter wins
    because the fold replaces, not merges.

**Gates.**

  * `mix test test/glorbo/filesystem/reindex_test.exs` — 26/26
    green (8 new tests + 18 existing).
  * `mix test test/glorbo/approvals/gate_test.exs` — 24/24 green
    (writer side untouched).
  * `mix test` (full suite) — 2265/2265 green, 42 excluded, 2
    skipped, 50.2s wall.

**Skipped / not done.**

  * Phase 3 (`budgets`) — separate PR; needs its own audit
    replay logic with threshold re-evaluation for the
    `alerts_fired` bitmap. Tracked as the last open Phase in
    GEP-34.
  * `mix precommit` not yet run (next step before commit).

**Commit(s).** Pending — bundle code + GEP edit + todo update
+ this session log.

### Things I'd like your review

  * **Phase 1 `_system` audit reindex path mismatch.** While
    studying Phase 1 to model Phase 2, I noticed the writer
    (`Company.AuditLog.jsonl_path/3`) puts orchestrator events
    at `<base>/audit/_system/<YYYY-MM>.jsonl` (a subdirectory)
    but Phase 1's `rebuild_audit_events/1` lists `*.jsonl`
    files directly under `<base>/audit/` (flat). The Phase-1
    reindex_test passes because the test writes to the flat
    path, but production layout is the subdirectory. Either
    reindex should descend into `_system/` or the writer
    should flatten. I added a P1 todo entry and left it as
    "defer pending decision on which path is canonical" —
    probably the subdirectory writer is right, so reindex
    needs to match. Flagging because it's a real
    `glorbo reindex` correctness issue for orchestrator-event
    rebuild (silent: zero rows imported, no error).

  * **Sentinel-retention call.** I went audit-only (D4); the
    GEP §Open-Questions entry leaned that way already. Worth
    flagging because it changes nothing about the writer
    side — but if you'd rather have the gate write a
    resolved-approval sentinel for `ls`-friendly forensics, the
    decision flip is just a few lines in `Approvals.Gate` and
    a new `kind: sentinel-resolution/v1` FileSpec. Audit-only
    is the simpler, more-orthogonal call IMO.
