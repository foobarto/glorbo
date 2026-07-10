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

- [x] **`~/.glorbo/config.md` is 0 bytes — default dev dashboard locked out.**
  FIXED 2026-06-14 (GEP-0060 branch, commit `5218925c`): `Glorbo.Config.load`
  (+`erl_cookie`/`node_id`) now self-heal an empty/unparseable config.md
  (regenerate when the parser yields empty meta, preserving any prior body to
  `config.md.bak`), and a one-shot endpoint child prints the
  `…/setup?token=…` URL only when an HTTP server is actually starting in
  bootstrap/degraded mode. A fenced-but-bad file still fails closed
  (GEP-0053 D9). Shipped alongside the SymlinkGuard `/home→/var/home` fix.

## P1 — next cycle

<!-- Promoted from session journals 2026-06-14 (before clearing them). -->

- [ ] **Auth HTML forms (setup/login) don't submit via browser
  automation.** The first-run `/setup` + `/login` forms failed to submit
  under browser automation in the 2026-06-13 web-ui UAT; may also bite real
  users with password managers / autofill. Repro + fix the form submit path.
  (from `2026-06-13-web-ui-uat-report`)
- [ ] **Security nits from the v0.25.0 review (still open).** (1) GEP-54 D9
  — the paperclip-import dest guard should `lstat` the *leaf*, not just
  ancestors; (2) `import_paperclip` TOCTOU — harden the fd handling on the
  copy path. Low-severity but real. (from `2026-06-03-v0250-release`)
- [x] **GEP-36 task editor mutation gap.** Closed 2026-07-10:
  `Glorbo.Actions.Tasks.update/4` now owns both task editors, performs one
  atomic rewrite, and the frontend Credo ratchet covers indirect domain-file
  writers as well as raw `File.*` calls.
- [ ] **Remaining deferred GEP↔code capability gaps** (detail in the gap
  report, `docs/sessions/2026-06-14-gep-codebase-reconciliation.md`): GEP-41
  standalone peer-review trigger, GEP-23 egress audit+sentinel, and GEP-46
  concurrency integration tests. (from `2026-06-14-gep-gap-implementation`)

- [ ] **Statusbar health contradicts sidebar badge.** Footer shows
  `daemon stale pidfile` (red) while sidebar reads “all systems
  operational” (green); agent counts oscillate without matching running
  processes. Violates observability “no lying zeros” stance. UAT
  2026-06-13 — unify daemon/agent health across statusbar, sidebar, and
  `/health`.

- [x] **`mix phx.server` prints the bootstrap URL when config is empty.**
  Closed 2026-07-10 by `GlorboWeb.SetupBanner`; non-server Mix tasks and
  configured nodes do not leak the token.

- [ ] **Keep `goto-bus-stop/setup-zig` compatible with GitHub's current
  JavaScript action runtime.** The action is SHA-pinned in release jobs;
  periodically check upstream runtime support, bump the pin deliberately,
  and verify all cross-build targets before the next release.

- [x] **`SymlinkGuard` false-positive on `/home → /var/home` (atomic
  Fedora).** Closed 2026-06-14 by the GEP-60 home-resolution change; the
  guard still rejects symlinks below the trusted Glorbo root.

- [x] **Agent-detail page re-render thrash while working.** Reported
  2026-05-21; the specific `document.scrollHeight` oscillation could not
  be reproduced (measured stable 900 px under load). Root cause addressed
  2026-05-22 regardless: `AgentLive` re-rendered the full detail panel
  synchronously on **every** `:agent_status` flip for the viewed agent
  (un-coalesced `load_agent_detail` + `@detail` reassign), so a looping
  agent thrashed the panel several times/sec. Now coalesced via
  `schedule_coalesced_reload(:coalesced_detail_reload, …, :detail_reload_pending?)`
  (250 ms window), working-on stamped from an unrendered pending assign.
  If the operator's symptom persists, it's a *different* (likely CSS /
  narrow-viewport) cause — still need: which tab, viewport width,
  streaming-vs-looping.
