---
gep: 0024
title: Task scheduler — firing scheduled dispatches from `schedule:` frontmatter
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Informational
created: 2026-04-21
history:
  - date: 2026-04-21
    status: Draft
    note: Retrofit GEP capturing the TaskScheduler design shipped in `053fc84`.
  - date: 2026-04-21
    status: Implemented
    note: Shipped in v0.0.3-dev as commit `053fc84` with 8 unit tests green.
requires: [2, 3]
see-also: [14, 16]
implemented-in: v0.0.3-dev
---

# GEP-0024: Task scheduler — firing scheduled dispatches from `schedule:` frontmatter

This is an **Informational** GEP that retrofits the design behind
`Glorbo.Company.TaskScheduler`, shipped on 2026-04-21 as commit
`053fc84`. Shipping-then-documenting is allowed under GEP-1 §"When
to retrofit"; this is that retrofit.

## Problem

Tasks have carried a `schedule:` field in their frontmatter since
#237 (2026-04-18). `schedule:` accepted any string: a 5-field cron,
a keyword like `"daily"`, or even natural language. Until this GEP,
the runtime **rendered** scheduled tasks (the `↻ <schedule>` pill
on the kanban card, recurring-loopback on `done → todo`) but
**never actually fired them**. A task that said
`schedule: "0 9 * * 1-5"` sat in `todo` forever unless a human
clicked "dispatch".

That's user-visible lying: the UI promises behaviour the runtime
can't deliver. #268 (this GEP) closes the gap.

### Context from adjacent GEPs

- **GEP-14** (Agent heartbeat semantics) — defines the per-*agent*
  cron runner. That scheduler wakes agents on `heartbeat:` cron
  from `AGENT.md`, consulting `HEARTBEAT.md` to decide whether the
  wake should dispatch. Task-level scheduling is a different
  concern with a different key space (task_id vs agent_slug); this
  GEP adds a sibling runner, not a subclass.
- **GEP-16** (Agent wake / dispatch pipeline) — defines how a
  dispatch becomes an inbox event + bwrap invocation +
  `agent.dispatch` audit record. TaskScheduler's fire path
  deliberately feeds into that pipeline at the inbox-write step,
  rather than calling `Dispatch.execute/3` directly. See D2 below.

## Goals

1. Tasks with a parseable `schedule:` field fire dispatches at
   their scheduled times, without director intervention.
2. The firing emits auditable events that show up in the #264
   task-history panel.
3. Malformed schedules never crash the scheduler; they log an
   audit event and are skipped.
4. Zero new persistent state files. The filesystem (task
   frontmatter) plus the append-only audit log are the source of
   truth. Filesystem-is-truth invariant preserved (GEP-3).
5. No breaking change to #237 semantics (`↻` pill, done→todo
   loopback).

## Non-goals

- **Natural-language schedule parsing** ("every weekday at 9am").
  A keyword alias table covers the common shapes;  free-form NL
  needs a parser + timezone awareness + edge-case audit this GEP
  does not tackle. See D6.
- **A schedule-editor UI.** Frontmatter is edited via the existing
  task-detail form; no new form controls.
- **Per-task timezone pinning.** All schedules resolve against
  `Etc/UTC`. Director in a non-UTC zone interprets their own
  cron.
- **Backfill of missed fires across restarts.** If the BEAM is
  down at the scheduled time, the fire is lost for that tick.
  See D5.
- **Replacing the existing `Glorbo.Company.Scheduler`** (agent
  heartbeats). The two coexist as siblings.

## Design

### Location in the supervision tree

```
Glorbo.Company.Supervisor
├── Glorbo.Company.AuditLog
├── Glorbo.Filesystem.Watcher
├── Glorbo.Company.Router
├── Glorbo.Company.Scheduler        # agent heartbeats (GEP-14)
├── Glorbo.Company.TaskScheduler    # task-level cron dispatches (THIS GEP)
├── Glorbo.Company.BudgetTracker
├── Glorbo.Company.AgentSupervisor
├── Glorbo.Approvals.Gate
└── Glorbo.Company.AgentBoot
```

