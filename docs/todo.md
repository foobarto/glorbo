# TODO — running punch list

Rolling list of noticed-but-not-yet-shipped items. Updated at the end
of every working cycle.

- **What lives here:** observations, follow-ups, visual polish, small
  UX tweaks, and deferred sub-tasks that don't warrant a GEP.
- **What doesn't:** architectural decisions (→ GEP), shipped work
  (→ CHANGELOG), autonomous-session review notes (→ user.md), OTP /
  filesystem invariants (→ CLAUDE.md or GEP-2).

Format: one bullet per item. Check `[x]` when shipped; delete once
it's been in CHANGELOG for a cycle.

---

## P0 — actively wrong (broken/lying/crashy)

*(empty — knock on wood)*

## P1 — next cycle

- [x] **GEP-32 phase 3 — native model discovery + cache surface.**
  Shipped `Glorbo.Providers.ModelCatalog` + `NativeConfig` +
  `ProviderModel` schema + migration. Wires `cache/providers/*.json`
  to a derived SQLite projection, reindex rebuild is network-free,
  AgentBoot soft-warns on unknown models, ProvidersLive grows a
  catalog chip (status / model count / refreshed), and failure
  classification matches the spec matrix (`:auth` / `:unreachable` /
  `:stale` / `:shape`).
- [x] **GEP-32 phase 4 — `glorbo detect-providers` CLI verb + agent-
  wizard model combobox.** Shipped the localhost probe (ollama,
  llama.cpp, LocalAI, vLLM, LM Studio) with shape + Server-header +
  body fingerprints, ProvidersLive `scan localhost` button, and
  AgentLive `model` datalist backed by the `provider_models` cache.
- [x] **GEP-32 phase 4 follow-up — auto-activate discovered providers
  via `Enable` flow.** Shipped `Glorbo.Providers.Enable` + the
  `+ enable` button per `:ready` scan row; idempotent on double-click.
- [x] **GEP-32 phase 4 follow-up — model combobox on KanbanLive
  new-task quick-add.** Shipped 2026-04-24 (autonomous round).
  `KanbanLive.model_options_for_assignee/3` looks up the selected
  assignee's provider and returns cached `provider_models` IDs; the
  new-task drawer renders a `<datalist>` for `model` next to
  `assigned to`. `model` persists into task frontmatter when
  non-empty. 5 new tests (43 total in kanban_live_test.exs).
- [x] **TaskScheduler retrofit GEP (Informational).** Shipped as
  `GEP-0024` with 7-entry decision log; bidirectional links added
  to GEP-2 + GEP-3.
- [x] **Visual "next fire at" indicator on TaskLive** — shipped
  on the usage strip with relative formatter (s / m / h m / d →
  ISO for far-future).
- [x] **Scheduler fire audit PubSub broadcast** — verified:
  `AuditLog.append/2` always broadcasts `{:audit_append,
  record}` on `company:<co>:audit`, and TaskScheduler routes
  through it via `audit_via_registry/2`. End-to-end chain
  intact; TaskLive history panel refreshes live.
- [x] **Modal ESC close consistency.** Fixed this cycle — every
  `.gl-modal` now wires `phx-window-keydown=<cancel> phx-key=Escape`;
  the ApprovalQueueLive deny modal was the only holdout.
- [ ] **Scheduler rescan is O(projects × tasks) every 60s.** Fine for
  v0.0.3's single-digit task counts, but watch it past 1000 tasks.
  If it becomes hot, cache mtime like Search.scan_tasks already
  does.