- [x] **Modal click-drop under rapid `agent_status` churn.** Fixed
  2026-05-22. `CompanyLive` now coalesces `:agent_status` through a
  *light* reload on a dedicated latch (`:agent_reload_pending?`) and
  defers it while a modal is open (re-arm on close) — the option the
  prior note flagged as "needs care." The naive full-coalesce regression
  was avoided by keeping the reload light (`load_agents` only, not
  `load_company_data`) and giving it its own latch. The "working on …"
  roster line is now backed by a durable `working_on_by_slug` overlay
  re-applied by both the `:file_event` and `:agent_status` reload paths
  (codex caught that a file_event reload would otherwise erase it). 7 new
  tests (4 CompanyLive, 2 AgentLive, 1 LiveHelpers).
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
- [x] **Scheduler rescan is O(projects × tasks) every 60s.** Shipped
  2026-05-04. `TaskScheduler.scan_one/2` now lstats first; if the
  file's mtime matches the cached entry AND its armed timer is still
  live (`Process.read_timer/1` > 0), the read + frontmatter + cron
  parse are skipped entirely. Mirrors the `Search.scan_tasks` mtime
  cache pattern. `read_timer_fun` injection seam added so tests
  exercise both the cache-hit and cache-miss paths deterministically.
  3 new perf tests on top of the existing 15.
- [x] **GEP-45 Phase 1a — stado provider registry entry + ACP prompt_mode.**
  Shipped 2026-05-04 in `f7eaf6b`. `Provider.@prompt_modes` gains `:acp`,
  Loader accepts `"acp"`, `priv/providers/stado.toml` declares stado as
  built-in. Dispatcher short-circuits `prompt_mode: :acp` with a
  structured `:unimplemented_prompt_mode` error pointing at Phase 1b.
- [x] **GEP-45 Phase 1b foundation — ACP framing + message types.**
  Shipped 2026-05-04 in `21b994d`. `Glorbo.CLI.Dispatcher.Acp.{Framing,
  Message, RpcError}` ship the wire-format half: tagged-tuple message
  shapes, line-delimited JSON encode/decode, partial-line buffer
  handling. 20 unit tests. Pure code; no I/O.
- [x] **GEP-45 Phase 1b client — JSON-RPC client state machine + mock
  peer.** Shipped 2026-05-04 in `18dcfcc`.
  `Glorbo.CLI.Dispatcher.Acp.Client` drives the conversation via an
  injected `%Client.IO{}` (read/write/close callbacks):
  initialize → session/new → session/prompt → drain text chunks
  → shutdown. Reply assembly via `update.kind == "agent_message_chunk"`.
  Errors map to `:provider_protocol_error` / `:provider_returned_error`
  / `:provider_timeout`. 16 mock-peer tests.
- [x] **GEP-45 Phase 1b sandbox + dispatcher — bwrap port without
  prompt-tempfile + Dispatcher.invoke integration.** Shipped 2026-05-04
  in `80826e5`. `Glorbo.Sandbox.Bwrap.start_acp/2` opens the bwrap'd
  Port without the stdin redirect; `Glorbo.CLI.Dispatcher.Acp.PortIO`
  wraps it as a `%Client.IO{}`; the dispatcher's ACP branch replaces
  the Phase 1a stub with a real run loop and adds an `:acp_run_fun`
  injection seam mirroring the existing `:run_fun`. 7 new tests
  (5 PortIO + 2 sandbox end-to-end with a fake-ACP shell script).
- [x] **GEP-45 Phase 2 — bench-acp stado smoke + bench.** Shipped
  2026-05-04. Integration test at
  `test/integration/gep_45_stado_bench_test.exs` drives the real
  stado-pinned binary through the full glorbo→stado ACP path; passes
  on either full-reply or handshake-only outcome (the latter is the
  load-bearing assertion when stado has no inference backend
  configured). Bench docs at `docs/research/gep-45-bench-acp.md`.
  Audit-log capture of the ACP exchange carried into Phase 3.
- [x] **GEP-45 Phase 3 — operational polish.** Shipped 2026-05-04
  across three slices: audit-log capture (`Acp.Client` accepts an
  `:audit_fun` callback emitting `cli.acp.<role>.<kind>` lines per
  frame; dispatcher result carries `acp: %{session_id, chunks,
  ignored_updates}`), GEP-32 catalog wiring (new `model_list.shape =
  "static"` so stado advertises 13 model aliases that surface in the
  LV combobox without an HTTP probe), and the `stado_acp` usage
  parser (shells out to `stado stats --session <sid> --json` after
  each dispatch, maps to canonical `Parsers.usage()` plus
  `cost_usd` + `duration_ms` extras for the budget ledger).
  Requires stado >= 0.27.x for the `stats --json` flag.
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
- [x] **GEP-34 Phase 3 — `budgets` rebuild from audit JSONL.**
  Shipped 2026-04-26. `Reindex.run/1` sums `budget.usage` lines
  per `{company_slug, agent_slug, year_month}` (year_month
  derived via the writer's own `Budget.Ledger.month_bucket/1`).
  Discovered the spec's `usage.recorded` audit action name
  doesn't match the writer (`budget.usage` is what
  `Company.BudgetTracker` actually emits) — replay uses the
  real name. The `alerts_fired` bitmap concern is moot — that
  state lives in tracker GenServer state, not the schema, and
  rehydrates from `alerts/*.md` on boot. 8 new tests cover
  single-event, multi-event sum, multi-month split, multi-agent
  split, cross-company isolation, idempotency, non-budget-line
  filtering, missing-token defaulting. GEP-34 D6+D7 captured.
  **GEP-34 → Implemented.** Every gap-table identified in the
  GEP is now derived from the on-disk source.
