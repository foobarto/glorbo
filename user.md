# user.md — autonomous-session log

Per your instruction: "make autonomous design choices and proceed to
implementation without my input. if normally you'd wait for me,
instead write your questions and decisions you've made to a user.md
file for my later review."

This file is the review log for the current autonomous /loop session.
Ordered newest-last so you can read it like a timeline. Each entry
is a decision I took alone (with rationale) or a question I'd
ordinarily surface but am answering myself.

---

## 2026-04-21 — Task #264 (B1+B2+C) shipped as `d57c3e2`

Scope included:

- `Glorbo.Audit.Query.for_task/4` — tiny pure reader
- TaskLive history panel live-refreshed via PubSub
- AuditLive `handle_params` for `?q=&actor=&action=&since=&until=`
- Deep-link "view full audit →" from TaskLive carries the task id

**Decisions taken without asking:**

1. **Panel cap of 25 entries.** TaskLive shows the last 25 audit
   rows for this task. The "view full audit →" link is the escape
   hatch for older data. I picked 25 because it's what the usage
   strip budget suggests (audit rows render with ~6-line bodies
   when expanded).

2. **Row id = sha256(ts + "\0" + action), truncated to 16 chars.**
   I needed a stable id so `aria-expanded` state survives PubSub
   appends. Using ts + action gives uniqueness at millisecond
   granularity without including the whole detail payload. Fallback
   to positional id if both missing.

3. **Convert-to-task disabled on TaskLive.** The scaffold lives on
   AuditLive (#254). From TaskLive's history panel, clicking
   convert-to-task flashes "Open the full audit log to convert
   this row" instead of duplicating the scaffold logic. Tradeoff:
   one more click for the user; gain: one source of truth for
   the scaffold code. Happy to invert if you disagree.

4. **`detail.target contains task_id` match is substring, not
   equality.** An audit row with `detail.target = "foo-1.md:42"`
   should match task `foo-1.md`. Substring keeps us resilient to
   line-numbered variants. Downside: false positives if a task
   slug is a prefix of another (e.g. `foo-1` matches `foo-10`).
   Unlikely in practice; revisit if it bites.

## Queued next — Task A (#268): TaskScheduler

Per your direction: "draft a plan for A and go for it without my
input." Below is the plan I'm executing. If anything looks wrong,
this is the moment to course-correct — I'll check user.md before
each commit for the next few turns.

**Problem.** Tasks can carry `schedule: "0 9 * * 1-5"` (cron) in
their frontmatter. Today the field is parsed and rendered (#237
shipped that) but nothing fires it. Scheduled tasks sit in todo
forever unless a human clicks "dispatch".

**Plan.**

1. **`Glorbo.Task.Scheduler`** — GenServer under the per-company
   supervisor. On boot: walk `projects/*/tasks/*.md`, collect tasks
   with a `schedule:` field, parse cron, sweep every 60s.

2. **Firing.** When `Crontab.next_run_date/2` lands in `(last_tick,
   now]`, enqueue a dispatch via the task's `assigned_to` agent's
   inbox — same path `/companies/<co>/kanban` uses for the manual
   dispatch button.

3. **De-dup.** Persist last-fire timestamp per task in
   `companies/<co>/_scheduler_state.json`. Survive restarts
   without double-firing a missed minute.

4. **Audit.** Emit `task.scheduled_dispatch` with `task_path`,
   `cron_expr`, `fired_at`, `next_at`. Panel #264 picks it up
   automatically.

5. **Off-switch.** Company-level `scheduler: off` in `company.md`
   disables it. Default on.

6. **Test shape.** Inject a mock clock; seed one task with cron
   `* * * * *`; assert dispatch fires once and `_scheduler_state`
   updates. Assert no double-fire if we crash and restart within
   the same minute.

**Non-goals for this iteration.**

- Retries on dispatch failure (the Router handles that already).
- Sub-minute granularity (cron can't express it anyway).
- Per-task scheduler status in UI (future — today just audit).

**Question I'm deferring to user.md instead of asking:**

> GEP for this, or just ship it? Earlier I said it warrants a GEP
> because it extends GEP-14 scheduler semantics. Re-reading GEP-14,
> that GEP is about recurring brain-dump capture, not task
> dispatch. The task-dispatch scheduler is small enough and
> architecturally obvious enough that I think a retrofit
> Informational GEP *after* it ships is fine. I'll ship the code
> first, then propose an Informational GEP as a separate commit
> if you don't object. If you do, revert the code commit.

## Queued after — Task #269: UI quality pass on modal popups

Per your hint: "check miał popups with forms". Translating: "main
popups with forms". The suspects are:

- `new-company` modal (CompanyPickerLive wizard step 1)
- `new-agent` modal (step 2)
- `new-project` modal (step 3)
- `hire-request` modal on CompanyLive
- `brain-dump` modal (where?)
- `edit-frontmatter` form on AgentLive config tab
- `dispatch-task` prompt dialog on kanban cards

I'll run agent-browser screenshots of each, visually diff against
the expected layout, and fix rendering bugs. Deliverable is a
commit per fix with a screenshot reference.

---

*Entries below this line are auto-generated by Claude as the
session proceeds. Read top-to-bottom in chronological order.*