Child-count assertions in three test files were bumped 8→9 (10
with the optional `Network.Proxy`).

### Lifecycle

1. **Boot** (`init/1`) subscribes to `company:<co>:projects`
   PubSub (unless `subscribe?: false` for tests) and sends a
   self-message `:initial_scan`. On `:initial_scan` it scans
   `projects/*/tasks/*.md`.
2. **Scan** (`do_scan/1`) walks the task tree, parses each task's
   frontmatter, and for every parseable `schedule:` arms a
   one-shot `Process.send_after(self(), {:fire, task_id},
   delay_ms)`.
3. **Rescan triggers**:
   - Any `{:file_event, rel_path, _}` under `projects/*/tasks/`
     from the Watcher PubSub.
   - A 60-second self-scheduled rescan as a safety net against
     missed inotify events (`auto_rescan?: true` default).
4. **Fire** (`handle_info({:fire, task_id}, state)`) re-reads the
   task file (defensive — schedule may have been removed, file
   deleted), writes a synthetic inbox message to
   `agents/<assignee>/inbox/sched-<uniq>-<task_id>.md`, emits a
   `task.scheduled_dispatch` audit event, then re-arms for the
   next scheduled time.

### Fire message shape

```
---
from: scheduler
task_path: projects/foo/tasks/foo-1.md
scheduled_at: "2026-04-21T10:00:00Z"
cron: "0 * * * *"
---

<task body copied verbatim — the same text that appears below the
 `---` fence of the task file>
```

The assignee's inotify watcher picks it up as a standard inbox
event; `Glorbo.Agent.Server` wakes with trigger `:inbox` and
dispatches via the normal GEP-16 pipeline.

### Accepted schedule formats

- 5-field crontab: `"0 9 * * 1-5"`
- Keyword aliases (case-insensitive, `@` prefix optional):
  - `hourly` / `@hourly` → `0 * * * *`
  - `daily` / `@daily` → `0 0 * * *`
  - `weekly` / `@weekly` → `0 0 * * 0`
  - `monthly` / `@monthly` → `0 0 1 * *`
- Anything else → `scheduler.invalid_task_cron` audit event, task
  is skipped until its frontmatter changes. The scheduler never
  crashes on a malformed schedule.

### Audit events emitted

| action                         | actor     | when                                          |
|--------------------------------|-----------|-----------------------------------------------|
| `task.scheduled_dispatch`      | scheduler | After a successful fire (inbox write + body). |
| `scheduler.invalid_task_cron`  | system    | A `schedule:` string fails cron parse.        |
| `scheduler.missing_assignee`   | system    | A valid-cron task has no `assigned_to`.       |
| `scheduler.dispatch_failed`    | system    | Inbox write fails (disk full, permission).    |

`scheduler.invalid_task_cron` is only emitted when the schedule
changes (via a cached `prev[:schedule]` comparison) to avoid
flooding the audit log every 60-second rescan.

### Dep-injection surface

| Key                | Default                       | Test hook       |
|--------------------|-------------------------------|-----------------|
| `clock_fun`        | `&DateTime.utc_now/0`         | freeze clock    |
| `send_after_fun`   | `&Process.send_after/3`       | capture `{dest, msg, delay}` |
| `audit_fun`        | Registry lookup → AuditLog    | capture entries |
| `write_inbox_fun`  | `File.mkdir_p` + `File.write` | capture writes  |
| `subscribe?`       | `true`                        | set `false` for pure-unit tests |
| `auto_rescan?`     | `true`                        | set `false` to disable background rescan |
| `rescan_ms`        | `60_000`                      | shorten for stress tests |

## Migration / rollout

- **Backwards compat.** Any task with an unparseable `schedule:`
  silently becomes a no-op fire (`scheduler.invalid_task_cron`
  audit, no dispatch). No breaking change to #237's rendering or
  loopback semantics.
- **Supervisor child-count bump.** Three test files updated:
  `test/glorbo/company/supervisor_test.exs`,
  `test/glorbo/filesystem/watcher_test.exs`,
  `test/glorbo/application_test.exs`. No production config
  change needed.

## Failure modes