- [x] **Phase 1 `_system` audit reindex path mismatch fixed
  2026-04-26.** Aligned reindex with the writer's canonical
  layout: `rebuild_audit_events/1` now reads
  `<base>/audit/_system/*.jsonl` instead of
  `<base>/audit/*.jsonl`. Updated the stale reindex_test that
  wrote to the flat path; added a defensive test confirming
  flat-path files are ignored. Doctor / FileSpec / portability
  fixtures all already use the subdirectory layout, so reindex
  was the lone outlier.
- [x] **Wave 29 (post-v0.12.0): audit-dir walks lstat'd.**
  Self-review of the just-shipped GEP-34 code surfaced a
  defense-in-depth gap: `Reindex.rebuild_audit_events/1`,
  `rebuild_tasks_approval_state/1`, and `rebuild_budgets/1`
  used `File.dir?/1` (follows symlinks) on
  `companies/<co>/audit/` and `<base>/audit/_system/`. Single
  `safe_audit_dir/1` helper now routes all three call sites
  through `AgentWritableFile.any_symlink_in_path?/1`. 2 new
  tests cover both per-company + `_system` symlink rejection
  paths. Closed in [Unreleased] CHANGELOG block; threatmodel
  cumulative tally bumped to 95 / 29 waves.
- [x] **Wave 30 (post-v0.12.0): JSONL slug fields validated
  during replay.** Second self-review pass: writer-side
  enforces canonical slugs on JSONL `company:` and `agent:`
  fields, replay-side did not. `safe_company_slug/2` +
  `safe_agent_slug/1` helpers added and wired through Phase
  1/2/3. Phase 3 also rejects `_system` company (budgets are
  strictly per-company). 6 new tests; cumulative tally 96 /
  30 waves.
- [x] **Wave 31 (post-v0.12.1, MEDIUM): cross-company bleed in
  tasks_approval_state.** Third self-review pass: the schema
  had unique index on `task_path` alone, no `company_slug`
  column. Two companies with awaiting tasks at the same
  relative path collided silently; director approve/deny
  flipped the wrong company's state. CLAUDE.md "Company
  isolation is absolute" violation. Migration drops + recreates
  the table with composite `(company_slug, task_path)` unique
  index; Gate's three call sites + Reindex Phase 2 fold all
  scope by company now. 2 new isolation tests; cumulative tally
  97 / 31 waves.
- [x] **Wave 32 (post-v0.12.2, MEDIUM): JSONL `company:` spoof
  defeats wave-31 isolation.** Fourth self-review pass: wave
  30's `safe_company_slug/2` let JSONL `company:` override the
  dirname when both were valid slugs. Combined with wave 31's
  `(company_slug, task_path)` index, that meant an attacker
  who wrote one line into company A's audit dir with
  `company: "B"` could create a spoofed row in company B's
  projection — defeating the isolation. New
  `dirname_company_slug/1` helper makes the on-disk dirname
  canonical for Phase 2 + 3; Phase 1 keeps wave-30 semantics
  (audit_events legitimately stores cross-routed events).
  2 new spoof-rejection tests; cumulative tally 98 / 32 waves.
- [x] **Wave 33 (post-v0.12.3, MEDIUM): Phase 1 audit_events
  also locks dirname.** Fifth self-review pass: wave 32 left
  Phase 1 on `safe_company_slug` with the rationale that
  audit_events legitimately stores cross-routed events. On
  reflection that argument applies only to the writer side
  (which routes by JSONL `company:`); the reader's dirname
  has already encoded the canonical company. Same spoof
  worked in Phase 1 — attacker writing into acme's audit dir
  with `company: "beta"` polluted beta's dashboard audit
  feed. New `audit_company_slug/1` makes the dirname
  canonical for Phase 1 too (with `_system` allowance for
  the system audit dir). `safe_company_slug/2` removed, no
  callers left. 1 new test; cumulative tally 99 / 33 waves.
