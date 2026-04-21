# Changelog

All notable changes to Glorbo will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0 caveat: APIs, CLI flags, on-disk layout, and SQLite schema may
change between minor versions. Pin exact versions in downstream usage.

## [Unreleased]

### Changed — GEP-25 atomic `kind:` cut, writers (R26.2a)

Per GEP-25 D9 + the pre-1.0 "no kid gloves" rule, every file Glorbo
writes now carries a `kind: <name>/v1` discriminator in its frontmatter
(or top-level JSON/JSONL object). No soft-migration fallback — readers
that care about kind (router's memory-write path, task outbox route)
reject files without it.

Writers updated:

- Scaffolders: `glorbo new {company,project,agent,skill}` emit the
  correct `kind:` line before anything else; templates that back agent
  scaffolds (HEARTBEAT.md, SOUL.md default bodies) include `kind:` too.
- `Glorbo.Init.ExampleCompany` — `glorbo init` acme seed now stamps
  `kind:` on company.md / AGENT.md / HEARTBEAT.md / general channel.
- `Glorbo.Company.AuditLog` — every JSONL line carries
  `"kind": "audit-event/v1"` as its first key.
- `Glorbo.Inbox.Archive` — `_inbox_archive.json` is now an object
  `{ "kind": "inbox-archive/v1", "keys": [...], "updated_at": "..." }`
  instead of a bare array.
- `Glorbo.Approvals.Gate` — awaiting-approval sentinel gains
  `kind: sentinel-approval/v1`.
- `Glorbo.Agent.LoopDetector` — stuck sentinel now uses the canonical
  `kind: sentinel-stuck/v1` (was `kind: loop_detected`).
- `Glorbo.Company.TaskScheduler` — scheduled inbox messages get
  `kind: inbox-message/v1`.
- `Glorbo.Company.Router` — memory-index upserts emit a kind-bearing
  frontmatter block; memory writes now REJECT incoming files missing
  `kind: agent-memory/v1`; outbox-filed tasks now REJECT files missing
  `kind: task/v1`.
- `Glorbo.BrainDump` — first write of the day wraps the section in a
  `kind: braindump/v1` frontmatter; brain-dump → task conversion
  stamps `kind: task/v1`.
- `Glorbo.EmergencyStop` — company stop sentinel carries
  `kind: emergency-stop/v1`.
- `Glorbo.TaskDefinition.write_frontmatter/2` — the editor-allowlist
  rewriter now preserves the file's original `kind:` line (or falls
  back to `task/v1`) instead of dropping it.
- `Glorbo.Chat.Rotation` — archive segments include
  `kind: channel-log/v1` + `archive_of:` / `rotated_from:`.
- `GlorboWeb.ChannelLive` / `PageController` — new channel creation +
  director/agent DM channels stamp `kind: channel-log/v1`.
- `GlorboWeb.CompanyLive` — company editor rebuilds frontmatter with
  `kind` + `slug` at the top.
- `GlorboWeb.KanbanLive` — task creation injects `kind: task/v1`;
  assignment inbox notify now uses canonical
  `kind: inbox-message/v1`.
- `GlorboWeb.ProjectLive` — bootstrap `project.md` seed now
  contains `kind: project/v1` + slug.

Router parser enforcement (load-bearing per D9):

- `task/v1` required on outbox-filed task.md — missing kind rejects
  the route + audits.
- `agent-memory/v1` required on memory-outbox file — missing kind
  rejects the write + audits `memory.rejected`.

Fixtures + tests: 6 router-test fixtures and 4 stuck-sentinel tests
updated to the new `kind:` shape; full suite green (1394 tests,
0 failures, 1 skipped). R26.2b (templates + per-kind golden fixtures
+ parser enforcement beyond router) follows.

### Added — GEP-25 formatter + `glorbo fmt` (R33)

- **`Glorbo.FileSpec.Formatter`** — canonical-form rewriter for
  Glorbo-owned markdown files. Reorders YAML frontmatter keys
  per each spec's `canonical_key_order/0`, normalises `---`
  fences, ensures trailing newline, preserves body byte-for-byte.
  Unknown frontmatter keys land alphabetically after the known
  block. JSON/JSONL files skipped; unknown paths skipped.
  Idempotence is load-bearing — `format(format(x)) == format(x)`
  asserted by fixture round-trip.
- **`glorbo fmt [PATH] [--check|--write]`** — default `--check`
  reports drift and exits 1 if any file would change; `--write`
  applies via atomic tmp+rename (same pattern as
  FrontmatterWriter / Router / Memory.Writer). No other cleanup
  on disk — `.tmp.*` files never leak.
- `Glorbo.FileSpec.Formatter` is the file-rewriter; the R27 CLI
  findings formatter was renamed to
  `Glorbo.FileSpec.FindingsFormatter` to avoid ambiguity.

14 formatter unit tests + 2 CLI smoke tests. 1394/1394 green.

### Added — R30.2: dispatch fallback + Doctor OS split

- **`Glorbo.Sandbox.Unsandboxed.start/2`** — sibling runner to
  `Glorbo.Sandbox.Bwrap.start/2` that skips every isolation flag
  and invokes the CLI directly via the same sh-wrapper + prompt-
  tempfile pattern. Tees stdout into `agents/<slug>/stdout.log`
  so the dashboard still sees output.
- **`Agent.Dispatch.default_run_fun/4`** now probes
  `Glorbo.Sandbox.Bwrap.availability/0` per invocation. On
  `{:error, :unavailable}` (macOS, bwrap-less Linux hosts) it
  emits `agent.sandbox_unavailable` audit ONCE per company per
  BEAM boot and runs via `Unsandboxed.start/2`.
- **`Glorbo.Doctor.run_checks/1` OS-aware reclassification.**
  On darwin, the four Linux-only probes (`linux_kernel`,
  `uidmap`, `bwrap`, `user_namespaces`) return synthetic
  `pass: true` with severity `:info` and detail
  "skipped on <os> (linux-only prerequisite; agent runtime runs
  unsandboxed here)". Check-list length stays 10 so existing
  tests don't churn; exit code math unaffected since `:info`
  entries aren't blockers.

macOS binaries now start + run `glorbo doctor` honestly + dispatch
agents without raising. Directors see exactly one
`agent.sandbox_unavailable` row per company boot making the
degraded-mode explicit.

### Added — R30.1: macOS build plumbing

- **Burrito targets gain `macos_x86_64` + `macos_arm64`** in
  `mix.exs`. `mix release` on macOS runners emits the darwin
  binaries the release workflow packages.
- **CI workflow adds a parallel `build-macos` matrix job** running
  on `macos-13` (Intel) and `macos-latest` (Apple Silicon).
  Compiles, builds the Burrito release, runs the smoke suite
  (`glorbo doctor --json` version check, help exit code, unknown-
  verb exit 1), and uploads the binary as an artifact alongside
  the Linux builds. `release` job now also signs and publishes
  the two darwin binaries + their `.sig` cosign bundles.
- **`Glorbo.Sandbox.Bwrap.availability/0`** returns
  `{:error, :unavailable}` on hosts without bwrap instead of
  raising. Callers that want to degrade gracefully (macOS) use
  this probe; callers that require sandboxing (Linux) keep
  calling `default_binary/0` which still raises on absence.
- **Homebrew formula generator** now expects 4 release assets
  (both linux + both darwin) and renders an `on_macos do` block
  alongside `on_linux do`. `depends_on "bubblewrap"` scoped to
  `on_linux do`; caveats explain macOS runs unsandboxed.

The Elixir runtime fallback (dispatch honours the availability
probe + emits a one-time `agent.sandbox_unavailable` warning
audit) and Doctor OS reclassification are R30.2. Until those
land, a macOS binary starts and `glorbo doctor` runs, but agent
dispatches will raise on bwrap absence.

### Added — Homebrew tap (R29)