| Failure                                | Behaviour                                     |
|----------------------------------------|-----------------------------------------------|
| Task file deleted between arm and fire | Fire re-reads; on `{:error, :enoent}` drops the task from state. |
| Schedule removed between arm and fire  | Fire re-reads; if `schedule == ""` drops the task. |
| Inbox write fails (disk full, perm)    | `scheduler.dispatch_failed` audit; task stays armed for the next tick. |
| BEAM restart during a fire window      | That tick is lost; rescan on boot re-arms for the next scheduled time. |
| Missing assignee                       | `scheduler.missing_assignee` audit; re-arm for next tick (schedule may pick up an assignee later). |
| Unparseable cron                       | `scheduler.invalid_task_cron` audit once; task skipped until the string changes. |

## Test strategy

Eight unit tests cover every branch via dep-injected helpers (no
real timer armed, no PubSub, no filesystem writes beyond the
per-test temp dir):

1. Arms a timer for a task with a valid schedule.
2. Ignores tasks without a schedule.
3. Invalid cron emits `scheduler.invalid_task_cron` + skips arm.
4. Honours keyword aliases.
5. Fire writes to assignee inbox + emits audit.
6. Missing assignee emits `scheduler.missing_assignee` + no write.
7. Fire re-reads — schedule removed between arm and fire drops it.
8. Stale entries removed on rescan when file deleted.

No integration test yet. See "Open questions" below.

## Open questions

- **Should the scheduler go through `Router.route/2` like a real
  sender?** Today it bypasses the Router's ACL pipeline, matching
  the existing `wake_agent/4` convention for system-initiated
  writes. If you want the pipeline, the scheduler needs a
  synthetic sender identity (`scheduler@<co>`?) that ACLMapper
  recognizes. Revert vector: swap `default_write_inbox/4` for a
  `Router.route/2` call. Currently open.
- **Visual "next fire at ___" indicator on TaskLive.** Scheduler
  has the data (`state.tasks[task_id].next_at`), just needs
  rendering. Tracked as follow-up in TODO.md.
- **`task.scheduled_dispatch` PubSub broadcast verification.** The
  #264 task-history panel relies on `company:<co>:audit`
  broadcasts for live refresh. Need to verify end-to-end that
  scheduler fires surface without waiting for the next inbox
  wake. Tracked as follow-up in TODO.md.
- **Natural-language schedule parser.** Deferred pending real user
  demand.

## Decision log

**D1 — Separate `TaskScheduler` module, not an extension of
`Glorbo.Company.Scheduler`.**

- **Decided:** Ship a new GenServer `Glorbo.Company.TaskScheduler`
  as a sibling child under `Company.Supervisor`.
- **Alternatives:** (a) extend the existing Scheduler with a new
  entry kind; (b) fold task firing into the `AuditLog` handle_info
  loop.
- **Why:** The existing Scheduler's scope is cleanly "agent-level
  heartbeats" (keyed by `agent_slug`, reads `AGENT.md`,
  consults `HEARTBEAT.md`). Task-level dispatch is a different
  key space (task_id), reads a different config source
  (`schedule:` in task frontmatter), and has no HEARTBEAT.md
  equivalent. Two small modules with clear boundaries beat one
  module with two modes. AuditLog is a log — adding cron logic
  to it would conflate concerns.

**D2 — Fire writes synthetic inbox messages instead of calling
`Dispatch.execute/3` directly.**

- **Decided:** On fire, write
  `agents/<assignee>/inbox/sched-<uniq>-<task_id>.md` with the
  task body as prompt; let the existing inotify → Agent.Server
  `:inbox` wake → GEP-16 dispatch pipeline take over.
- **Alternatives:** (a) call `Dispatch.execute/3` directly; (b)
  fabricate a wake-request.md (director-wake style).
- **Why:** (a) couples the scheduler to dispatch internals
  (provider resolution, budget tracking, run-log, audit) that
  already run correctly off an inbox event. Why duplicate the
  wiring? (b) conflates "scheduled run of task X" with "director
  wakes agent" — the audit would show `actor: director`, not
  `actor: scheduler`. Inbox-write keeps the actor correct and
  adds no new code paths. The bypass of `Router.route/2` is
  consistent with `wake_agent/4` (system-initiated writes
  bypass the ACL pipeline by convention). Flagged as an open
  question for future tightening.