- [x] **Wave 34 (post-v0.12.4, LOW): BudgetTracker alert
  rehydrate uses filename canonically.** Cross-area review:
  same dirname-vs-content pattern in
  `BudgetTracker.parse_alert_key/2`. Reading `agent:` from
  frontmatter let an operator-tampered `editor-budget.md`
  with `agent: "ceo"` populate the MapSet with the wrong
  key, silently suppressing ceo's real alert for that month.
  Filename is now canonical via
  `agent_from_alert_filename/1`. 1 new test; cumulative
  tally 100 / 34 waves.

## P2 — nice to have

- [ ] **Approval queue: file-glob (inbox) vs DB-row (Gate) source-of-truth.**
  The inbox lists pending approvals from `agents/*/state/awaiting-approval-*.md`
  file globs; `Approvals.Gate.resolve_status` grants by a `tasks_approval_state`
  **DB row** (`find_awaiting_row`). A backless sentinel shows an approve button
  whose grant audits `approval.spurious` and never clears the sentinel / wakes
  the agent. **REASSESSED 2026-06-14 (reproduce-first): not reachable in normal
  operation** — `Gate.request_approval` (sole caller `Router.maybe_request_approval`,
  router.ex:1103) writes the sentinel + DB row + audit together, and `reindex`
  rebuilds `tasks_approval_state` from the audit JSONL (`fold_approval_dir`), so
  file/DB stay consistent. A backless sentinel only arises from a filesystem
  hand-edit; harm is minimal (task IS marked approved; agent self-recovers on
  next inbox scan; inbox hides the orphan once status ≠ pending-approval). Every
  fix touches security-critical Gate-grant code or GEP-34's audit-fold rebuild —
  disproportionate to the benefit. **→ leave as-is, or a small source-of-truth
  GEP if the design inconsistency is worth cleaning up; not a quick patch.**
- [x] **Chat drawer: tail channels other than `#general`.** DONE 2026-06-14
  (`feat/chat-drawer-channel-switch`): header channel selector; the
  `chat_drawer_channel` event handled centrally via a `live_session` `on_mount`
  hook in `ChatDrawer.State` (no per-LV wiring across the ~19 hosts); the 5
  hardcoded `general` sites parameterized; localStorage persistence across the
  per-nav re-mount; server-side validation against the company's real channels.
  Browser-verified incl. cross-nav persistence. (from `2026-06-14-web-ui-e2e-uat`)

<!-- Promoted from session journals 2026-06-14 (before clearing them). -->

- [ ] **Director passphrase-auth open design questions (GEP-49).** Three left
  unanswered in the 2026-05-29 design: (1) session TTL — keep browser-close
  cookie or add a persistent cap + idle timeout (~7-day)? (2) re-scope GEP-49
  under the GEP-53 session-store layer, or keep independent? (3) `return_to`
  post-login bounce-back (same-origin-guarded) vs hardcoded `/`. (from
  `2026-05-29-director-passphrase-auth`)
- [ ] **`priv/uat_seed/` (or a `mix` task) for repeatable browser UAT.**
  Scaffold a project + task + approval + scheduled task + audit rows so the
  browser-UAT sweep is reproducible. (from `2026-06-13-web-ui-uat-report`)
- [ ] **Human-slug agent dir names.** Some imported companies (e.g.
  `bladeandblaster`) have UUID agent directory names; rename to human slugs
  (or leave to the operator). (from `2026-06-02-paperclip-instance-import`)
- [ ] **Fold the GEP-0063 `uat.md` K1/K1b goal-file update into the next
  UAT-sweep commit.** The 4-line UAT doc update for the file-canonical goals
  was deferred pending that commit. (from `2026-06-13-gep0063-goals-file-canonical`)

- [ ] **ProxyTokens: explicit token audience/scope field (GEP-0055
  follow-up).** GEP-23 CONNECT tokens and GEP-0055 inference tokens
  share one ETS table; today they're distinguished only implicitly
  (`provider_alias` nil vs set, and the CONNECT proxy treats tokens as
  audit-only). An explicit `audience: :connect | :inference` asserted
  inside `resolve/2` would make the separation unforgeable. Touches
  `Network.Proxy` too. Deferred from the 2026-06-10 review round.

- [ ] **OpenAIProxy: concurrent-handler cap.** The listener bounds
  per-request memory/time (16 KiB head, 1 MiB body, 15 s read
  deadline) but not the number of simultaneous handler processes.
  Loopback + per-company netns means only the company's own agents
  can connect, so this is hardening, not a hole. Revisit with the
  slice-5 streaming work (long-lived connections change the math).

