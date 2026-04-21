# Changelog

All notable changes to Glorbo will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0 caveat: APIs, CLI flags, on-disk layout, and SQLite schema may
change between minor versions. Pin exact versions in downstream usage.

## [Unreleased]

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
[Unreleased]: https://github.com/foobarto/glorbo/compare/v0.0.3...HEAD
[0.0.3]: https://github.com/foobarto/glorbo/releases/tag/v0.0.3
[0.0.2]: https://github.com/foobarto/glorbo/releases/tag/v0.0.2
[0.0.1]: https://github.com/foobarto/glorbo/releases/tag/v0.0.1