**D3 — Audit-log-is-truth; no persistent state file.**

- **Decided:** Timer state (which tasks are armed, their next-fire
  time, their timer ref) lives in GenServer memory only. On BEAM
  restart, the scheduler re-arms from disk via the boot scan.
- **Alternatives:** A `_scheduler_state.json` file recording
  last-fire timestamps for de-dup across restarts.
- **Why:** Filesystem-is-truth (GEP-3). Adding a new state file
  creates a new invariant to maintain, new failure modes
  (partial write, corruption, staleness vs disk), and a new
  coherence story for `glorbo reindex`. A missed fire across
  restart is cheap to absorb (tasks are idempotent-ish; the next
  scheduled tick picks up). The audit log already records every
  successful fire — if you *really* need backfill, a future GEP
  can add scan-on-boot-with-audit-dedup without replacing the
  core.

**D4 — Closed keyword-alias table, not NL parsing.**

- **Decided:** Support `hourly`/`daily`/`weekly`/`monthly` plus
  the `@`-prefixed variants. Anything else falls through to the
  `Crontab.CronExpression.Parser` and is skipped on parse error.
- **Alternatives:** Accept arbitrary NL ("every morning at 9am")
  like #237 already does at the UI layer.
- **Why:** NL parsing for cron is a rabbit hole (timezone, DST,
  ambiguous "morning", edge cases like "every other Tuesday").
  The keyword aliases cover the 90% case in <10 lines. If
  users demand NL, add it in a follow-up GEP with a real parser
  library (e.g. `cronex`). The #237 NL *display* stays; this
  GEP only parses actual crons.

**D5 — Never crash on a malformed schedule.**

- **Decided:** On cron parse error, emit
  `scheduler.invalid_task_cron` audit once (deduped by
  `prev[:schedule]`) and skip. No `raise`, no supervisor
  restart.
- **Alternatives:** Raise and let the supervisor restart, which
  would retry the scan and repeatedly fail the same task.
- **Why:** One user-typo shouldn't halt the scheduler for every
  other task in the company. Audit visibility + silent skip is
  the right failure mode.

**D6 — 60s background rescan as a safety net on top of inotify.**

- **Decided:** In addition to `{:file_event, _, _}` event-driven
  rescans, schedule a self-message `:rescan` every 60 seconds
  (`rescan_ms`).
- **Alternatives:** (a) rely purely on inotify; (b) no rescan,
  explicit manual `:scan` call only.
- **Why:** Inotify on Linux is reliable but not bulletproof
  (buffer overflows on very busy trees, mount-boundary quirks,
  missed events on atomic rename). The 60s catch-all rescan
  costs O(projects × tasks) filesystem reads — fine up to
  hundreds of tasks; revisit past ~1000 tasks with an mtime
  cache (pattern already used by Search.scan_tasks).

**D7 — `Etc/UTC` for all schedule resolution.**

- **Decided:** Convert `DateTime.utc_now/0` to NaiveDateTime,
  pass to `Crontab.Scheduler.get_next_run_date/2`, convert the
  result back to `DateTime` with `Etc/UTC`. No per-task
  timezone pinning.
- **Alternatives:** Per-company timezone or per-task timezone.
- **Why:** Directors running a single-company local Glorbo
  interpret `0 9 * * 1-5` in their head as "9 AM local". If the
  host wall-clock is local, they're implicitly matched; if
  it's UTC, they consciously pick UTC-relative crons. Adding
  timezone config now would front-load complexity before a
  concrete user ask. A future GEP can add
  `timezone: Europe/Warsaw` in task frontmatter when needed.

## Related

- **GEP-2** (architecture overview) — invariants preserved.
- **GEP-3** (filesystem-is-truth) — no new state file
  introduced.
- **GEP-14** (agent heartbeat semantics) — sibling scheduler;
  different key space + config source, same `crontab`
  dependency.
- **GEP-16** (agent wake/dispatch pipeline) — scheduler feeds
  into this pipeline at the inbox-write step.