- [ ] **ModelCatalog via_proxy refresh: route through the proxy for
  audit parity.** Today the catalog calls the upstream directly with
  the env key (host-side, same trust domain). Once GEP-0055 slice 7
  lands audit rows, consider routing list-models through the listener
  so all upstream traffic shares one audit path.

- [ ] **Post-0.25.0 review follow-ups (non-blocking).** From the pre-release
  adversarial review of the v0.25.0 diff (all LOW/nit, deferred past the cut):
  - GEP-0054 D9: optionally lstat the glorbo-home *leaf* itself (refuse a
    symlinked `~/.glorbo` final component) without re-walking OS ancestors —
    restores PR #38's leaf protection without the `/home → /var/home`
    false-positive. Documented as an accepted trade-off in GEP-0054 D9.
  - `import_paperclip` companion-file read is lstat-then-`File.read!`
    (narrow TOCTOU); close with `:file.read_link_info` on an open fd if a
    future hardening pass wants it. Not exploitable single-user.
  - CHANGELOG GEP-0053 entry reads as commit-by-commit accretion (4 blocks,
    hardening before the feature intro) — reorder into one coherent narrative.
  - GEP-29 `see-also` could gain `53` for link symmetry (GEP-0053 already
    backlinks 29). Cosmetic.
  - `assets/index.html` hard-codes the version in 3 spots; the Pages deploy
    auto-syncs it from mix.exs, so committed source drifts harmlessly — can
    `sed` it in sync at cut time if desired.

- [ ] **Peer-review `:reroute` verdict (or deep-revision-as-subtask).**
  From the multi-agent orchestration benchmark
  (`docs/research/2026-04-25-multi-agent-orchestration-comparison.md`):
  GEP-41 D6 enforces a single final verdict per review, which is
  awkward for 6+ round tasks. Add a non-final `:reroute` verdict or
  formalize deep-revision-as-subtask. Belongs in a GEP-41 follow-up.
- [ ] **Structured `handoff.note:` field on `Tasks.reassign/4`.** Same
  source. Glorbo's `reason:` is one line; paperclip carries ~20 lines
  of critique prose per handoff. Add a richer structured note field so
  reassignment can carry full critique context.
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

<!-- Promoted from session journals 2026-06-14 (before clearing them). -->

- [ ] **Widen `Agent.Dispatch` `@type dispatch_result`** to include the
  `:reply` / `:reply_path` variants (`agent/dispatch.ex:71`). Minor typing
  accuracy. (from `2026-06-12-gep-batch-elixir-1.20-warning-zeroing`)
- [ ] **Remove the stale untracked `priv/plts/`** leftover sitting in the
  worktree. (from `2026-06-10-gep0055-review-round`)
- [ ] **Reconstruct (or consciously skip) the missing GEP-0055 2026-06-07/08
  session journals** — decide whether the GEP history is enough. (from
  `2026-06-10-gep0055-review-round`)
- [ ] **Confirm Overview progress-bar semantics (GEP-0063).** Per-goal bars
  honour explicit `progress:`, while the `/companies` card % stays
  done-tasks/total-tasks — confirm that split is intended. (from
  `2026-06-13-gep0063-goals-file-canonical`)

- [x] **InotifyToBwrapHappyPathTest suite-pollution — root-caused
  + fixed (2026-04-25).** Wasn't pollution at all: an inotify
  watch-attachment race. `Watcher.start_link/1` returned before
  `inotifywait` had attached its kernel watches; concurrent
  scheduler load from preceding agent-spawning tests made the
  file write fire ahead of attachment more often, so events
  were silently dropped. The original 250ms settling sleep still
  raced on a loaded GitHub runner; the test now writes a non-task
  sentinel until it observes the Watcher's PubSub event, then retries
  the real task write until its `created|modified` event is observed
  before asserting dispatch.
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
- [x] **GEP-37 `glorbo shell` Phase 1 — Supervisor + Runtime +
  EventBus.** Shipped post-v0.12.5 (autonomous L4). Three new
  modules under `Glorbo.Shell.*` + Application conditional
  surface flip via `apply_surface/2` reading
  `:glorbo, :surface` config (`:web` default, `:tui` swaps
  Endpoint for Shell.Supervisor, `:headless` strips both).
  Supervisor uses `:rest_for_one` per D6: EventBus → Runtime
  (crash of EventBus restarts both; crash of Runtime
  restarts only itself). EventBus subscribes to per-company
  PubSub topics + `glorbo:companies` and forwards as
  `{:shell_event, raw_msg}` casts. Runtime accumulates last
  256 events; Phase 2 turns it into the term_ui app module.
  12 new tests covering init, accumulation, cap, forwarding,
  restart semantics, drop-on-runtime-down. 2300/2300 total.
