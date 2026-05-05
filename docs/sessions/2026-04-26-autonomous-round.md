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

---

## Task 2 — GEP-34 Phase 3: `budgets` rebuild from audit JSONL

**Task picked.** Phase 3 was the last open phase in GEP-34 — user
said "go for it" after Phase 2 shipped. Bounded; followed the
same shape as Phase 2 (wipe-and-rebuild, per-company JSONL fold,
chunked bulk insert).

**What shipped.** `lib/glorbo/filesystem/reindex.ex`:

  * `rebuild_budgets/1` — wipes the table, walks every
    `companies/<co>/audit/` dir, sums `budget.usage` lines into a
    `{company, agent, year_month} => totals` map, bulk-inserts.
  * `sum_budget_dir/3` + `sum_budget_file/3` + `sum_budget_line/4`
    — same streaming + 64-KiB-line cap + JSON-decode skip-with-
    warn discipline as Phase 1 / Phase 2.
  * `apply_budget_usage/3` — extracts `agent`, `prompt_tokens`,
    `completion_tokens`, `cost_usd_cents` from each line; derives
    `year_month` via `Budget.Ledger.month_bucket/1` (the writer's
    own helper — see D7 below); folds into per-key sums.
  * `non_neg_int/1` — coerces missing / non-integer / negative
    fields to 0 so a malformed event can't insert a row with NULL
    or negative tokens (the schema's `validate_number greater_
    than_or_equal_to: 0` only fires on `Repo.insert/2`, not
    `insert_all`).
  * `insert_budget_rows/1` — chunks of 100 (8 cols × 100 = 800
    binds, well under SQLite's 999 ceiling). Provides explicit
    `inserted_at`/`updated_at`.
  * `do_run/1` calls the new rebuild after Phase 2 and adds
    `:budgets` to the result map.
  * Moduledoc updated with Phase 3 description + the
    `alerts_fired` clarification (it's tracker GenServer state,
    not schema columns; rehydrated from `alerts/*.md` on boot).

**Tests** — 8 new in `reindex_test.exs`:

  * single `budget.usage` line lands as one row
  * multiple events in same month sum into one row
  * events spread across months produce separate rows
  * different agents in same month produce separate rows
  * two companies stay isolated
  * idempotent re-run (wipes before re-import; row count stays 1)
  * non-budget lines (`task.create`, `approval.granted`) ignored
  * missing/invalid token fields default to 0

**Design calls I made without you.**

  * **Audit action name is `budget.usage`, not `usage.recorded`.**
    GEP-34's spec said `usage.recorded` but the actual writer
    (`Company.BudgetTracker.safe_record/3`) emits
    `action: "budget.usage"`. Used the real name; updated the
    GEP §Phase-3 paragraph to call out the spec drift. Matters
    because had I followed the spec literally, replay would have
    silently inserted zero rows.

  * **`alerts_fired` bitmap is out of scope.** GEP-34's open-
    questions block worried about reconstructing the bitmap by
    re-evaluating threshold ladders. False alarm: the bitmap is
    GenServer state in `Company.BudgetTracker`, not a column on
    the `budgets` schema, and the tracker's moduledoc says it
    rehydrates from `alerts/*.md` on boot. Reindex doesn't need
    to touch it. Captured by flipping the §Open-Questions entry
    to "Resolved 2026-04-26 — moot".

  * **No chronological fold for budgets (D6).** Phase 2 needed
    chronological order because a later `granted` line must
    overwrite an earlier `awaiting` state. Phase 3 is pure
    summation — addition is commutative — so I skipped the
    `Enum.sort/1` on filenames. Each event carries its own `ts`
    and therefore its own `year_month` bucket; cross-month
    behaviour falls out naturally.

  * **Use the writer's `month_bucket/1` (D7).** Imported
    `Budget.Ledger` and called `Ledger.month_bucket/1` rather
    than reimplementing the YYYY-MM derivation. If the writer's
    bucketing logic ever changes (e.g. fiscal-year buckets),
    replay tracks automatically. Slight tradeoff: a circular-
    looking dep in the alias list, but it's an existing module
    + pure function — no boot-order issue.

  * **Defensive integer coercion via `non_neg_int/1`.** The
    schema validates non-negative ints in changeset, but
    `Repo.insert_all` skips changesets entirely. A malformed
    audit line with `"prompt_tokens": null` or
    `"prompt_tokens": -5` would write garbage. Coerce to 0 at
    the seam.

**Gates.**

  * `mix test test/glorbo/filesystem/reindex_test.exs` — 34/34
    green (8 new + 26 from earlier today).
  * `mix test test/glorbo/budget/ test/glorbo/company/budget_tracker_test.exs`
    — 38/38 green (writer side untouched).
  * `mix test` (full suite) — 2273/2273 green, 42 excluded, 2
    skipped, 51.1s wall.

**Skipped / not done.**

  * The Phase 1 `_system` audit path mismatch I flagged in Task 1
    is still open — separate fix.
  * `mix precommit` not yet re-run (next step).
  * GEP-34 status flipped to **Implemented**; commit pending.

**Commit(s).** Pending — bundle code + GEP edit + todo update +
session-log append.

### Things I'd like your review (Task 2)

  * **Spec-vs-writer drift.** GEP-34 said `usage.recorded`, the
    writer emits `budget.usage`. I updated the GEP. Worth a
    glance at whether other GEPs reference an action name and
    might be similarly stale — quick `grep -r "action.*usage" docs/`
    didn't surface anything obvious but I didn't grind further.
    File a P3 todo to audit GEP audit-action references? Or
    not worth it, the only consumer is reindex which now matches
    the writer.

  * **GEP-34 → Implemented.** All three phases shipped today.
    Please verify the Implemented status flip in the frontmatter
    is appropriate — I'm assuming it is per the original spec
    ("after rm glorbo.db && glorbo reindex, no derived field is
    missing"). Result map now carries `indexed`, `skipped`,
    `deleted`, `audit_events`, `tasks_approval_state`, `budgets`
    — every projection from the GEP plus the original three.

---

## Task 3 — Phase 1 `_system` audit reindex path mismatch

**Task picked.** I flagged this in Task 1's review block as a
real `glorbo reindex` correctness gap: the AuditLog writer puts
orchestrator events at `<base>/audit/_system/<YYYY-MM>.jsonl`
(subdirectory) but Phase 1's `rebuild_audit_events/1` was
listing `*.jsonl` files directly under `<base>/audit/`, so
production system events never replayed. Follow-up scope was to
continue with that fix.

**What shipped.** `lib/glorbo/filesystem/reindex.ex`:

  * `rebuild_audit_events/1` — `system_audit_dir` now joins
    `[base, "audit", "_system"]`, matching the writer's
    `Company.AuditLog.jsonl_path/3` `_system` branch. Comment
    block updated to reference the writer-side function so the
    coupling is explicit.

**Tests** — `test/glorbo/filesystem/reindex_test.exs`:

  * Updated the existing `_system` test to write to
    `audit/_system/2026-04.jsonl` (production layout) and
    renamed it for clarity.
  * Added a defensive negative test confirming that JSONL files
    placed at the legacy flat `<base>/audit/*.jsonl` path are
    ignored — they're not what the writer emits, so reindex
    correctly skips them.

**Cross-checks.** Verified the rest of the codebase already
uses the subdirectory layout — Doctor (`lib/glorbo/doctor.ex`),
the auto-fixer (`lib/glorbo/doctor/fixer.ex`), the FileSpec
(`lib/glorbo/file_spec/audit_month_jsonl.ex`), and the
portability test fixtures (`test/support/portability_fixtures.ex`)
all reference `audit/_system/`. Reindex was the only outlier.

**Design calls I made without you.**

  * **Pre-1.0 = no compat shim.** I considered making the
    reader fall back to flat-path files for backward-compat,
    but the writer never wrote them. Any flat file in
    production is operator detritus or an old test artifact —
    safer to ignore than to silently import inconsistent data.
    The new defensive test locks in the ignore behaviour.

**Gates.**

  * `mix test test/glorbo/filesystem/reindex_test.exs` — 35/35
    green (1 updated + 1 new test on top of the 34 from
    earlier today).
  * `mix precommit` — 2274/2274 green, 42 excluded, 2 skipped,
    52.2s wall, exit 0.

**Skipped / not done.**

  * No code beyond reindex.ex + the test changes; no
    documentation drift to chase down (the reader was the
    odd one out).

**Commit.** Pending.

### Things I'd like your review (Task 3)

  * **One-line behavioural change.** A user who has been
    running this branch with `_system` events in flat-path
    files would see them stop importing after this fix. Given
    the writer never produced flat files, this is an empty
    set in practice — but worth noting as a "behavioural
    change in reindex" line for any release notes.

---

## Task 4 — v0.12.0 release-gate walk + cut

**Task picked.** With every gap-table from GEP-34 now derived
from disk, this was the natural moment to roll the work onto a
release surface. The L4 continuation scope was to walk
`docs/workflow/release-gate.md` end-to-end as a single bounded task.

**What shipped (Step 1 — doc-drift pass).**

  * `mix.exs`: `version: "0.11.3"` → `"0.12.0"`.
  * `CHANGELOG.md`: promoted `[Unreleased]` to
    `[0.12.0] — 2026-04-26` with a description of the GEP-34
    phases plus the `_system` audit subdirectory fix; reset
    `[Unreleased]` to "(nothing yet — next cycle)".
  * `README.md`: "Latest release **v0.11.1** (2026-04-25)" →
    "**v0.12.0** (2026-04-26)" in the Project Status block.
  * `docs/geps/README.md`: GEP-34 row flipped Draft →
    Implemented in the index (file frontmatter was already
    Implemented; `mix gep.validate` caught the index drift).

**What shipped (Step 2 — graphify refresh).** Ran
`graphify update lib`; the report grew to **3312 nodes / 6230
edges / 118 communities** (was 2478 / 4478 / 103 at the v0.11
baseline) — that's roughly +25% on every dimension, reflecting
the FileSpec / Actions / native-harness / GEP-32 / GEP-34 work
since v0.11.0. Moved the regenerated `GRAPH_REPORT.md` into
`docs/knowledge-graph/`. Appended a fresh tacit-knowledge
section to `notes.md` capturing four facts I learned today:

  1. `Reindex.run/1` result-map keys are additive, never
     removed (additive extension is safe pre-1.0).
  2. Trust the writer for audit-action names — GEP specs can
     drift (the `usage.recorded` vs `budget.usage` divergence
     I hit in Phase 3).
  3. `alerts_fired` isn't on the `budgets` schema (it's
     GenServer state in `BudgetTracker`, rehydrated from
     `alerts/*.md`).
  4. Phase 2 needs chronological fold, Phase 3 doesn't —
     order matters for lifecycle, not for summation.

**What shipped (Step 3 — tests + Credo).**

  * `mix test` → 2274 / 2274 green, 42 excluded, 2 skipped,
    50.6s wall.
  * `mix credo --strict` → 5389 mods/funs, no issues, exit 0
    (verified explicitly with `echo $?` per the gate's "Credo
    doesn't exit non-zero on refactor warnings" caveat).

**What shipped (Step 4 — UAT smoke).** N/A for a reindex-
internals release (no UI surface change). The CLI E2E was
already covered by `mix precommit`'s release-binary smoke
chain (`init → new company → reindex → post_doctor`) which
ran in Step 3 with `reindex — indexed=5 skipped=0 deleted=0`
exit 0. Documented as such in the commit body so the gate
walk is auditable.

**What shipped (Step 5 — security review).**

  * Open Critical / High / Medium / Low: **0 / 0 / 0 / 0**
    in `docs/testing/threatmodel.md`.
  * 2 Accepted Risks documented inline (stdout-streamer marker
    spoofing; release-boot `validate_compile_env: false`).
  * 24 Informational rows remain — explicitly flagged
    "correctness / UX — not a direct security gap" by the
    threatmodel itself; not blockers per
    `docs/project-profile.md` §"P0 definition" which scopes
    P0-deferral specifically to security findings.
  * Reviewed the diff itself for new attack surface: JSONL
    inputs are bounded by the existing 64-KiB line cap; all
    integer fields go through `non_neg_int/1`; `Repo.insert_all`
    uses parameterized binds; `Path.join` uses pre-validated
    `companies_dir`. Clean.

**What shipped (Step 6 — release).**

  * Local pre-flight: `mix gep.validate` (1 error caught + fixed:
    GEP-34 README index Draft → Implemented), `mix glorbo.docs.
    file_formats --check` (clean).
  * Single release commit `50c393c chore(release): cut v0.12.0`
    bundling all 6 files with the gate-walk evidence as the
    commit body.
  * `git tag -a v0.12.0 -m v0.12.0` — annotated tag at HEAD.
  * `git push origin main` (b6fb71c..50c393c) +
    `git push origin v0.12.0`.
  * Three CI runs kicked off: main-branch CI, tag-triggered CI
    (the publish job), and Pages deploy. Armed `ci-monitor` on
    the tag run (24952972187) which handles the Burrito build +
    signed GitHub Release upload; will notify on completion.

**Design calls I made without you.**

  * **Bumped 0.11.3 → 0.12.0 (minor), not 0.11.4 (patch).**
    GEP-34 is a load-bearing FS-as-source-of-truth invariant
    — `glorbo.db` is now genuinely rebuildable for the first
    time. That's behavioural, not just a bugfix; minor cut is
    the honest call. Pre-1.0 SemVer is loose, but this matches
    the v0.10 → v0.11 precedent (GEP-44 + harness work).

  * **Skipped browser UAT.** Per CLAUDE.md the browser path
    requires distrobox; I'm on the host. The release ships
    no UI changes, so the CLI smoke from precommit's
    release-binary chain covers the actual change set.
    Documented this in the commit body so the next reviewer
    sees the reasoning.

  * **Single bundled release commit.** Considered splitting
    the version bump from the docs/graph refresh, but the
    release-gate output IS a single atomic event from the
    user's perspective. One commit is easier to revert if the
    tag has to be pulled.

**Gates.**

  * All 6 release-gate steps green.
  * Tag pushed; CI monitoring armed.

**Skipped / not done (and why).**

  * `gh release view v0.12.0` verification — depends on the
    tag-triggered CI publishing the assets first.
  * `mix glorbo.release_formula --write` — the task fetches
    `SHA256SUMS` from the live GitHub release, which doesn't
    exist until CI completes the publish job. Will be the
    next-step trigger after the CI monitor fires success.
  * `brew upgrade glorbo` smoke + `git push` to the tap repo
    — needs the user's local environment / authentication on
    the homebrew-tap repo. Will surface as a follow-up ask
    once CI lands and the formula regenerates clean.

**Commit(s).** `50c393c chore(release): cut v0.12.0
(GEP-34 reindex v2 fully Implemented)` — the single release
commit; tag `v0.12.0` annotated at the same SHA.

### Things I'd like your review (Task 4)

  * **Release-formula + tap push are still pending CI.**
    When the monitor fires success, I'll run
    `mix glorbo.release_formula --write` against
    `../homebrew-tap` if that sibling exists, otherwise dump
    the formula and ask you to drop it in place. The
    `git push` to the tap repo is a separate-confirmation
    step (touches a different repo). Same with
    `brew upgrade glorbo` — your-machine action.

  * **Behavioural-change footnote on `_system` audit.** The
    fix in commit 8d9f3b1 silently changes which JSONL files
    `glorbo reindex` will read. For any user who hand-placed
    files at the legacy flat path, those events stop being
    indexed. The CHANGELOG records this as a `Fixed` line —
    flagging it explicitly here in case you'd rather call it
    out as a "Behaviour change" subheading in the release
    notes.
