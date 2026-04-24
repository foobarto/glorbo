# Autonomous-work protocol

When the user asks the agent to "keep going," "run autonomously
for a while," "pick something from the punch list while I'm
away," or similar — follow this protocol. It's a discipline for
unattended work that keeps the blast radius bounded and the
trail legible.

This doc covers both modes:

- **Round** — one cycle, stop when done, hand control back.
- **Loop** — repeat rounds, schedule next wakeup, stop on
  checkpoint or stop criterion.

The substance (task pick, gates, commit, journal) is identical.
The delta is *what happens after step 8 of the loop*: stop
(round) or schedule-and-continue (loop).

## Governing principles apply first

Before anything else, re-read
[governing-principles.md](governing-principles.md). The loop is
how you execute; the principles are what make execution
legible. Every decision the protocol asks you to log is a
chance to apply them.

## Autonomy-level calibration (first step of every round / loop)

At the **start** of autonomous work, confirm which level of
autonomy is expected. If the user's instruction unambiguously
specifies a scope ("just finish the Kanban refactor" → L2 on
that specific work), skip the menu. Otherwise present this
menu once, cache the answer for the session:

```
Autonomy level for this <round|loop>?

  [L0] Supervised — ask before picking any task. Default for
       risky or unfamiliar projects.
  [L1] Conservative — pick bounded tasks, gate, commit. Do
       NOT touch Drafts, Placeholders, or in-progress partials.
  [L2] Partials too (default) — L1 plus: finish in-progress
       work (half-written Drafts, stub modules, missing E2E).
       No new proposals from scratch, no status promotions.
  [L3] Expansive — L2 plus: promote Placeholder → Draft when
       design space is settled; never push.
  [L4] Publish — L3 plus: push to remote after all gates green.
       Rare and opt-in.

Pick [L0/L1/L2/L3/L4] (default: L2):
```

**Default is L2.** Most autonomous asks are "finish what's
in-flight, don't start greenfield work, don't push." If the
user wants tighter or looser scope they'll say so.

The project profile (if present) can cap the menu — e.g., a
project profile declaring "risk tolerance: conservative" caps
at L1 even when the user's global preference is L2.

Record the selected level in the session journal as part of
the round's first entry.

## The loop (one cycle)

1. **Check for user input** since the last wakeup (loop mode)
   or since the user's triggering message (round mode). If a
   new message has arrived, abandon the cycle and address it.
2. **Verify prerequisites.** `docs/todo.md` exists. Session
   journal for today exists or will be created. Working tree
   is clean (no uncommitted changes from an earlier task).
3. **Pick one bounded task** from `docs/todo.md`:
   - L0: ask the user.
   - L1: P0 first → P1 only if no open Draft/Placeholder
     blocks the path.
   - L2: P0 → P1 → in-progress partials (Drafts, stubs,
     missing tests for shipped features).
   - L3: L2 plus status promotions (Placeholder → Draft) when
     the design space is settled.
   - L4: L3 plus push authority after green gates.

   The `autonomous-planner` sub-agent (if cairn is installed on
   Claude Code) is a good read-only helper here — it inspects
   `docs/todo.md` + recent journals and returns a task
   recommendation with rationale.

   Bounded means: you can finish, gate, and commit in one turn,
   you know what "done" looks like before starting, and no open
   design decisions block the path.
4. **Announce the pick** in today's session journal. One
   sentence: *Picked X because Y. Autonomy level: LN.* If
   multiple plausible tasks exist, list the ones passed over
   and why.
5. **Implement.** Log design calls you take without asking, in
   the journal, as you take them. Follow the governing
   principles — surgical changes, simplicity first.
6. **Gate.** Run the project's tests, linter, formatter, and
   any precommit checks. Record tool + command + result in the
   *Gates* block. Check exit codes where the tool reports
   warnings without non-zero exit.

   If the review-phase skill is available (cairn v0.2.0+), run
   it here: it orchestrates quality + security passes using
   whatever tools the project has.
7. **Commit locally.** Conventional-commit style subject; body
   explains the *why* if non-obvious; reference the task you
   picked. No pushes unless L4 and the project authorises it.
8. **Decide: continue or stop.** See "When to stop," below.

## Round mode — after step 8

- Write the handoff summary at the end of the session journal.
  No next wakeup scheduled.
- Return control to the user. The round is done.

## Loop mode — after step 8

- Check commit-count checkpoints (see below).
- If continuing: schedule the next wakeup (20-60 min cadence is
  a good default for open-ended work).
- If stopping: write the handoff summary. No next wakeup.

## Hard rules (ALWAYS, every level)

- **Never push** unless you're at L4 *and* the user's
  instructions have explicitly authorised pushes.
- **Never force-push or rewrite** commits that have been
  pushed, or that touch others' work.
- **Never start implementation** of a proposal whose status is
  `Draft` or `Placeholder` unless you're at L2+ and the task
  you picked is to finish a specific in-progress partial.
  Never promote proposal status below L3.
- **Never bypass safety gates** (`--no-verify`, `--no-gpg-sign`,
  skipping precommit). If a gate fails, diagnose the underlying
  issue.
- **Never delete unfamiliar files or branches.** If you find
  something you don't recognise, leave it alone and note it in
  the journal.
- **Never send messages to chat platforms, ticket systems, or
  external services** without explicit authorisation. The
  session journal is the sanctioned status-update channel for
  autonomous work.
- **Never start a second task in the same turn.** One task per
  turn, period.

## Mid-cycle "ask anyway" cases

Even mid-round, some decisions deserve stopping to ask:

- Risk of data loss, shared-state corruption, or a hard-to-
  reverse action (schema migration, force-push, file deletion).
- The user's instructions could be interpreted two very
  different ways — pick one visibly and ask, don't silently
  choose.
- The change would touch files the user clearly intended to
  work on themselves (recent untracked edits, half-finished
  branches, etc.).
- The "bounded" task ballooned mid-implementation (30 lines →
  300 lines, 1 file → 5 files). Stop. Either re-scope or ask.

## When to stop the loop

Stop (don't schedule next wakeup) if:

- **Blocker hit** beyond your authority — design decision,
  ambiguous failing gate, shared-state risk.
- **No bounded task available** — P1 cleared, P2 items are all
  "revisit if feedback complains" placeholders. Don't force a
  pick.
- **Commit checkpoint reached** — see below.
- **User message arrived** mid-cycle.
- **Commit failed** (hook rejection, unresolvable compile
  error).

## Commit checkpoints (loop mode only)

- **3 commits in the session** (soft checkpoint): notify the
  user via the journal's handoff section, wait for approval to
  continue past the checkpoint. Don't auto-schedule another
  wakeup.
- **5 commits in the session** (hard stop): stop
  unconditionally. Silent prolific output without a user
  checkpoint erodes trust faster than fewer commits plus a
  clear handoff.

These are overridable: if the user explicitly asks for a long
loop ("run all night"), the checkpoint shifts to "every N
hours of wall time" or "until the punch list clears." Log the
override in the journal.

## Handoff summary

When the loop or round ends (for any reason), the last action
in the session journal must be a handoff block:

```markdown
## Handoff — <timestamp>

**Shipped this <round|loop>:** <commit SHAs + one-liners>.

**Autonomy level used:** <L0/L1/L2/L3/L4>.

**Stopped because:** <which stop criterion applied>.

**Queued if you want more:** <tasks considered next but not
picked — or "nothing obvious">.

**For your review:** <specific yes/no questions parked above>.
```

Terse, honest, no filler. That's what the user reads when
they get back.