- [x] **GEP-37 `glorbo shell` Phase 2 — Inbox view (read-only).**
  Shipped post-v0.12.5 (autonomous L4).
  `Glorbo.Shell.Views.Inbox` implements `TermUI.Elm` with
  cursor-navigated approvals list (arrows + j/k, q to quit,
  empty-state placeholder). `Glorbo.Shell.Views.Inbox.Data`
  is the disk-read layer mirroring `InboxLive.load_sentinels/2`
  + `sentinel_row/4`; sentinels without matching task files
  surface with `task_path: nil` so the Director can clear
  them via Phase 2b actions. 23 new tests (6 Data + 17 view).
  2323/2323 total. Phase 2b adds approve/deny/archive
  actions on top of the wave-31 Gate API; Phase 3 adds the
  remaining views.
- [x] **GEP-37 `glorbo shell` Phase 2b — approve/deny actions.**
  Shipped post-v0.12.5 (autonomous L4). Wires the Inbox view
  to `Glorbo.Actions.set_approval/4` (the wave-31 Gate API):
  `a` approves, `d` denies. Both paths are dependency-
  injected via `:approve_fn` + `:loader_fn` for testability.
  Defensive arms cover empty list, sentinel-without-task,
  missing company/base, and `set_approval`-returns-error.
  After success, the approvals list refreshes and cursor
  reclamps. 8 new tests. 2331/2331 total. Phase 2c brings
  the deny-reason prompt UX + term_ui.runtime.run wire-up
  so the Director can finally launch the shell.
- [x] **GEP-37 `glorbo shell` Phase 2c — deny prompt + Launcher.**
  Shipped post-v0.12.5 (autonomous L4). Inbox view gained
  a modal `:deny_prompt` mode: pressing `d` opens a
  buffer-driven prompt (chars append, Backspace drops last,
  Enter submits with `denial_reason:`, Esc cancels). New
  `Glorbo.Shell.Launcher` composes `TermUI.Runtime.run/1`
  opts from CLI argv (`glorbo shell <company>`) +
  `GLORBO_HOME`, with a mockable `:runner_fn`. Validates
  the company slug + the dir exists; returns
  `{:error, :usage | :unknown_company | {:invalid_slug,
  raw}}` on failure. `Glorbo.Shell.run/1` updated to call
  Launcher when argv is non-empty; surfaces error tuples
  as operator-friendly exit-2 messages. The no-argv path
  prints a placeholder-with-usage banner. 17 new tests
  (6 prompt arms + 11 Launcher). 2348/2348 total.
  Production launch path is TTY-bound; from a real
  terminal `glorbo shell acme` now invokes
  `TermUI.Runtime.run/1` for the first time. Phase 3
  adds the remaining views.
- [x] **GEP-37 `glorbo shell` Phase 3a — AppRoot + chord
  prefix.** Shipped post-v0.13.0 (autonomous L4).
  `Glorbo.Shell.AppRoot` is the new top-level Elm view
  that wraps per-view modules and owns the
  `C-c <letter>` chord-prefix state machine per D10's
  keybinding table (`:idle ↔ :c_c`). Ctrl+c flips into
  chord mode, next keystroke selects a view, Esc cancels.
  Unknown / Phase-3b+ chords surface a `chord_hint` footer
  line; only `p` (Approvals = Inbox) actually routes in
  Phase 3a. Launcher updated to use AppRoot as root
  instead of Inbox directly. 18 new tests; 2366/2366 total.
  Phase 3b adds Health as the second view to validate the
  chord-driven swap.
- [x] **GEP-37 `glorbo shell` Phase 3b — Health view.**
  Shipped post-v0.13.0 (autonomous L4).
  `Glorbo.Shell.Views.Health` mirrors `glorbo doctor`
  output: one line per check with pass/fail glyph +
  severity tag, cursor-navigated, `r` to refresh. AppRoot
  registers `:health` in `@views_implemented` and routes
  `C-c h` → Health, `C-c p` → Inbox. View swap forwards
  `:base` + `:company` opts to the new view's init.
  `init/1` gained `:initial_view` opt for non-default
  starts. 16 new tests (13 Health + 3 AppRoot swap
  semantics); 2382/2382 total. End-to-end in a real TTY:
  `glorbo shell acme` boots Inbox, `C-c h` swaps to
  Health, `C-c p` swaps back. Phase 3+ adds remaining
  views one at a time (overview, tasks, agents, chat,
  audit) following the same pattern.