- **`brew install foobarto/tap/glorbo` works end-to-end (#300).**
  The tap repo at <https://github.com/foobarto/homebrew-tap> now
  ships `Formula/glorbo.rb` pinning v0.0.4 Linux x86_64 + aarch64
  binaries + SHA256s. `depends_on :linux` guards macOS for now;
  `depends_on "bubblewrap"` wires the kernel-sandbox prerequisite.
  `brew audit --new` clean; `brew test` runs `glorbo doctor --json`.
- **`mix glorbo.release_formula [--tap-path PATH] [--write]`** —
  new Mix task that regenerates the tap formula from the current
  `mix.exs` version by fetching `SHA256SUMS` from the corresponding
  GitHub release and rendering the formula template. Run after
  each `gh release create`. Prints to stdout by default; pass
  `--write` to overwrite `<tap>/Formula/glorbo.rb` in place.

### Changed — GEP-25 TaskMd widen + skill/v1 (R28)

- **TaskMd regex widened (#299).** UAT ran the R27 validator
  against a real workspace and found that descriptive-slug tasks
  (`cut-release.md`, `drop-s3.md`) were reported as `unknown_file`
  — TaskMd's regex required the GEP-13 canonical
  `<project>-NN.md` form, but `Glorbo.TaskDefinition.parse_file`
  accepts any `*.md` under `projects/<p>/tasks/`. Spec now
  matches reality; a new info-level finding
  `:non_canonical_task_filename` surfaces non-canonical names
  without blocking CI.
- **`skill/v1` FileSpec module added.** Covers
  `priv/templates/skills/*.md` (builtin) and
  `~/.glorbo/skills/*.md` (user override); registry grows to
  16 kinds.

### Added — GEP-25 validator + `glorbo validate` (R27)

- **`Glorbo.FileSpec.Validator` + `glorbo validate` CLI (#298).**
  Read-only workspace health check driven by the R26.1 FileSpec
  registry. Walks a path, classifies every file, parses frontmatter
  (via `Glorbo.Filesystem.Frontmatter` for markdown, `Jason` for
  JSON/JSONL), and emits structured findings against each spec's
  declared schema. Ten check codes covering missing `kind:`,
  kind/path mismatch, YAML parse errors, missing-required-key,
  enum-out-of-range, pattern-mismatch, cap-exceeded, unknown-key,
  unknown-file, IO errors.

  Output modes: `:human` (one line per finding), `:json` (NDJSON
  per GEP-25 D6 — one finding per line + trailing `type:summary`),
  `:summary` (count-line only). Flags: `--json`, `--summary`,
  `--severity lvl`, `--kind kind`. Exit code 1 on any error-level
  finding, else 0.

  Verified end-to-end against a pre-cut workspace — reports 27
  `missing_kind` errors on the R22 UAT tree, exactly the diagnostic
  the atomic cut needs.

  Tests: 14 validator unit cases covering every check code + 2
  CLI smoke tests + a help-text regression.

### Added — GEP-25 scaffolding (R26.1)

- **`Glorbo.FileSpec` registry + 15 per-kind spec modules.** Pure
  catalogue of every markdown-with-frontmatter or JSONL/JSON file
  Glorbo reads or writes (`company/v1`, `agent/v1`, `project/v1`,
  `task/v1`, `agent-heartbeat/v1`, `agent-soul/v1`,
  `agent-memory-index/v1`, `agent-memory/v1`,
  `sentinel-approval/v1`, `sentinel-stuck/v1`,
  `sentinel-resolution/v1`, `braindump/v1`, `channel-log/v1`,
  `audit-event/v1`, `inbox-archive/v1`). Each module declares
  its `kind:` discriminator, frontmatter schema
  (required/optional/enums/patterns/caps), canonical key order,
  and docs. `classify_by_path/1` + `classify_by_kind/1` for
  lookup. No writer/CLI changes yet — the atomic `kind:` sweep
  across every writer + fixture + the validator/formatter land
  as R26.2.

### Fixed — post-release polish (R25, browser UAT)

- **Goal `name:` accepted as title fallback (#294).** GoalsLive
  and CompanyLive's goals panel expected `title:` on every goal
  entry under `goals:`. Directors reaching for the convention used
  on every other `company.md` field (`name:` on company, agent,
  project) got back `slug · slug` rendered with a muted separator
  — the same slug twice. Now both keys work; `title:` still
  preferred, `name:` falls back. Two new test cases cover the
  fallback on both views.

## [0.0.4] — 2026-04-21

Large release spanning browser-UAT rounds R14–R24 plus the GEP-20
director-dashboard UX sweep. Headline additions: file-based agent
memory (GEP-21) end-to-end, natural-language scheduler parser, per-
agent proxy allowlist extensions (GEP-23), loop-detector sentinel
resolution contract unification, and the unified Inbox.

### Added — director dashboard UX sweep (rounds 2+3, GEP-20)

- **Unified director inbox (`/companies/<co>/inbox`)** with Mine /
  Recent / All / Archive tabs. Aggregates pending approvals + the
  recent audit stream; inline approve / deny / archive actions on
  each row. Archive state persists at
  `audit/_inbox_archive.json` and survives reloads; Archive tab
  lists handled rows with an Unarchive escape hatch.
- **Dedicated goals view (`/companies/<co>/goals`)**. Reads
  `company.md` frontmatter `goals:` list, buckets every task by
  `goal:` reference, shows per-goal totals + status breakdown bar
  + deep link into a Kanban filtered by goal slug. Unassigned
  tasks roll up under a `(no goal)` card.
- **Skills marketplace (`/companies/<co>/skills`)**. Enumerates
  builtin skills under `priv/templates/skills/` alongside user
  overrides; classifies each as `builtin | custom | shadowed`;
  used-by counts per agent.
- **Per-goal Kanban filter** (`?goal=<slug>`) from GoalsLive,
  CompanyLive goals panel, or URL.
- **Agent config edit form.** AgentLive's right-column `config`
  panel gains an `edit` button that flips to a structured form
  for provider / model / reports_to / heartbeat / network. Writes
  allow-listed AGENT.md frontmatter keys via the new
  `Glorbo.Filesystem.FrontmatterWriter.update_keys/3` (preserves
  order, comments, indentation; atomic `.tmp` + rename).
- **14-day rollup strip on CompanyLive** — runs per day, success
  rate, tasks by status, tasks by priority. Data from
  `Glorbo.Activity.Rollup` (scans current + previous monthly
  audit JSONL; reads task frontmatter for status/priority
  buckets). Reuses `Components.Spark` + new
  `Components.StatBreakdown` (stacked segments + colour-coded
  legend with curated palette for known statuses).
- **Create-company wizard** chains the three existing modals
  (new-company → new-agent → new-project) via URL params
  (`?wizard=new_agent` → `?wizard=new_project`). 3-step
  breadcrumb renders inside each modal while a chain is active.
- **Two-letter actor avatars** on audit rows, channel messages,
  and inbox activity feed. `AuditEntry.actor_initials/1` +
  `actor_kind/1` public helpers; colour by kind (system /
  director / agent).
- **Inline slug-availability probe** on the new-company modal.
  150 ms debounced `phx-change` checks `File.dir?`; inline hint
  + green/red border + disabled submit when taken.
- **Command palette additions.** `⌘K / Ctrl-K` overlay now
  surfaces Inbox, Skills, projects from the sidebar, and
  `+ new agent` / `+ new project` action shortcuts.
- **Tool-call counts on agent.complete audit entries** (§2).
  `ClaudeJsonl` parser counts `tool_use` blocks per assistant
  message; Dispatch forwards `%{"Bash" => 1, "Read" => 2}` onto
  the complete-audit detail; AgentLive Runs tab shows `N tools`
  (collapsed) and `Bash×1, Read×2` (expanded). Opencode + Codex
  + Gemini parsers keep `tool_calls: nil` for now.
- **Activity sentences on audit rows** — `<actor> <verb> <object>`
  framing with delta rendering for status changes.
- **GEP-20** — Informational GEP retrofitting the scope, design,
  and decision log for this sweep. See `docs/geps/0020-round-2-
  3-ux-sweep.md`.

### Added — loop-session ship list (#230, #232 – #242, T1-E / T1-F / T2-B / T2-C / T2-D / T3-A)

- **Brain dump (`/companies/<co>/braindump`, `g b`)** — daily
  append-only capture log at `companies/<co>/braindump/YYYY-MM-DD.md`.
  Topbar "+ dump" button, convert-to-task action scaffolds into
  `projects/inbox/tasks/` with `source: braindump` frontmatter.
- **Per-task `model:` / `provider:` override (#235)** — task
  frontmatter pins a specific LLM for that dispatch; blank / nil
  falls back to the agent spec.
- **Agent model aliases (#236)** — optional `models:` map in
  AGENT.md (alias → concrete); tasks select by alias.
- **Natural-language heartbeat (#233)** — `heartbeat: "every
  morning at 9am"` compiles to cron at parse time. Literal cron
  passes through.
- **Ctrl+K content search (#232)** — `/api/search?co=&q=` JSON
  endpoint backing the command palette with task-title matches;
  ETS mtime cache skips re-parse on hot path.
- **Recurring tasks (#237)** — task frontmatter `schedule:` + auto-
  reset to `todo` when written `done`. Kanban card renders a `↻`
  pill with the schedule string.
- **Rolling-log rotation for channels (#238)** — oversized
  channel files (512 KB / 1500 lines default) rotate into
  `channels/archive/<channel>/<ts>.md` atomically.
- **Archive browser in ChannelLive (#239)** — collapsible list of
  rotated segments with inline viewer.
- **Named autonomy tiers (#231)** — `autonomy: manual | supervised
  | auto` on AGENT.md; metadata-only for now, runtime gate wiring
  is a follow-up.
- **Emergency stop (#241, T2-C)** — director-visible kill switch.
  Writes `companies/<co>/state/emergency-stop.md`, stops every
  running dispatch, refuses new ones until cleared. Pulsing red
  topbar chip when engaged.
- **Cost ledger page (`/costs`, #242, T2-D)** — per-agent monthly
  spend matrix for the last 12 months, top-spender card, drill-in
  link to AgentLive.
- **Per-company budget cap (#245)** — `company.md` frontmatter
  `budget_usd_cents_month:`. Dispatch refuses new work when the
  sum of every agent's month-to-date spend reaches the cap; an
  alert state fires between 80% and 100%. Complements the
  existing per-agent `budget_usd_cents_month:` on AGENT.md; both
  caps are independent — whichever hits first stops dispatch.
- **Per-task budget cap (#243)** — task frontmatter
  `budget_usd_cents:` caps what a single dispatch may cost.
  Post-dispatch check emits a `task.budget_exceeded` audit event
  when usage exceeded the cap; hard-stop enforcement
  (refuse the next re-dispatch if the prior one crossed the cap)
  is a follow-up.
- **Tokens + cost on Runs tab (#246)** — `agent.complete` audit
  events now carry `prompt_tokens`, `completion_tokens`, and
  (when pricing is known) `cost_usd_cents`. AgentLive Runs tab
  always shows `N in / M out` tokens; cost shows `$X.YY` when
  pricing for the provider/model is available, `—` when not.
- **Session resilience (#248, T1-A)** — dispatch now auto-retries
  on `:timeout` and `:reply_file_missing` with the prior attempt's
  summary appended to the prompt. Retry count caps at
  `AGENT.md` `max_retries:` (default 2, max 5). Non-recoverable
  errors (prompt size, unknown provider, budget stop, emergency
  stop) never retry — config problems don't self-resolve.
  Emits `agent.retry` audit per attempt for the history tab.
- **Ctrl+K finds audit rows (#249)** — palette search now
  matches on actor / action / target across the current month's
  audit JSONL, capped at the most recent 500 entries. Audit
  results carry `kind: audit` and navigate to the company's
  audit page; task-title and audit-row hits rank together so
  the single best match wins the top slot.
- **TaskLive usage strip (#252)** — dedicated task pages now
  show aggregated tokens + cost + dispatch count across all
  this task's `agent.complete` audits for the current month.
  Follows the #246 rule: tokens always, cost `—` when zero.
- **Goal progress bar (#253)** — `/companies/<co>/goals` each
  goal card now renders a coloured progress bar showing
  `done / total tasks · N%`. Colour state: muted (<50%),
  amber (50-99%), green (100%).
- **Audit → task conversion (#254)** — one-click "convert to
  task" on expanded audit rows. Scaffolds
  `projects/inbox/tasks/t-audit-<date>-<slug>.md` with a
  ```Context``` block containing the audit actor / action /
  target + the raw JSON payload for reference.
- **Audit CSV export (#259)** — `/companies/<co>/audit.csv`
  downloads the current month's audit log as CSV with columns
  `ts, actor, action, target, detail`. RFC 4180-compliant
  quoting. "⇩ export CSV" button on AuditLive header.
- **Audit date-range filter (#263)** — `since` and `until` date
  inputs on the filter bar narrow the visible rows by timestamp.
  Both bounds inclusive (00:00:00Z → 23:59:59Z). Composes with
  the actor / action / free-text filters.
- **Task history panel (#264)** — TaskLive renders a
  task-scoped slice of the audit log under the Sugar grid:
  every `agent.dispatch` / `agent.complete` / `agent.retry` /
  `task.update` row that targets this task. Expandable via
  the shared `AuditEntry` component, live-refreshing via the
  `company:<co>:audit` PubSub topic, capped at 25 entries.
  Deep-link "view full audit →" navigates to AuditLive with
  the task id pre-filled (`?q=<task-id>`). AuditLive now
  honours `?q=&actor=&action=&since=&until=` URL params so
  deep-links survive copy-paste.
- **`Glorbo.Audit.Query.for_task/4`** — tiny pure reader over
  the current-month JSONL; matches `target == task_path`,
  bare `task_id`, `detail.task_path`, or `detail.target`
  containing the id. Graceful on missing file / malformed
  JSON.
- **Scheduled-task "next fire" indicator (GEP-24).** TaskLive's
  usage strip now renders a `schedule · ↻ <cron> · next fire in
  2h 15m` row for tasks with a `schedule:`. New
  `Glorbo.Company.TaskScheduler.next_fire_at/2` soft API returns
  the armed `DateTime` or `nil` (tolerates a stopped scheduler
  via `catch :exit`). Relative formatter falls back to ISO
  timestamp for fires more than 7 days out so monthly crons
  don't render "in 720h". Docs retrofit in `GEP-0024`.
- **Task scheduler (#268)** — `Glorbo.Company.TaskScheduler`
  now actually fires dispatches from `schedule:` cron fields.
  On boot + on each `projects/**/*.md` write event the
  scheduler scans `projects/*/tasks/*.md`, parses each
  task's schedule (5-field cron or keyword alias —
  `hourly`/`daily`/`weekly`/`monthly` plus `@hourly` etc.),
  and arms a one-shot `Process.send_after/3` timer. Firing
  writes a synthetic `sched-<ts>-<task_id>.md` into the
  assignee's inbox with the task body as the prompt;
  Agent.Server's inotify watcher picks it up as a regular
  `:inbox` wake. Every fire emits
  `task.scheduled_dispatch` (appears in TaskLive history
  panel #264). Malformed schedules log
  `scheduler.invalid_task_cron` and are skipped — the
  scheduler never crashes on a bad cron. Zero state file;
  filesystem-is-truth invariant preserved. Until this
  landed the `schedule:` frontmatter field was rendered
  but never actually fired anything.

### Fixed — round 24 (browser UAT polish)

- **Truthful Inbox header (#292).** `/companies/<co>/inbox` used
  to say `Inbox (0 pending)` while a non-empty "Stuck agents"
  list rendered below — the count referenced only approval
  sentinels. Header now composes both counts:
  `(N approval[s] · M stuck)` when both present, `(N approvals)`
  or `(M stuck)` when only one, `(empty)` when neither. +1 test
  case asserting the header text for a seed with 1 approval + 1
  stuck.
- **Relative last-failure timestamp on stuck rows (#292).**
  Stuck-agent rows in InboxLive rendered raw ISO timestamps for
  `last_failure_ts`. Switched to `GlorboWeb.TimeFormat.relative/1`
  (same formatter audit rows use) so the row reads "3 min ago"
  / "2 hr ago" at a glance; ISO string kept in the title tooltip
  for precise auditing. Matches the TaskLive stuck-banner
  treatment.
- **UAT.md additions.** G6 (truthful inbox header), G7 (relative
  stuck timestamp), G8 (file-drop resolution path — R23
  regression) added under section G.

### Fixed — round 23 (browser UAT regression)

- **`agent.loop_resolved` audit row was missing in production
  (#291).** Browser UAT of the R21 file-drop resolution flow
  found that resolution files were being cleaned up, but no
  `agent.loop_resolved` audit row ever landed on disk. Three
  bugs compounded:

  1. `apply_one_resolution` always forwards
     `audit_fun: Keyword.get(opts, :audit_fun)` — nil when the
     caller (InboxLive/TaskLive load_stuck) didn't pass one.
     `resolve/5` used `Keyword.get_lazy`, which only fires when
     the key is *absent*, not when the value is nil — so
     `audit_fun` was `nil` and `nil.(company, entry)` raised.
  2. `emit_resolved_audit`'s rescue clause caught exceptions but
     not `:exit` signals; the compounding `GenServer.call` to a
     non-registered process raised exit, not a rescuable error.
  3. The default audit_fun called `AuditLog.append/1` (singleton),
     but AuditLog is started *per-company* under
     `Glorbo.Agent.Registry` — there is no singleton. The audit
     sink was therefore pointed at a non-existent process.

  Fixes: (a) coerce nil → default in `resolve/5`, (b) add
  `catch :exit, _ -> :ok` to `emit_resolved_audit`, (c) rewrite
  `default_audit_fun` to resolve the per-company audit server
  via Registry (same pattern as
  `Glorbo.Agent.Dispatch.default_audit_fun/2`). R23 verified
  end-to-end: file-drop → resolve → audit row written to
  `companies/acme/audit/2026-04.jsonl` with actor
  `agent:engineer` + decision `retry`.

  Test: +1 regression case asserting `resolve/5` with
  `audit_fun: nil` returns `:ok` and removes the sentinel,
  without propagating a crash.

### Fixed — round 22 (browser UAT)

- **Sidebar memory badge glyph (#290).** R20 used `✎` (U+270E) as
  the memory-count icon; it didn't render in the sidebar's
  monospace font (JetBrains Mono / Fira Code don't carry that
  codepoint) and fell back to a tofu box. Swapped to
  `<i class="fa-solid fa-brain">` — FontAwesome 6.5.2 is already
  loaded in the root layout, renders crisply, and is semantically
  closer to "memory" than the pen glyph. Badge layout switched to
  `inline-flex` + 3px gap so the icon and count sit cleanly
  together.
- **Sidebar memory badge aria-label plural fix.** Badge title +
  aria-label both said "memory files" regardless of count;
  singular-count rows now read "1 memory file". Extracted
  `pluralise_files/1` helper. +3 test cases on
  `GlorboWeb.Components.SidebarTest` cover the filename filter
  (valid types, wrong case, wrong extension, `MEMORY.md` index
  excluded) via a new `count_memory_files_for_test/2` helper.

### Added / Changed — round 21

- **Unified loop-detector resolution contract (#289).** The
  stuck-on sentinel body documented three resolution paths via
  `resolved-<decision>-<task-id>.md` file drops, but
  InboxLive/TaskLive buttons bypassed that contract entirely —
  they mutated the task frontmatter in-process and deleted the
  sentinel directly, so agents who followed the documented
  protocol were ignored.

  Both views now call a single `Glorbo.Agent.LoopDetector.resolve/5`
  entry point. The module also exposes `apply_resolution_files/3`,
  which scans `agents/*/state/resolved-{retry,skip,stop}-<task>.md`
  on every InboxLive/TaskLive render, applies any matching
  resolution, and deletes both the resolution file and the
  sentinel. Orphan resolution files (no matching sentinel) are
  cleaned up silently.

  Consequences:
  - **One code path**, not two. Retry/skip/stop semantics match
    whether the decision came from the UI button or a CLI agent
    dropping a file.
  - **Truthful sentinel body.** The documented file-drop protocol
    now actually works end-to-end.
  - **Single audit row per resolution** (`agent.loop_resolved`)
    with `actor` set to `"director"` (button) or `"agent:<slug>"`
    (file-drop). Replaces the previous implicit behaviour where
    only task mutations + sentinel deletion were recorded.
  - Director and agent can no longer race: each resolution file
    is keyed by `task_id`, and InboxLive applies them on render.

  Tests: 8 new cases on `Glorbo.Agent.LoopDetectorTest` cover
  retry/skip/stop mutation + sentinel cleanup + audit emission +
  custom actor propagation + file-drop application + orphan
  cleanup + malformed-filename tolerance + multi-agent batching.

### Added — round 20

- **Memory count badge on sidebar agent rows (GEP-21, #288).** Each
  agent row in the company sidebar now shows a subtle `✎ N` badge
  next to the slug when the agent has one or more memory files on
  disk. Directors can scan memory activity across the whole roster
  without clicking into each AgentLive Memory tab. Badge is hidden
  for agents with no memory directory or zero matching files; count
  uses the same filename regex as `Glorbo.Agent.Memory`
  (`^(user|feedback|project|reference)_...\.md$`) so invalid files
  never inflate the count. `File.ls` errors rescue to 0 — a
  permission glitch on one agent's dir never blanks the sidebar.

### Added — round 19a

- **Per-agent `network_allow:` proxy extensions (GEP-23, #283).**
  Agents whose AGENT.md carries `network: api-only` can now
  declare additional hosts in a `network_allow:` frontmatter
  list. Company.Supervisor unions those into the proxy's
  allowlist at boot, so directors can grant access to an
  internal dashboard or vendor API without touching the
  global `config :glorbo, :network_policy` base.

  ```yaml
  # agents/scout/AGENT.md
  ---
  slug: scout
  provider: claude-code
  network: api-only
  network_allow:
    - grafana.internal
    - ops.example.com
  ---
  ```

  Validation: hostnames must match `[a-z0-9]([a-z0-9-]*[a-z0-9])
  ?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+` — no schemes, no
  wildcards, no whitespace, no empty strings. Invalid entries
  are silently filtered so one typo doesn't poison the
  allowlist. Failures in `File.read` / `Frontmatter.parse`
  fall through to the base allowlist.

  Scope: coarse-grained per-company. Any api-only agent in the
  company can reach any host any sibling declared. Per-
  requester gating (distinct allowlists per agent identity)
  is tracked as R19b along with smart-mode LLM filtering.

  Tests: 4 new cases on `Glorbo.Company.SupervisorTest` cover
  frontmatter unions into proxy state; invalid hosts filtered;
  no-frontmatter agent inherits base only; multiple agents
  union. `Glorbo.Network.Proxy.default_allowlist/0` is now
  public so callers can compose the base.

### Added — round 18a (E2E backfill)

Per new feedback rule "ship E2E tests alongside features" — back-
filling integration coverage for recently shipped features that had
unit tests only.

- **NL schedule E2E (#286).** Two new cases in
  `test/integration/scheduled_task_e2e_test.exs` verify NL phrases
  (`every minute`, `every morning at 9am`) actually fire scheduled
  dispatches end-to-end — scheduler parses → arms timer →
  `send({:fire, task_id})` → inbox file on disk + audit. Unit
  tests on `Glorbo.ScheduleNL` proved the parse; these prove
  the fire path doesn't silently swallow the parsed cron.

- **Kanban filter chip E2E (#275 extension).** Two new cases
  exercise the full `navigate → mount → handle_params` pipeline
  after a chip click: dropping the assignee chip keeps the
  project filter applied, clear-all removes the entire chip bar.
  Unit tests checked chip rendering; these check the re-mount
  behaviour callers rely on.

- **Task-ID autolink E2E (#276 extension).** Two new cases mount
  TaskLive with a comment referencing `foo-2`, verify the rendered
  anchor URL is correct, and then mount kanban at that deep-link
  URL and confirm the referenced task's overlay renders. Unit
  tests checked the HTML anchor; these check the anchor actually
  navigates to something useful.

### Added — round 17b/17c

- **Agent memory writing — outbox → Router → disk (GEP-21, #284).**
  `Glorbo.Company.Router` now classifies two new outbox paths:
  - `agents/<slug>/outbox/memory/<type>_<topic>.md` → atomic
    write to `memory/<type>_<topic>.md` + upsert MEMORY.md index
    line + `memory.write` audit.
  - `agents/<slug>/outbox/memory/delete/<type>_<topic>.md` →
    delete the memory file + remove index line +
    `memory.delete` audit.

  Validation: filename matches `<type>_<topic>.md` (type ∈
  user|feedback|project|reference); body ≤ 8 KB; frontmatter
  `type:` matches filename prefix. On any failure, a
  `memory.rejected` audit lands and the outbox file is dropped
  so the agent doesn't retry forever on bad input.

  Atomic: tmp+rename on each write. Index uses match-by-
  filename dedup so repeat writes to the same memory replace
  a single line, not append duplicates. When the last memory
  goes, MEMORY.md is removed entirely.

  6 new unit tests on Router (write, replace, type-mismatch,
  oversize, invalid-filename fall-through, delete). Full suite
  1309/1309 green.

- **Memory tab on AgentLive (#284 UI).** New tab next to
  `history` surfaces MEMORY.md + each memory file's frontmatter
  name/description + body, sorted newest-first with relative
  mtime (`3 h ago`, `yesterday`). Type pill colours the row.
  Directors read agent memory without shell access. 3 new unit
  tests cover empty state, populated list, filename filter.

- **E2E memory with real CLI agent (#285).** Two new
  `:live_model` tests in `test/integration/opencode_lmstudio_
  live_test.exs` — skipped when LM Studio isn't serving qwen.
  (1) Seeds a unique token in memory, asks the model to
  recall, asserts the reply contains it (memory read path
  proven end-to-end with a real model). (2) Asks the model to
  write a memory via the outbox routing contract, pokes the
  Router with a simulated inotify event, asserts the file
  landed in `memory/` with correct content + index upserted +
  `memory.write` audit emitted. Both pass against live qwen
  3.6-35b on LM Studio.

### Added — round 17

- **Agent memory reading (GEP-21 / #281 MVP).** New
  `Glorbo.Agent.Memory.compose/3` reads `agents/<slug>/memory/` —
  `MEMORY.md` index + `<type>_<topic>.md` body files with
  `type` ∈ `user|feedback|project|reference` — and returns a
  single string capped at 20 KB suitable for prompt
  composition. `Agent.Server.compose_prompt/4` splices the
  result into the system prompt as a `## Memory` section
  between the permission-mount summary and the reply-hint.
  Bodies are sorted newest-first by mtime; overflow appends a
  `[N older memories not shown]` notice.

  This is the **reading half** of GEP-21. The writing path
  (agent outbox → Router classify → atomic write → MEMORY.md
  upsert + `memory.write` audit) ships next iteration as #17b.
  Validates the prompt-composition contract in production
  before the write contract is sealed — partials-first
  discipline per memory feedback.

  9 unit tests on the Memory module cover: missing dir → empty,
  empty dir → empty, index verbatim, newest-first ordering,
  filename filter (invalid types + slugs rejected), all 4
  valid type prefixes, 20 KB cap with truncation notice,
  malformed binary index graceful handling, empty index
  skipped.

### Added — round 16

- **NL schedule parser (#280).** Tasks can now use English
  phrases like `every morning at 9am` / `every weekday` /
  `every 5 minutes` / `every Monday at 6pm` in their `schedule:`
  frontmatter and the scheduler will actually fire them. The
  display layer has shown these since v0.0.3 but they used to
  fall through the 5-field cron parser into
  `scheduler.invalid_task_cron` oblivion. New
  `Glorbo.ScheduleNL.parse/1` converts NL → cron; TaskScheduler
  calls it before the Crontab.Parser fallback so 5-field crons
  still work unchanged. Grammar covers time-of-day
  (morning/evening/night/noon/midnight with default hours +
  optional `at <time>`), weekdays (Monday-Sunday + weekday /
  weekend buckets), and intervals (every minute / N minutes /
  N hours / hour / day / week). Closes the gap between #237
  display and #268 firing. 30 unit tests on the parser + 2
  scheduler-integration tests.

### Added — round 15

- **E2E LoopDetector sentinel emission test (#279).**
  `LoopDetectorTest` covered the pure detection logic +
  filesystem writes via stubbed fs_fun; this new integration
  test closes the loop by exercising `LoopDetector.check/3`
  against real disk I/O, seeding 3 prior failure audit rows
  and asserting the sentinel file lands at
  `agents/<slug>/state/stuck-on-<task>.md` with correct
  frontmatter + director-resolution instructions. Idempotency
  case confirms a second check doesn't overwrite. Second test
  case proves a clean audit leaves no sentinel. Was partial —
  unit tests mocked the fs, so nobody had confirmed production
  wiring writes a real file. Now proven.

### Added — round 14

- **E2E scheduled-task dispatch test (#278).** New integration
  test at `test/integration/scheduled_task_e2e_test.exs`
  exercises the TaskScheduler fire path against the real
  `default_write_inbox` (no test stub for the write): drives
  `:fire` directly so it's fast, but verifies inbox file lands
  on disk + audit event emitted. Second case confirms the
  fire-time re-read works — arming with body A then rewriting
  the task to body B before firing produces inbox body B. The
  `inotify → Agent.Server wake` half of the chain is already
  covered by `AgentWakeInboxTest`; between the two, scheduled
  dispatch is end-to-end proven.

### Added — round 13

- **Heartbeat cron validation on AgentLive config save (#277).**
  The AGENT.md edit form used to accept any string for the
  `heartbeat:` field — malformed crons saved silently and the
  scheduler would log `scheduler.invalid_cron` and skip forever,
  leaving directors puzzled about why the agent never woke.
  Save now validates via the same Crontab parser the scheduler
  uses, failing inline with a concrete error (`"Invalid
  heartbeat cron: <reason>. Expected a 5-field cron (e.g. \"0
  * * * *\") or blank for no heartbeat."`). Blank = no-heartbeat
  agent, still valid. Form stays in edit mode on failure so the
  fix doesn't lose the director's typed state. 2 new regression
  tests cover the invalid and blank paths.

### Added — round 12

- **Task-ID autolinking in comments (#276).** Task-ID tokens
  like `abc-02` / `glorbo-7` in TaskLive / Kanban-shelf comment
  bodies now render as clickable anchors to the kanban
  deep-link (`?task=projects/<proj>/tasks/<id>.md`), consistent
  with how channel messages handle the same tokens via
  `GlorboWeb.Markdown.Linkify`. XSS-safe: comment body is
  HTML-escaped before the linkifier runs. Directors cross-
  referencing tasks in review comments get one-click
  navigation instead of having to type the URL. 4 new unit
  tests on the shared TaskDetailForm component cover plain
  text, single / multiple task-IDs, and HTML-escape behaviour.

### Added — round 11

- **Kanban filter chip bar (#275).** When any of the kanban
  filters (`?project=` / `?goal=` / `?who=`) is active, a row of
  pill-shaped chips now renders below the page header listing
  the active filters with an `×` that drops just that filter
  while preserving the others. A "clear all" link on the right
  nukes every filter. Previously only `?project=` had any
  visible-clear affordance (the "× all projects" button); the
  goal and assignee filters were silently applied with no way
  to tell they were even on. Replaces that one button with a
  more discoverable, composable UI pattern. 3 new regression
  tests cover no-chips, single-chip, and multi-chip URL
  construction.

### Added — round 10

- **TaskLive stuck-on banner (#274).** When an agent gets
  flagged by the LoopDetector as stuck on a specific task, the
  sentinel now surfaces on the task page itself — not just in
  the inbox. Warning-tinted banner above the usage strip shows
  the stuck agent + detected-at timestamp + reason, with
  symmetric retry / skip (reassign to director) / stop (deny
  task) buttons. Clicking any action resolves immediately and
  refreshes the banner in place. The inbox still lists
  everything; this just puts the controls where the director
  is already looking. 4 new regression tests cover render +
  all three resolve paths.

### Fixed

- **Scheduler.invalid_task_cron audit flood (#273, UAT round 9).**
  A task with an unparseable `schedule:` field was re-emitting
  `scheduler.invalid_task_cron` on every 60-second rescan
  because the dedup logic looked up the previous value from
  `state.tasks[task_id]` — but the error branch was never
  writing back to state. Fix: threading the state through the
  error branch so a stub entry (`%{schedule: ..., invalid?:
  true}`) is stashed, making the next rescan's `prev[:schedule]
  == schedule` short-circuit work. `{:fire, task_id}` for
  stashed-invalid entries is guarded (should never arrive;
  defensive) so a scheduler bug can't dispatch an unparseable
  task. 2 new regression tests — repeated-scan no-flood and
  re-emit-on-change — cover the behaviour.
- **Close-button hover affordance (#273).** The `×` glyph on
  every modal looked like static text because it had no hover
  state. Added a subtle border + surface-raised background on
  `:hover`, plus a `:focus-visible` outline for keyboard
  navigation. No text-size change; the button reveals itself
  as interactive on hover.
- **Sidebar Approvals badge/list mismatch (#272, UAT round 8).**
  Previously the badge counted every `awaiting-approval-*.md`
  sentinel including orphans (matching task file absent), while
  ApprovalQueueLive and InboxLive filtered them out. Directors
  could see "1 pending" and click through to an empty list. Fix:
  the badge counter now validates each sentinel's `<task_id>`
  resolves to a real file under `projects/<proj>/tasks/<id>.md`,
  matching the view's filter. 6 new unit tests cover orphan /
  live / mixed / malformed-id cases.
- **Audit log ISO timestamps → relative `N min ago` (#272, UAT
  round 8).** The collapsed audit row rendered
  `2026-04-21 03:50:42.555059` which scans poorly in a
  fast-scrolling log. Now shows `"7 min ago"` / `"yesterday"` /
  etc. via the existing `GlorboWeb.TimeFormat.relative/1`
  helper; the absolute timestamp is preserved on hover (`title=`)
  and in the `datetime=` attribute for screen readers.
  Malformed timestamps fall back to the raw string — nothing
  crashes.
- **ESC key now closes the ApprovalQueueLive deny modal (#272).**
  Every other modal already wired `phx-window-keydown="<cancel>"
  phx-key="Escape"`; the approval-queue deny modal was the only
  holdout, so keyboard users had to click the `×` to dismiss.
  Now ESC universally closes modals.
- **`glorbo up` crash when EPMD not running (#271).** Cold-boot
  timing: `glorbo doctor` 145ms, `glorbo status` 141ms, warm
  `glorbo up → running` 417ms. Cold `glorbo up` on a host with
  no EPMD crashed immediately with `econnrefused` on port 4369
  (Burrito ships ERTS but not a running EPMD; `Node.start/2`
  with `:longnames` needs one). `Glorbo.CLI.Lifecycle.
  Distribution.start/0` now spawns `epmd -daemon` itself before
  the first `Node.start`. The call is idempotent (epmd refuses
  to double-bind). Prefer the `epmd` shipped with the current
  ERTS release (via `:code.root_dir/0`) over `$PATH` so the
  Burrito binary always gets a matching version.
- **Inbox deny modal styling (#269).** The deny-prompt modal in
  InboxLive used `gl-modal__body` + bare `gl-form__row` /
  `gl-form__label` classes that had no CSS backing — rendering the
  form unpadded and misaligned. Added generic rules for
  `.gl-modal__body`, `.gl-modal__body .gl-form__row`, and
  `.gl-modal__body .gl-form__label` matching the padding / grid
  pattern used by the `.gl-company-md-form` wrapper other modals
  share. Every modal with a form now renders consistently whether
  it uses the shared wrapper or the bare `__body` container.
- **Topbar shortcut strip overflow (#269).** The keyboard
  shortcut strip (`g o overview · g c chat · …`) wrapped onto two
  lines at ~1400 px wide and the second line overlapped the page
  title below. Added `white-space: nowrap` + `overflow: hidden` +
  `text-overflow: ellipsis` to the strip and `flex-wrap: nowrap`
  + `overflow: hidden` to the topbar — shortcuts truncate with
  `…` on narrow widths instead of reflowing into the content.
- **Modal close-button glyph (#269).** The `✕` (U+2715) character
  used on every modal close button rendered as a fallback boxed
  "X" because neither JetBrains Mono nor IBM Plex Mono ship the
  glyph. Replaced with `×` (U+00D7 multiplication sign) across
  every LV + the filetree delete / `org_state_glyph` / tool-count
  formatter — the multiplication sign is present in every mono
  font and visually identical when rendered correctly.

### Changed

- AgentLive Runs tab + CompanyLive roster now include tool-call
  indicators when available; collapse gracefully when the
  provider doesn't emit tool telemetry.
- Sidebar gains `Goals`, `Skills`, `Brain dump`, and `Costs` nav
  entries.

### Fixed

- **`PORT` env var now honoured by `mix phx.server`**. `config/
  dev.exs` hardcoded port 4000; set `PORT=4001 mix phx.server` to
  bind to an alternate port (UAT workflow).
- **Search endpoint (`/api/search`) now piped through the
  dashboard bearer-token gate.** On LAN exposure with
  `dashboard_token:` set, the palette API was enumerable without
  auth.
- **Recurring-task loop-back covers `write_frontmatter/2`**, not
  just `write/2`. The #237 commit missed a call site hit by agent
  self-reports, kanban detail-modal save, and denial actions.

---

## [0.0.3] — 2026-04-19

### Added

- **`glorbo import paperclip <src>`** — import a paperclip.ai
  `agentcompanies` tree into a Glorbo company directory. Detects
  paperclip's per-agent layout (`<agent>/AGENTS.md`, `HEARTBEAT.md`,
  `SOUL.md`, `TOOLS.md`), wraps each `AGENTS.md` in Glorbo
  frontmatter as `AGENT.md`, copies the rest verbatim, and prints a
  hint report naming every paperclip-ism (`$AGENT_HOME`,
  `PAPERCLIP_*` env vars, `paperclip-*` skills, `/api/...` HTTP
  calls) so the Director can hand-fix them. `--as <slug>` overrides
  the target name; `--force` overwrites only `agents/` on re-import.
- **Role-specific HEARTBEAT.md templates (GEP-14 extension).** CEO
  gets a 5-step company-stewardship loop (triage inbox → check
  roster → check goals → budget + health → exit cleanly) instead of
  the minimal 4-line default. Engineer + researcher get role-shaped
  per-tick checklists too. Scaffolding picks them up
  automatically via `priv/templates/heartbeats/<name>.md`.
- **CEO AGENT.md + SOUL.md expansion.** Active-stewardship system
  prompt (three concrete priorities: work flows / goals move /
  roster fits) + actions catalogue + constraints. SOUL gets
  owner-vs-observer stance.
- **Right-panel collapse on agent detail.** Thin 14px toggle rail
  between the center (stdout) and right (config + budget + perms)
  columns. Defaults collapsed on viewports < 1200px so stdout gets
  priority. Persists in localStorage.
- **Themed scrollbars** — universal scrollbar styling matches the
  phosphor palette (transparent track, thumb on
  `--gl-border-strong`, `--gl-accent-dim` on hover). Firefox
  + WebKit both covered.
- **`glorbo new agent <co>/<slug> --template <name>`** with
  SOUL.md + HEARTBEAT.md auto-wiring per template.
- **GEP-19 Director Approval Workflow Protocol** — retroactive
  Informational GEP capturing the `awaiting-approval-<task_id>.md`
  sentinel contract, frontmatter transitions, audit-event
  vocabulary, and the Gate-daemon vs UI-direct equivalence.
- **README dashboard screenshots** — six captures (overview,
  company, kanban, agent, approvals, providers) in a 2×3 table
  showing the terminal phosphor UI.
- **GEP-8 Provider Registry + CLI Auto-Detect** — config-driven CLI
  provider system. `priv/providers/*.toml` + optional
  `~/.glorbo/providers.toml` declare invocation shape, env overrides,
  reply contract, and usage-parser bindings. Six built-in providers:
  three tracked (`claude-code`, `codex`, `gemini-cli`) and three
  untracked (`hermes`, `opencode`, `pi`). New `/providers` LiveView
  dashboard. Detection runs on boot (PATH scan only); version probes
  run on explicit refresh and respect per-entry `allow_version_probe`
  opt-in for user-declared providers.
- `agent.md` gains `allow_untracked_budget: true` frontmatter opt-in
  for routing through `usage_parser = "none"` providers. Dispatch
  refuses otherwise.
- **Dashboard UX overhaul (M1-M5 sprint)** — mockup-aligned shell
  (tri-section sidebar, topbar with brand + company picker, terminal
  phosphor tokens), company overview with stat cards + agent roster
  + org chart, agent detail three-column layout (identity /
  tabbed stdout|sandbox argv|inbox-outbox|history / config + budget
  + permissions), Kanban drag-drop with status writeback to
  frontmatter, chat channel switcher + DM enumeration, approvals
  prompt-diff with `j/k/y/n` keyboard, audit unified free-text
  search, providers card grid with TOML snippet, global `g o/h/p`
  shortcuts, TWEAKS drawer with localStorage persistence, and
  `+ new company/agent/task` entry points that call the existing
  CLI scaffolds.
- **Approval workflow polish** — director/agent `assigned_to` swap
  on approval-request/grant/deny (requesting agent slug recovered
  via `awaiting-approval-<task_id>.md` sentinel when Gate isn't
  running), denial reason surfaced on approval card + threaded
  into audit JSONL + persisted to task frontmatter, denied-reason
  modal with Escape close, Gate audit events now use canonical
  `target:` field (matches UI-path shape).
- **Agent page interactions** — `edit AGENT.md` opens in-browser
  editor, `send message` opens Director DM, `stop` kills in-flight
  dispatch (proper reply tuple, tested), `wake` prompts for
  reason in a modal.
- **Chat ergonomics** — Enter sends / Shift-Enter newlines in
  channel compose, textarea autogrows with content, view fills
  viewport with messages scrolling under a pinned compose row,
  tail-pin autoscroll on new messages (user scroll-up unpins).
- **Stdout hardening** — mid-line `\r` and OSC window-title
  sequences stripped at the streamer (killed ghost gaps between
  paragraphs rendered under `white-space: pre-wrap`); trailing
  whitespace trimmed; autoscroll pins to bottom with tail-pin
  hook, unpins when user scrolls up; stdout pane stretches to
  viewport via `.gl-view--tall` opt-in.
- **Kanban** — drag-drop writes `status:` frontmatter, live task
  search across title/assignee/task_id, comment history in task
  detail modal, denial reason surfaced on denied cards, visual
  status tags for approved/denied, severity field wired
  end-to-end.
- **Accessibility sweep** — every role="button" surface gained
  `phx-keydown=… phx-key="Enter"` and a descriptive `aria-label`
  (task cards, agent table rows, approval rows, permission rows,
  file-tree actions became actual `<button>` elements, topbar
  TWEAKS button's aria-expanded reflects state).
- **Scaffolding entry points** — new-company / new-agent / new-task
  modals wire directly to `Glorbo.CLI.Scaffold.*`; scaffold "already
  exists" responses now surface as info (not error) flashes; the
  new-agent form's provider dropdown is populated from
  `Glorbo.CLI.Registry` and its HTML `pattern` matches the scaffold
  backend regex.

### Changed (Breaking)

- **Reply-file contract** (GEP-8 D1). Agents must now write their
  final reply to `$GLORBO_REPLY_PATH` — an absolute path exported to
  the CLI's env. On exit, an empty or missing reply file is an
  invocation failure. Existing agent system prompts must be updated
  to include a "write final answer to `$GLORBO_REPLY_PATH`" directive
  or their replies will surface as `:reply_file_empty` / `:reply_file_missing`.
- `Glorbo.Agent.Dispatch.execute/3` dep-inject keys changed:
  `:adapter_registry` + `:binary_fun` → `:provider_fun`. The
  `:run_fun` signature is now 4-arity
  `(args, env, bwrap_opts, run_opts_map)`.
- `Glorbo.CLI.Adapter` behaviour and its three implementations
  (`ClaudeCode`, `Codex`, `GeminiCli`) removed. Their parsing logic
  moved to `Glorbo.CLI.Parsers.{ClaudeJsonl, CodexJsonl, GeminiStdout}`.
- Gate audit event payloads renamed `task_path:` → `target:` and
  (for denials) `reason:` → `denial_reason:` so both daemon and
  UI-direct code paths emit identical JSONL shape.

### Fixed

- 5 Critical + 15 Important + 15 Minor code-quality findings from a
  2026-04-17 review. Notable: `Network.Proxy` pipe tasks now use
  `Task.Supervisor.async_nolink` (socket-cleanup ordering);
  `BudgetTracker.init` rehydrates `alerts_fired` from filesystem on
  crash (no duplicate alert files); `Company.Router` captures a
  single `DateTime.utc_now/0` per routing (filename + frontmatter
  now consistent); `Restore.extract` preserves pre-existing user
  data on symlink-escape rejection with `--force`;
  `Sandbox.Bwrap.drain_port` caps accumulated stdout at 16 MiB;
  `Ledger.record/1` (non-raising variant) added for callers that
  need error taxonomy.
- **Task body parser** — distinguishes markdown sub-headers (`###
  foo`) from new comment posts (`## YYYY-MM-DD …`); channel message
  parser gets the same treatment so agent-posted markdown with
  sub-headers doesn't fracture into spurious posts.
- **File editor modal** — X/cancel buttons now actually close; the
  blocking `onclick="event.stopPropagation()"` on the form was
  swallowing delegated phx-click events.
- **Agent status pill** — `:stop` now covers both director kills and
  unexpected crashes (was conflating `:idle` with `:stop`).
- **Approval flash** — UI-path denial no longer claims "moved to
  history" (that only happens via Gate; UI only rewrites
  frontmatter).
- **`gl-view--tall`** — correctly stretches via `flex: 1 min-height: 0`;
  previous commit introduced the class without the flex-grow.
- **Kanban layout** — all 4 columns fit without horizontal scroll.

### Meta

- GSD workflow retired 2026-04-17; design decisions now captured as
  GEPs under `docs/geps/`. The originally planned Podman
  container-runtime restoration has been dropped entirely (see
  GEP-5 D6); agents remain CLI-tool subprocesses under bwrap
  permanently.
- `skills-lock.json` pruned of 6 entries that weren't linked into
  `.claude/skills/` (docx / pdf / pptx / xlsx office skills,
  plus stale GSD plugins retired with the workflow).
- 895/895 tests passing, Credo strict clean, `mix gep.validate`
  clean at time of writing.

---

## [0.0.2] — 2026-04-16

> **Note on references below:** this entry was written while the
> `.planning/` GSD workspace was still live. Those paths were
> deleted 2026-04-17 (design records moved to GEPs under
> `docs/geps/`, everything else lives in git history). Path
> references below are left in place as they appeared at release
> time; `git log --all --diff-filter=D -- <path>` will find the
> deleted file if you need to read it.

Closes Milestone 01 (CLI-agent runtime) by shipping the dashboard and full CLI
surface on top of the v0.0.1 Phases 1-3 foundation. 5 phases / 20 plans / 219
commits / 621 tests green / 38-of-38 v0.0.2 requirements covered.

### Phase 5 — CLI Completeness + Backup/Restore Portability

#### Added

- Lifecycle verbs: `glorbo up` (detached daemon via `setsid`), `down`
  (SIGTERM → 10s grace → SIGKILL escalation), `status` (pidfile state
  machine: running/stale/missing), `serve` (foreground-blocking
  supervision tree start), and `run` (one-shot `reindex`-like scripts).
- Pidfile with atomicity invariants: `tmp + chmod 0600 + rename` write,
  fsync on close, mode-bit enforcement, TOCTOU re-check against the
  daemon pid at every lifecycle verb boundary.
- Scaffolding verbs: `new company <slug>`, `new agent <company>/<slug>`,
  `new project <company>/<slug>`. Slug regex guards against path
  traversal; default frontmatter matches DESIGN.md §5.
- `logs <company> [agent] [--follow]` with inotify-backed live tail;
  audit-log or `stdout.log` selection; rotation-aware (handles
  `YYYY-MM.jsonl` rollover without raising).
- `backup [--output <path>]`: WAL-checkpoint via
  `PRAGMA wal_checkpoint(TRUNCATE)` before archiving; `tar.gz` over
  `~/.glorbo/companies/`, `config.md`, and audit log; pidfile
  TOCTOU re-check between checkpoint and `:erl_tar.create`; chmod
  0600 on output; archive-bomb cap at 10 GiB uncompressed sum.
- `restore <archive> [--force]`: pre-extract traversal guard rejects
  entries starting with `/` or containing `..`; archive-size cap
  enforced from verbose tar table; post-extract symlink-target walk
  via `:file.read_link/1` rejects any symlink escaping the restore
  base (CR-01); post-extract chain `migrate → reindex → doctor --fix`
  (D-22); `:non_empty_base` guard bypassed only with `--force`.
- `console`: `iex --name console@127.0.0.1 --cookie <cookie> --remsh
  glorbo@127.0.0.1` against the running daemon; pidfile-gated
  (exit 3 if daemon not running); cookie read from
  `~/.glorbo/state/.erl_cookie` (mode 0600, atomic write).
- `migrate`: `Ecto.Migrator.run(Glorbo.Repo, _, :up, all: true)` with
  `rescue` for migration errors and `catch :exit` for Ecto exit signals
  (lock-contention / connection-pool failures surface as exit 2).
- `doctor --fix`: severity-weighted exit code (0 / 1 / 2), registry of
  7 fixers (`ollama_daemon`, `runtime_image`, `podman_missing`,
  `podman_socket`, `sqlite_wal`, `pidfile_stale`, `audit_dir_mode`),
  check→fix→recheck pattern; only counts `repaired` if recheck passes;
  missing-fixer for blocker checks returns non-zero.
- End-to-end portability test (`test/integration/portability_test.exs`):
  two-root A→archive→B extract + migrate + reindex + fixer roundtrip
  with hermetic hosts.
- Distribution release uses long-name node (`-name glorbo@127.0.0.1`)
  in `rel/vm.args.eex` to support `console` remsh (short-name rejected
  by BEAM when qualified with host).

#### Security

- **CR-01** — symlink-target path-traversal bypass: archives with benign
  entry names but escaping `linkname` no longer extract successfully;
  post-extract walker wipes partially-extracted base if any symlink
  resolves outside `~/.glorbo/`.
- **WR-03** — archive-bomb DoS vector closed: restore refuses archives
  whose uncompressed entry sizes sum above the 10 GiB cap.
- **WR-04** — backup pidfile TOCTOU closed: daemon-restart between
  `ensure_down` and `write_archive` now aborts the backup.
- **WR-07** — `Restore.maybe_fixer` no longer swallows doctor-fix
  errors silently; failures surface via `Logger.warning/1` with
  structured reason while preserving the `:ok` contract.
- `Config.write_default!` and `Config.erl_cookie` use
  tmp-write → chmod 0600 → atomic rename (closes write-then-chmod
  race that exposed the cookie at umask-default mode).

### Phase 4 — LiveView Dashboard + Real-Time Channels

#### Added

- Phoenix LiveView on `:4000` with 8 views: company overview, kanban
  board, agent detail with live `stdout.log` streaming, chat, approval
  queue, audit viewer, system health, and settings.
- Phoenix Channels + PubSub wired end-to-end to `file_system` (inotify)
  events — `~/.glorbo/companies/` mutations repaint the dashboard in
  under one second with no polling.
- Append-only channel markdown files with Elixir as the sole writer;
  browser POSTs route through the Channel controller which validates
  and appends; frontmatter `status:` transitions are frontmatter-first
  (file is truth).
- `@agent-name` mention posted to a channel wakes the named agent via
  the Router; approval-queue one-click approve/reject updates the task
  file's `status:` frontmatter and fires the wake.
- `GlorboWeb.Layouts.app` default layout wired for all LiveViews.

### Tests / Infrastructure

- 621/621 unit tests green. 52 integration tests excluded-by-default
  (require live host deps: `inotify-tools`, Podman, Ollama, real
  network, real `setsid`).
- `mix compile --warnings-as-errors` clean.
- Code review (standard depth) produced 1 Critical + 15 Warnings + 12
  Info across two rounds; all Critical + Warning findings closed
  (see `.planning/phases/05-cli-completeness-backup-restore-portability/05-REVIEW-FIX.md`).
- Milestone audit: 38/38 requirements covered, no integration gaps.
  10 human-verify items tracked as pre-release checklist (non-blocking).

---

## [0.0.1] — 2026-04-16 (unreleased)

First cut of the CLI-agent runtime milestone. Tag pending the first
`v0.0.1-rc1` signed release.

### Phase 3 — CLI Agent Runtime + bwrap Isolation + Routing + Budgets

#### Added

- Per-company OTP supervision tree with crash isolation: an agent
  crash restarts only that agent; a company crash restarts only
  that company's agents; dashboard and other companies unaffected.
- Inotify-driven inbox/outbox routing. Elixir is the only writer to
  `inbox/`; agents are the only writer to `outbox/`. Cross-agent
  messages are Router-mediated — no agent touches another agent's
  files directly.
- CLI agent adapters for **Claude Code** (`claude -p`), **Gemini
  CLI** (`gemini -p`), and **Codex CLI** (`codex exec -`). Session
  state + credentials `--ro-bind`ed from the Director's home into
  each sandbox via provider-specific env redirects
  (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, etc.).
- `bwrap(1)` sandboxing for every agent wake. Baseline:
  `--die-with-parent --unshare-user-try --unshare-ipc --unshare-pid
  --unshare-uts --unshare-cgroup-try --new-session --cap-drop ALL`.
  Workspace bind-mounted `rw`; outbox `rw`; inbox `ro`;
  per-permission mounts spliced in from `agent.md` frontmatter.
- Three-value network policy enforced by kernel:
  - `none` — `--unshare-net` (egress physically blocked).
  - `api-only` — inherits host netns; `HTTPS_PROXY` + `HTTP_PROXY`
    point at a `Glorbo.Network.Proxy` listener with a hostname
    allowlist (advisory).
  - `open` — inherits host netns; no proxy.
- Per-agent monthly budgets with JSONL usage ledger, dashboard
  alerts, and hard-stop at cap.
- Skills injection: `.glorbo/skills/` markdown files discoverable
  and attachable per-agent via frontmatter.
- Director approval gates: tasks with `requires_approval: director`
  frontmatter pause until the Director explicitly approves.
- Append-only `audit/YYYY-MM.jsonl` per company. Action vocabulary
  fixed in `AUDIT_EVENTS.md`. Mode bits prevent group/other write.
- Permission model: two-layer enforcement by design. Elixir Router
  (application) and bwrap mounts (kernel). Extending to POSIX ACLs
  inside Podman containers in v0.0.2.

#### Security

- **SEC-03** (`--unshare-net` kernel-enforced egress block) validated
  on Fedora 43 dev host: `curl --max-time 3 https://api.anthropic.com`
  inside a `network: none` sandbox returns exit 7 with no packet
  ever leaving the host.

### Phase 2 — Filesystem Foundation + Container Runtime + Local LLM

#### Added

- `glorbo init` bootstrap: verifies deps, materialises `~/.glorbo/`
  hierarchy, prepares (deferred) Podman/Ollama integration
  scaffolding, writes the initial config.
- `~/.glorbo/` directory hierarchy per `DESIGN.md` §3:
  `companies/`, `containers/`, `bin/`, `models/`, `audit/`,
  `sockets/`, `state/`, `config.md`, `glorbo.db`.
- `glorbo doctor` extended with 8 new checks: `podman`, `ollama`,
  `ollama_daemon`, `runtime_image`, `runtime_exec`, `audit_dir`,
  `sockets_dir`, `tar_zstd`. Severity-weighted exit code (0 /
  warning / blocker).
- `glorbo reindex` rebuilds SQLite state fully from markdown/JSONL
  on disk. The SQLite DB is derived data — delete anytime.
- Append-only system audit log at `audit/_system/YYYY-MM.jsonl`
  recording `init.step.*` actions during bootstrap.
- Podman + Ollama + `glorbo-runtime` container design preserved
  for restoration in v0.0.2; dormant in v0.0.1 codebase
  (`.planning/deferred/container-runtime-v0.0.2/`).

### Phase 1 — Compilable Skeleton + CI Release Pipeline

#### Added

- Elixir 1.18.4 / OTP 28.0.2 toolchain, pinned via `.tool-versions`.
- Phoenix 1.8 skeleton with SQLite WAL (`ecto_sqlite3`), trimmed
  of esbuild/tailwind/heroicons scaffolding (reintroduced in
  Phase 4).
- `mix glorbo.doctor` CLI skeleton with 5 baseline checks:
  `linux_kernel`, `uidmap`, `disk_space`, `glorbo_dir`,
  `erts_version`.
- `/health` endpoint (replaces generated `/` home page).
- `Burrito`-packaged single-binary release pipeline for Linux
  x86_64 and aarch64, with bundled ERTS and Zig cross-toolchain.
- GitHub Actions CI matrix: compile-as-errors, test, Credo
  strict, format check, release build, binary smoke test, artifact
  upload.
- Cosign keyless signing (Sigstore OIDC) on tagged `v*.*.*`
  releases. `SHA256SUMS` + `.sig` per artifact.
- SQLite WAL journal mode enabled in `dev.exs`, `test.exs`,
  `runtime.exs` (FND-02).
- Credo strict mode with project-specific tunings
  (`CyclomaticComplexity` to 20 for dispatch-table functions,
  `Nesting` to 3, `AliasUsage` threshold relaxed).

### Infrastructure — Repository hygiene

#### Added

- `README.md` with Glorbo brand logo, OSS badges (CI, release,
  license, Elixir/OTP, platform, security, PRs, last-commit),
  and phase-accurate v0.0.1 scoping.
- `SECURITY.md` — vulnerability reporting policy tailored for
  Glorbo's sandbox-as-trust-boundary threat model. GitHub Private
  Vulnerability Reporting as primary channel; 72h ack, 90-day
  coordinated disclosure, safe harbor clause.
- `CONTRIBUTING.md` — dev setup, PR flow, Conventional Commits,
  quality gates, DESIGN.md invariants, review checklist.
- `LICENSE` — Apache License 2.0.

#### Changed

- Dropped Python-in-Podman agent runtime from v0.0.1 scope
  (deferred to v0.0.2). DESIGN.md and README now annotate the
  shift explicitly. The dormant container design is preserved at
  `.planning/deferred/container-runtime-v0.0.2/` for restoration.

#### Fixed (CI pipeline)

- Replaced `${@:3}` bash-ism in bwrap launcher shell with POSIX
  `shift 2; exec "$b" "$@" < "$p"` — Ubuntu's `/bin/sh` is dash
  and rejected the array slice.
- Installed unconfined AppArmor profile for `/usr/bin/bwrap` on
  Ubuntu 24.04 runners to work around
  `kernel.apparmor_restrict_unprivileged_userns=1`, which blocked
  `--unshare-net` loopback setup with `RTM_NEWADDR: Operation not
  permitted`.
- Installed `bubblewrap` package on CI runners (not default on
  ubuntu-24.04).
- Removed invalid `E` regex modifier in `config/dev.exs`
  live_reload patterns — Elixir 1.18 parses strict modifiers.
- Loosened smoke-test `.checks | length` assertion from `== 5` to
  `>= 5` to stay resilient as phases add doctor probes (Phase 1:
  5; Phase 2: +8; Phase 3: +2; total 16).
- Guarded the "unknown-command exits 1" smoke assertion against
  `bash -e` — the `( cmd; ec=$?; test ... )` subshell tripped
  errexit before capturing the exit code.

---

<!-- Link refs for GitHub -->
[Unreleased]: https://github.com/foobarto/glorbo/compare/v0.0.4...HEAD
[0.0.4]: https://github.com/foobarto/glorbo/releases/tag/v0.0.4
[0.0.3]: https://github.com/foobarto/glorbo/releases/tag/v0.0.3
[0.0.2]: https://github.com/foobarto/glorbo/releases/tag/v0.0.2
[0.0.1]: https://github.com/foobarto/glorbo/releases/tag/v0.0.1