- [x] **GEP-34 Phase 2 — `tasks_approval_state` rebuild from
  audit JSONL.** Shipped 2026-04-26. `Reindex.run/1` folds
  `approval.{requested,granted,denied}` lines chronologically per
  task_path into the schema's `{status, agent_slug, requested_at,
  resolved_at, reason}` shape, bulk-inserts in chunks of 100.
  Resolutions without a matching request synthesize a row from
  the resolution event. Decided sentinel-retention question
  audit-only (gate keeps deleting the awaiting sentinel; no
  resolved sentinel written; audit JSONL is authoritative).
  GEP-34 D4+D5 captured. 8 new tests; result map gains
  `:tasks_approval_state` count. Only `budgets` (Phase 3)
  remains.
- [ ] **Phase 1 `_system` audit reindex path mismatch.** The
  writer puts orchestrator events at
  `<base>/audit/_system/<YYYY-MM>.jsonl` (subdirectory) but
  Phase 1's `rebuild_audit_events/1` lists `*.jsonl` files
  directly under `<base>/audit/`. The reindex_test passes because
  tests write to the flat path; production layout is the
  subdirectory. Either reindex should descend into `_system/` or
  the writer should flatten — defer pending decision on which
  path is canonical (probably the subdirectory writer is right;
  reindex needs to match).

## P2 — nice to have

- [x] **VR harness fixture-seed bug.** Shipped 2026-04-25 — harness
  now uses `./glorbo init` + `./glorbo new company acme` against
  a fresh tmp `GLORBO_HOME`, with a `mix glorbo.build_local`
  fallback when the burrito symlink is missing. Also moved the
  case-dispatch block AFTER the function definitions (the prior
  ordering silently failed at runtime — masked because
  contributors invoked the node script directly). Baselines
  recaptured into `2026-04-25-0.11.0/`.
- [x] **VR harness `check` mode flake risk — topbar-path + clock
  noise.** Shipped 2026-04-25. Capture script now passes Playwright
  a `clip` rect that excludes the top 30px (path bar) and bottom
  30px (wall-clock + uptime). Worst drift across 3 back-to-back
  `check` runs: 0.045% on `/health` — well under the 0.5%
  threshold.
- [x] **VR harness needs project-local node_modules.** Shipped
  2026-04-25. `scripts/package.json` lists playwright + pngjs +
  pixelmatch (pinned to ^5 for CommonJS); `ensure_node_deps()`
  runs `npm install` on demand. `NODE_PATH` set to
  `scripts/node_modules` for both capture + diff invocations.
- [x] **VR drift outliers on CI vs local** — Shipped 2026-04-25.
  Picked option (b): added a `DIFF_SKIP` set in the harness for
  `08-health` and `12-providers`. Both LVs are still captured
  (so dated baseline dirs stay complete) but skipped during
  diff. Their entire purpose is to surface environment-
  dependent data (host CLI versions, doctor check details,
  localhost provider scan results); making them deterministic
  would defeat their purpose. Captures still serve as visual
  archive when contributors run `update`.
- [ ] **VR gate flip to blocking-mode** — drift gate is currently
  `continue-on-error: true`. With DIFF_SKIP closing the env-
  drift outliers, the next step is measuring per-PR flake rate
  for 1–2 weeks of real PR activity. If 16/16 gated LVs stay
  under threshold across ≥10 PRs, flip to blocking by removing
  `continue-on-error`. Until then it's informational.
- [x] **Modal body `gl-form__row` in narrow viewport.** Shipped
  2026-04-25. Added a `@media (max-width: 600px)` block that
  switches `gl-modal__body .gl-form__row` from
  `grid-template-columns: 140px 1fr` to `1fr` (label stacks
  above input), with reduced row gap and the label
  `padding-top: 0` so it sits directly above its control. No
  layout impact above the breakpoint.
- [x] **Close button `×` hover affordance.** Fixed in round 9 —
  hover shows a raised-surface background + border; focus-visible
  adds a 2px accent outline.
- [x] **Scheduler aliases list is closed.** Shipped `Glorbo.ScheduleNL`
  (#280) — handles `every morning`, `every weekday at 9am`,
  `every 5 minutes`, weekday names, etc.
- [x] **Topbar shortcuts truncate on narrow windows.** Shipped
  2026-04-25. Added `@media (max-width: 1100px)` that hides
  `.gl-topbar__kbd` (the inline shortcut strip) plus the
  trailing separator. Power users keep the full reference via
  the `?` modal; the topbar's path / picker / version / dump /
  TWEAKS get the space they need. CSS-only — no markup change.
- [ ] **Approvals power-user features on Inbox Mine tab.**
  ApprovalQueueLive was collapsed into Inbox (backlog #14), but
  its keyboard shortcuts (j/k/y/n) and prompt-diff panel weren't
  preserved. Revisit if director feedback complains about
  approval throughput.

## P3 — thinking out loud

- [x] **InotifyToBwrapHappyPathTest suite-pollution — root-caused
  + fixed (2026-04-25).** Wasn't pollution at all: an inotify
  watch-attachment race. `Watcher.start_link/1` returned before
  `inotifywait` had attached its kernel watches; concurrent
  scheduler load from preceding agent-spawning tests made the
  file write fire ahead of attachment more often, so events
  were silently dropped. Fix: 250ms settling sleep after
  `Watcher.start_link/1` in the test, with rationale captured
  in the test moduledoc.
- [x] **GEP-33 — git history layer for ~/.glorbo/. STATUS:
  IMPLEMENTED 2026-04-25.** Phase 1 read UX shipped earlier;
  Phase 2 (marked commits from writers) + Phase 3 (watcher
  fallback for manual edits) shipped today across 15 commits
  (`97c48f7` 2a-1, `4827554` 2b, `b731a0c` 2c-0+1, `8254341`
  2c-2, `9830268` 2c-3, `9df606f` 2c-4, `8ce37fa` 2c-5,
  `f304d61` 2c-6, `26ccc9d` 2c-7, `5a42771` 2c summary,
  `9f69b13` 2c-8, plus today's Phase 3 commit). Status flipped
  in `docs/geps/0033-git-history-layer-for-glorbo-home.md`.
  Phase 4 (`history restore`/`show`/`diff` UX) is still
  ahead — additive Director ergonomics on top of an
  already-working layer; tracked separately as P3 work.
- [x] **GEP-33 Phase 4 — `history show` / `diff` / `restore` UX
  shipped 2026-04-25 (autonomous L4).** All three verbs landed
  with defensive rev/path validation and dry-run-by-default for
  restore. With Phase 4, every implementation phase from §14 is
  done; GEP-33 is fully Implemented.
- [x] **(superseded by GEP-33 Implemented entry above)
  GEP-33 Phase 2 — marked commits from write surfaces.**
  Phase 1 shipped 2026-04-25 (`Glorbo.HomeHistory` + `glorbo
  history {init, status, log}`). **Phase 2a-1 shipped
  2026-04-25 (autonomous L4):** synchronous `commit_marked/3`
  primitive — kernel committer + actor-aware author + sanitized
  GEP-33 §4.3 trailers + tracked-scope filter + no-op-on-empty
  semantics. 12 new tests; 31 total in `home_history_test.exs`.
  **Phase 2b shipped 2026-04-25 (autonomous L4):**
  `Glorbo.HomeHistory.Tx` GenServer wraps the primitive with
  §6.1 debounce semantics (500 ms inactivity, 2 s hard cap),
  fire-and-forget auto-flush, "history disabled" translation
  for unconfigured homes. Wired into `Glorbo.Application`. 12
  Tx tests in `tx_test.exs`. **Phase 2c-0 + 2c-1 shipped
  2026-04-25 (autonomous L4):** `Tx.with_tx/3` helper +
  resilient-to-missing-server fallback; first writer wired
  (`Actions.Companies.update/3`) + integration test;
  `commit_marked/3` gained an existence filter so optimistic
  marks of async-written audit paths don't break the whole
  commit. **Phase 2c-2 shipped 2026-04-25 (autonomous L4):**
  shared `HomeHistory.actor_from_string/1` +
  `audit_jsonl_path/2` helpers extracted; `Tasks.create/4`,
  `Channels.create/3`, `Channels.archive/3` wired through
  `with_tx`; Companies.update retrofitted to use the shared
  helpers. 6 new integration tests. Phase 2c-3 picks up
  Goals / Skills / Projects / Proposals / Agents / the rest
  of Tasks-mutation surface + the Router proposal/memory
  paths. Phase 3 follows with watcher-fallback `External`
  commits for manual edits; Phase 4 adds
  `show`/`diff`/`restore`.
- [ ] **GEP-37 `glorbo shell` Phase 1 — Supervisor + Runtime +
  EventBus.** Phase 0 shipped 2026-04-25 (v0.10.0): CLI verb
  wired, `term_ui ~> 1.0.0-rc` installed, `Glorbo.Shell`
  skeleton + placeholder banner + non-TTY guard, 4 dispatch
  tests. Phase 1 builds the OTP runtime (Shell.Supervisor,
  Shell.Runtime GenServer driving the term_ui render loop,
  Shell.EventBus pub/sub for per-LV drop-in views). Phase 2+
  ships views in drop-in parity order with the Phoenix
  dashboard. Sprint-sized; not autonomous-bounded.
- [x] **GEP-40 implementation (crown-jewels phase 1a).** Shipped
  2026-04-24: FileSpec schema (`done_when:`, `handoff_chain:`,
  `requested_by:`, `severity:`, `peer_review_required:` with
  append-only enforcement), `Actions.Tasks.assign/4` handoff-
  chain appender, `GlorboWeb.TaskChainLive` at
  `/companies/:co/tasks/:task_id/chain` with drift detection +
  peer-review event section. GEP-40 → Implemented.
- [x] **FileSpec.Formatter: preserve `|` block-scalar for
  multi-line strings.** Shipped 2026-04-25 (autonomous L3).
  `Glorbo.FileSpec.Formatter` now emits multi-line binary values
  (top-level + nested in list-of-maps items) as YAML `|` block
  scalars instead of double-quoted strings with literal `\n`.
  Idempotent across round-trips; covers `done_when:`,
  `handoff_chain[].reason`, and any other future paragraph
  field. 5 new tests in `formatter_test.exs`.
- [x] **GEP-41 implementation (crown-jewels phase 1b).** Shipped
  2026-04-24 across rounds J/K/N-1/N-2/N-3/O/P: CritiqueOps verb
  alignment, `Approvals.Gate` peer-review blocker + requested
  audit, `Actions.Tasks.record_peer_review_verdict`, severity
  auto-flip at create, Kanban `⧗ peer-review` pill, opt-in
  paragraph on 5 agent templates, chain-view peer-review section.
  GEP-41 → Implemented. Phase-3 reviewer auto-dispatcher stays
  future work.
- [x] **Agent template propagation (crown-jewels phase 1c).**
  Shipped across Round L (cairn-style + handoff to ceo/editor/
  researcher/provenance-auditor) and Round O (peer-review opt-in
  paragraph added to engineer/ceo/editor/researcher/provenance-
  auditor — 5/5). CritiqueOps is the reviewer side and keeps its
  pre-existing GEP-41 wording. Opt-in paragraph is canonical verbatim
  from GEP-41 D1 + a reminder that the flag is append-only.
- [x] **Global search should include scheduled-task tags.** Shipped
  2026-04-24 (autonomous round). `Glorbo.Search.scan_tasks/2` now
  reads `schedule:` alongside `title` (same ETS cache key), and
  `score_task/3` scores a schedule substring match at 35 (below
  title/id). Task labels decorate with `(<schedule>)` when the
  task has a schedule. 5 new tests in `search_test.exs`.
- [x] **Visual regression tests.** Shipped 2026-04-25 as
  GEP-44. `scripts/ui-baseline.sh` drives Playwright over 18
  LV routes, diffs against
  `test/fixtures/ui-baselines/current/` via pixelmatch, gates
  PRs in CI as informational drift annotations. Two env-
  dependent LVs (`/health`, `/providers`) are in `DIFF_SKIP`;
  remaining 16 sit at 0.048–0.311% drift on CI. Flipping to
  blocking-mode is gated on a 1–2 week soak (separate todo).

---

## Shipped this cycle (2026-04-21 to 2026-04-23)

- [x] #264 TaskLive history panel + AuditLive ?q= deep-link
- [x] #268 TaskScheduler fires scheduled dispatches
- [x] #269 UI pass: modal __body CSS, topbar overflow, `×` glyph
- [x] CLAUDE.md: agent-browser Bazzite workaround documented
- [x] GEP-24 retrofit + TaskLive next-fire indicator (#270)
- [x] UAT Round 7 — 23 cases green via browser (UAT.md)
- [x] #271 Fix `glorbo up` crash on hosts without EPMD daemon
- [x] #272 UAT Round 8 — interactive (C2/C3/C6, D2/D5, G1–G3, M4) + 3 ships
- [x] Fix sidebar Approvals badge/list parity bug (UAT finding)
- [x] Audit log relative timestamps ("7 min ago" + title tooltip)
- [x] ESC key closes every modal
- [x] #273 UAT Round 9 — E3/E4/L1/L2/L3 green + 2 ships
- [x] Fix scheduler.invalid_task_cron audit flood (UAT finding)
- [x] Modal close-button hover affordance
- [x] #274 Round 10: TaskLive stuck-on banner
- [x] #275 Round 11: Kanban filter chip bar (project/goal/who)
- [x] #276 Round 12: Task-ID autolinking in comments
- [x] #277 Round 13: Heartbeat cron validation on agent config save
- [x] #278 Round 14: E2E scheduled-task dispatch test (was partial — lacked live E2E proof)
- [x] #279 Round 15: E2E LoopDetector sentinel emission test (was partial — fs_fun stubbed)
- [x] #280 Round 16: NL schedule parser (was partial — display accepted NL but firing needed cron)
- [x] #281 Round 17: GEP-21 memory reading MVP (read path only; write path is R17b)
- [x] #284 R17b: GEP-21 memory write path (outbox routing + Router classifier + atomic write + MEMORY.md upsert + audit)
- [x] #284 R17b UI: Memory tab on AgentLive detail page
- [x] #285 R17c: E2E memory — real qwen agent reads AND writes memory via live opencode dispatch
- [x] #286 E2E backfill: NL schedule fire + kanban chips navigate + task-ID autolink resolve
- [x] #283 R19a: GEP-23 per-agent network_allow extensions (company-coarsened; per-requester is R19b)
- [x] #288 R20: memory-count sidebar badge (✎ N next to slug when ≥1 memory file)
- [x] #289 R21: unified loop-detector resolution (single LoopDetector.resolve/5 entry; apply_resolution_files/3 honours documented file-drop protocol)
- [x] #290 R22: sidebar memory badge — fa-brain icon + aria-label singular/plural + 3 regex test cases
- [x] #291 R23: R21 audit-row regression fix (nil audit_fun coercion + catch :exit + per-company Registry resolution)
- [x] #292 R24: truthful Inbox header ("N approval · M stuck" / "(empty)") + relative last-failure timestamp on stuck rows
- [x] v0.0.4 shipped — release tagged, GitHub Release live with Burrito binaries
- [x] #294 R25: goal `name:` accepts as title fallback (GoalsLive + CompanyLive); UAT pass on Skills/Costs/Goals/BrainDump clean
- [x] #295 GEP-25 drafted: file format specs + `glorbo validate` + `glorbo fmt` + `kind:` discriminator (k8s-inspired) + atomic cut plan
- [x] #296 R26.1: FileSpec behaviour + 15 per-kind spec modules (company/agent/project/task/heartbeat/soul/memory-index/memory-entry/sentinel-approval/sentinel-stuck/sentinel-resolution/braindump/channel-log/audit-event/inbox-archive — all `/v1`); 28 tests; no writer changes yet
- [x] #298 R27: FileSpec.Validator + `glorbo validate` CLI (read-only; 10 check codes; NDJSON output; verified 27 missing_kind errors against pre-cut r22 workspace)
- [x] #299 R28: TaskMd regex widened (now matches `*.md` under `tasks/` like the real parser) + `skill/v1` FileSpec module + `:non_canonical_task_filename` info finding; 16 kinds total
- [x] #300 R29: Homebrew tap at foobarto/homebrew-tap (`brew install foobarto/tap/glorbo`) + `mix glorbo.release_formula` auto-regen task
- [x] R30.1: macOS build plumbing — Burrito darwin targets + GHA `build-macos` matrix job + `Sandbox.Bwrap.availability/0` probe + formula renders `on_macos do` block
- [x] #302 R30.2: `Glorbo.Sandbox.Unsandboxed.start/2` + Dispatch fallback + per-company once `agent.sandbox_unavailable` audit + Doctor reclassification (linux-only checks → `:info` severity on darwin); macOS binaries now functional in degraded mode
- [x] **Full browser E2E functionality test (post-R30.2 chore).** Ran
  2026-04-25 (autonomous L4) under Playwright MCP from inside the
  Ubuntu distrobox. Smoke covered `/companies` (200 + Companies
  cards render), `/companies/acme/kanban` (200), `/companies/acme/
  agents/ceo` (200), `/providers` (200), `/companies/acme/audit`
  (200), `/companies/acme/proposals` (200), `/companies/acme/
  inbox` (200), `/health` (200), Ctrl+K command palette open + live
  filter (`/api/search?co=acme&q=ceo` → 200). Console clean across
  navigations; 0 LiveView mount errors. Doctor: 10 pass, 1 warn
  (`uidmap`: newuidmap missing in distrobox), 1 fail (`pasta`:
  passt missing in distrobox) — both expected omissions of a
  fresh distrobox, not regressions. CLAUDE.md §"Browser UAT" +
  uat.md §"Browser environments" updated to record the distrobox
  path as preferred.
- [x] #297 R26.2a: atomic `kind:` cut — writers. Every writer emits
  `kind: <name>/v1` (scaffolders, init, router, audit, memory, sentinels,
  brain-dump, chat rotation, kanban/company/project/channel editors,
  task scheduler, DM channel). Router rejects missing `kind:` on task
  + memory outbox. 1394/1394 green.
- [x] R26.2b: atomic `kind:` cut — per-kind golden fixtures for every
  FileSpec kind. Shipped 2026-04-24 (autonomous round). Added 12
  missing fixtures (sentinel-stuck, sentinel-resolution,
  task-comments, inbox-message, inbox-archive, audit-event,
  agent-memory-index, benchmark-run, config, emergency-stop,
  proposal, path-request). All 24 kinds now have minimal_valid
  fixtures; 71/0 in golden_fixtures_test.exs. Fixed a pre-existing
  formatter bug surfaced by list-of-map frontmatter (path-request's
  `paths:`): continuation keys now align with the first key instead
  of the dash column. Precommit wiring is NOT in this pass —
  `mix glorbo.docs.file_formats` + `glorbo fmt --check` already
  exist but the precommit alias was not touched; filed as a
  follow-up if the user wants it.
- [x] #306 R33: FileSpec.Formatter + `glorbo fmt [--check|--write]` — canonical YAML key ordering, fence normalisation, idempotent, atomic writes; 14 unit tests + 2 CLI smoke tests
- [x] **Threatmodel waves 1–3 (2026-04-22).** Shipped across 3
  commits: wave-1 T1–T15 + UAT B1–U1 + `:api_only → :proxy`
  rename + GEP-31 draft; wave-2 H4–H12 + M25/M35/M36/M40/M41 from
  Codex scan; wave-3 M02–M21 (isolation + secure defaults + input
  hardening). 51 lower-severity findings remain open under
  `docs/testing/threatmodel.md`.
- [x] **Threatmodel wave 6 (2026-04-23).** Shipped 4 medium
  closures across ACLMapper scope validation, Skills resolver
  regular-file checks, watcher/reindex lstat discipline, and
  config/log 0600 + doctor warning; also dropped 3 stale medium
  rows that were already fixed at HEAD (`create_agent` YAML guard,
  proposal extra-key filter, restore symlink-target guard).
- [x] **Threatmodel wave 7 (2026-04-23).** Shipped 4 medium
  closures across Kanban `open_task` strict path + lstat guards,
  release-formula SHA256 validation, canonical agent budget block
  enforcement in Parser/BudgetTracker, and backup temp+rename
  0600 finalization.
- [x] **GEP-32 phase 1 (2026-04-23).** Shipped native-provider
  runtime support inside the existing bwrap dispatch path:
  `kind = "native"` providers, internal `glorbo harness`,
  built-in `openai` + `openrouter`, tracked native usage JSON, and
  the initial `read_file` tool loop.
- [x] **v0.1.0 shipped.** First minor since v0.0.4: GEP-32 phase 1
  plus the post-v0.0.4 threatmodel hardening batches are now rolled
  into the release docs/version surface.
- [x] **GEP-32 dependency — doctor checks native credential perms.**
  `private_files` now covers `~/.local/etc/glorbo/credentials/*.toml`
  (or `GLORBO_CREDENTIALS_DIR`), and the fixer chmods those files to
  `0600` alongside `config.md` and `logs/glorbo.log`.
- [x] **GEP-32 phase 2a (2026-04-23).** Native harness filesystem
  tools now cover `write_file`, `edit_file`, `glob`, and `grep`
  alongside `read_file`; the native usage contract gained sanitized
  `audit_events`, and Dispatch replays those tool audits into the
  company audit log.
- [x] **GEP-32 phase 2b (2026-04-23).** Native
  `bash` and `web_fetch` now run inside the existing sandbox/runtime
  contract; provider + tool HTTP requests honor per-agent timeout/retry
  knobs; and `tool.bash` / `egress.web_fetch` events replay through the
  same sanitized `usage.json` path.
- [x] **v0.4.0 shipped.** Fourth pre-1.0 minor: GEP-32 phase 2b is now
  on the release surface, along with the follow-up medium hardening
  batch that closed proxy mailbox, console cookie, stdout streamer,
  search cache, archive list, and stuck-sentinel findings.
- [x] **Threatmodel medium queue cleared (2026-04-23).** Wave 8 closed
  the remaining three medium findings: MCP session lifecycle bounds,
  file-only provider binary binds, and GitHub Action SHA pinning.
- [x] **v0.4.1 shipped.** Patch release for the completed medium sweep
  and the earlier budget-ledger scoping fix.
- [x] **v0.2.0 shipped.** Second pre-1.0 minor: GEP-32 phase 2a is now
  on the release surface.
- [x] **GEP-31 shipped (2026-04-23).** Linux `network: proxy` now
  wraps the existing bwrap launch in `pasta --splice-only`, exposes
  only the per-company proxy port inside the agent netns, refuses
  proxy dispatch when `pasta` is missing, and rewrites the proxy
  integration suite around blocked host loopback reachability.
- [x] **v0.3.0 shipped.** Third pre-1.0 minor: GEP-31's enforced
  proxy-only Linux networking is now on the release surface.
- [x] **v0.5.0 shipped (2026-04-23).** Fifth pre-1.0 minor:
  GEP-32 phase 3+4 complete (`ModelCatalog` cache + `detect-providers`
  CLI + Scan-localhost UI + Enable flow that appends to
  `~/.glorbo/providers.toml`), GEP-25 R26.2b golden fixtures
  expanded to 12 kinds, GEP-15 atomic cut (lowercase
  `agent.md` fallback deleted), GEP-12/15/21/31/32 statuses flipped
  to Implemented, AgentLive model combobox populated from
  `provider_models`, AgentLive network dropdown fix (UAT finding),
  pasta probe tightened to require `--splice-only`, CI release
  path repaired (setup-beam v1.24.0, skip-pattern fix), Homebrew
  tap auto-publish job via `HOMEBREW_TAP_TOKEN`.
- [x] **macOS cross-compile from Linux.** Shipped `build-macos-cross`
  ubuntu-24.04 matrix that produces both darwin Mach-O binaries
  via Burrito's Zig cross-compile path. Verified with `file` check
  per arch; artifacts + signatures + tap formula all flow through
  the normal release plumbing.
- [x] **v0.6.0 shipped (2026-04-23).** Sixth pre-1.0 minor. Five
  shipping flags beyond v0.5.0: macOS binaries via Linux-hosted Zig
  cross-compile; GEP-28 ProposalsLive + auto-approve-hire-within-
  headcount-budget (GEP-28 → Implemented); GEP-26 Phase B
  Director-facing scoring slice (`/benchmarks` + blind A/B
  BenchLive); GEP-25 R26.2b parser enforcement (kind: agent/v1 +
  task/v1 now required on every agent/task frontmatter; GEP-25 →
  Implemented); GEP-23 Egress.History per-company verdict cache.
- [x] **GEP-23 `network:` enum rename** (shipped 2026-04-23 in
  `802bc25`). Atomic cut: parser, bwrap typespec + `network_flag/1`,
  AgentLive/CompanyLive editors, AgentMd FileSpec enum, ~20 test
  fixtures. `kbps_cap` throttle ships separately.
- [x] **GEP-23 `egress.kbps_cap` — won't-fix (2026-04-25).**
  Maintainer declined: kbps throttling is overkill for the single-
  user, single-host posture Glorbo targets; the host-only proxy
  isn't a transit point worth shaping. GEP-23 history updated to
  record the decision; the spec line stays as a documented opt-out
  but no implementation path is planned.
- [x] **GEP-26 Phase B dispatch orchestrator** (shipped 2026-04-23).
  `glorbo bench run <template> <task-id> --providers a,b,c
  [--keep-shadow]` now forks N shadow companies rooted at the
  template, pins each agent's `provider:` + substitutes AGENT.md
  placeholders, fires the task through `Agent.Dispatch.execute/3`,
  and writes outputs as `kind: benchmark-output/v1` under
  `benchmarks/runs/<id>/providers/<p>/output.md`. Manifest
  `status:` flips `in-progress → completed|failed`. GEP-26 →
  Implemented.