- [x] **GEP-37 `glorbo shell` Phase 3c — Overview view.**
  Shipped post-v0.13.0 (autonomous L4). Cross-company
  workspace list (one row per `companies/<slug>/`):
  `slug (name) — N agents, M alerts`. Active company
  highlighted with `*`; cursor lands on it on first paint.
  `r` refreshes; `q` quits. FS-only read (no Repo
  dependency); spend/in-progress/goals columns deferred
  to Phase 3d. AppRoot registers `:overview` in
  `@views_implemented`; `C-c o` is now a real swap.
  26 new tests (9 Data + 16 view + 1 AppRoot swap-target
  fixture refresh). 2408/2408 total. Phase 3+ continues
  with tasks/agents/chat/audit one at a time.
- [x] **GEP-37 `glorbo shell` Phase 3d — Agents view.**
  Shipped post-v0.13.0 (autonomous L4). Per-company
  roster: `<slug> [<role>] <provider>/<model> · <network>
  → <reports_to>` (the trailing `→ ...` only when set).
  FS-only read of `agents/<slug>/AGENT.md` (or legacy
  `agent.md`); `.archive/` + dotfile dirs hidden; agents
  without an AGENT.md are not surfaced (not bootable).
  `r` refreshes; `q` quits. AppRoot wires `C-c a` →
  agents. 24 new tests (10 Data + 14 view); 2432/2432
  total. Phase 3e widens to budget tracking +
  last-wake (Repo-backed columns); Phase 3+ continues
  with tasks/chat/audit.
- [x] **GEP-37 `glorbo shell` Phase 3e — Audit view.**
  Shipped post-v0.13.0 (autonomous L4). Current-month
  JSONL tail rendered as a cursor-navigated event log:
  `[<ts>] <actor> <action> <target>`. Bounded-memory
  read mirrors `GlorboWeb.AuditLive.load_tail/2`. ts
  trimmed to 16 chars; empty target omits trailing space;
  malformed lines skipped silently. AppRoot wires
  `C-c u` → audit. 22 new tests (7 Data + 15 view);
  2454/2454 total. Phase 3f adds the live-tail EventBus
  subscription + older-page navigation; Phase 3+
  continues with tasks/chat.
- [x] **GEP-37 `glorbo shell` Phase 3f — Chat view.**
  Shipped post-v0.13.0 (autonomous L4). Per-channel
  message stream (default `general`): header `#<channel>`,
  one line per message `[<ts>] <author>: <first body
  line>`. Multi-line bodies collapsed to first line for
  the cursor list (Phase 3g adds Enter-to-expand + the
  slash-command composer). `Chat.Data` mirrors the LV's
  `## <ts> | <author>` regex contract; `list_channels/2`
  enumerates available channels for the future switcher.
  AppRoot wires `C-c c` → chat. 27 new tests (11 Data +
  16 view); 2481/2481 total. Phase 3+ continues with
  the `:tasks` kanban flagship (last remaining
  GEP-37 view).
- [x] **GEP-37 Phase 3c-revisit — Overview+ spend column.**
  Shipped post-v0.15.0 (autonomous L4).
  `Overview.Data.load_companies/2` now sums each
  company's current-month spend across agents via
  `Glorbo.Budget.Ledger.fetch/3`. View appends `, $X.YZ
  spent` after the alerts column when spend > 0. Fail-open-
  with-0 + `:ledger_fetch_fn` injection (same pattern as
  Agents+). 7 new tests (5 Data + 2 view).
  `in_progress_count` + `goals_summary` columns are still
  future work (walk every task per company; defer until
  read pattern stabilises).
- [x] **GEP-37 Phase 3d-revisit — Agents+ budget
  columns.** Shipped post-v0.15.0 (autonomous L4).
  `Agents.Data.load_agents/3` now reads
  `budget.monthly_usd` from agent frontmatter (normalised
  to cents) + current spend from
  `Glorbo.Budget.Ledger.fetch/3`. View renders
  `· $used.dd/$cap.dd` after the network column when a
  cap is declared; agents without a cap stay visually
  distinct. Ledger calls wrapped in rescue → 0 so view
  renders even without a Repo connection.
  `:ledger_fetch_fn` opt for testability. 9 new tests
  across Data + view (cap normalisation int/float/string,
  ledger routing, year_month override, fail-open on Repo
  raise, view with/without cap). Last-wake column +
  pill-status are still future work.
- [x] **GEP-37 Phase 3f-revisit — Chat composer modal.**
  Shipped post-v0.15.1 (autonomous L4). `i` opens a
  modal composer; chars accumulate into a buffer, Enter
  posts via `Glorbo.Actions.post_message/4`, Esc cancels.
  Same modal shape as the Inbox deny prompt. State carries
  `mode :: :list | {:compose, buf}` + `last_action`;
  successful posts refresh the list and render `✓ posted`,
  failures render `✗ post failed: <reason>` without
  clobbering the existing list. `:post_fn` injection so
  tests don't shell out. 11 new tests (chat_test only —
  no new Data tests since composer is write-side).
  Channel switching + slash-command parsing are still
  future work.
- [x] **GEP-37 Phase 3f-revisit-2 — Chat channel switcher.**
  Shipped post-v0.15.1 (autonomous L4). `s` in list mode
  opens a switcher modal: j/k navigate the on-disk channel
  list, Enter switches and reloads via the existing
  `:loader_fn` seam, Esc cancels. Cursor seeds on the
  current channel. State now carries
  `mode :: :list | {:compose, buf} | {:switch, %{channels,
  cursor}}`. `:list_channels_fn` injection so tests skip
  the filesystem. 8 new tests; 35 total in chat_test.exs.
- [x] **GEP-37 Phase 3f-revisit-3 — composer slash commands.**
  Shipped post-v0.16.0 (autonomous L4). Composer parses
  `/`-prefixed buffers as commands: `/switch <ch>` (swap
  channel, reload), `/help` (advertise commands on the
  action line), `/cancel` (silent exit alias for Esc).
  Unknown command / unknown channel / missing argument
  surface as `{:error, :command, _}` last_action variants
  with dedicated render strings. Leading-whitespace+`/`
  buffer is still treated as a regular post (only a leading
  `/` invokes the parser). Composer hint line now mentions
  `/help`. 8 new tests; 43 total in chat_test.exs.
- [x] **GEP-37 Phase 3a-revisit — AppRoot help overlay.**
  Shipped post-v0.17.0 (autonomous L4). `?` in idle mode
  toggles a full-screen keymap reference covering chord
  prefix, list nav, and per-view modal triggers (Inbox /
  Chat / Audit). Esc or `?` dismiss; all other keys are
  absorbed while open (no underlying-view leakage).
  AppRoot state gains `:help_open` boolean. 5 new tests;
  2584 total.
- [x] **GEP-37 Phase 3e-revisit — Audit older-page navigation.**
  Shipped post-v0.17.0 (autonomous L4). `p`/`n` step the
  Audit view through month buckets; header shows active
  month + directional hints. State carries `:year_month`
  + `:available_months`. `Audit.Data.load_tail/3` migrated
  from positional N to keyword opts (`:year_month`, `:n`);
  loader_fn seam is 3-arity. New `Audit.Data.list_year_months/2`
  enumerates on-disk buckets, filters malformed names,
  always seeds current month at index 0. 12 new tests;
  2579 total.
- [x] **GEP-37 Phase 3g-revisit — Tasks status pill.**
  Shipped post-v0.16.0 (autonomous L4). Every task row now
  carries a single-char status glyph between the cursor
  prefix and the task id (· todo, ▸ in-progress, ? pending,
  + approved, ✗ denied, ✓ done). The four review-lane
  sub-states (pending / pending-approval / approved / denied)
  are now visually distinguishable inside the same lane.
  `Tasks.Data.status_glyph/1` is the new helper. 9 new tests
  (1 view + 8 Data). Last-wake column still future work
  (would need agent mtime/ledger reads per task — defer
  until read pattern stabilises).
- [x] **GEP-37 `glorbo shell` Phase 3g — Tasks view +
  Phase 3 complete.** Shipped post-v0.14.0 (autonomous L4).
  Kanban-style stacked-vertical layout: each lane
  (TODO / IN PROGRESS / REVIEW / DONE / OTHER) gets a
  `▾ <LANE> (<count>)` header followed by indented task
  rows `<task_id> — <title> [<assignee>]`. Cursor
  navigates the flat sequence; j/k crosses lane
  boundaries. `Tasks.Data.group_by_lane/1` mirrors the
  LV's `group_by_column/1` (REVIEW collects pending /
  pending-approval / approved / denied; OTHER is the
  unknown-status catch-all). AppRoot wires `C-c t` →
  tasks. **All seven D10 chord-target views now
  implemented — GEP-37 Phase 3 complete.** 28 new tests
  (12 Data + 16 view); 2509/2509 total. v1 surface as
  defined in the GEP is shippable as v0.15.0. Future
  phases revisit existing views for Repo-backed columns,
  slash-command composer, live-tail subscriptions, and
  channel switcher.
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
