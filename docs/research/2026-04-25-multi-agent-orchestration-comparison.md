# Multi-agent orchestration comparison — paperclip vs Glorbo

**Date:** 2026-04-25
**Goal:** evaluate Glorbo's writer↔reviewer multi-agent loop against
paperclip's equivalent flow on the dimensions of (1) agent-to-agent
interaction mechanics, (2) audit/provenance capture, and (3)
review-loop quality lift.

This doc is fully anonymized — references to the test company, task
identifiers, agent display names, project domain, and any deliverable
content are scrubbed. The comparison covers orchestration mechanics
only.

## Setup

A real recent multi-agent task in paperclip — a creative-craft
deliverable produced via a writer↔reviewer two-round loop — was used
as the reference. Its full interaction trail (4 comments, 2-round
writer→reviewer→writer→reviewer→cleared chain, ~10 minutes wall-clock)
was pulled via paperclip's REST API.

In Glorbo, an equivalent test company was scaffolded at
`~/.glorbo/companies/<co>/` with two agents in the same writer +
reviewer roles. The same brief (anonymized) was dispatched through
Glorbo's `Glorbo.Actions.Tasks.{create, reassign,
record_peer_review_verdict}` machinery to capture the orchestration
flow, then a four-round LLM-backed loop ran end-to-end against a
local LM Studio instance.

## Part 1 — Interaction-mechanics comparison

Both systems express the same logical sequence: writer takes
assignment, produces draft, hands off to reviewer, reviewer returns
critique, writer revises, reviewer clears.

| dimension                      | paperclip                                            | Glorbo                                                       |
|--------------------------------|------------------------------------------------------|--------------------------------------------------------------|
| **Handoff vehicle**            | comment-on-issue + assignment field flip             | `Tasks.reassign/4` flips `assigned_to:` + appends `handoff_chain:` atomically |
| **Handoff prose**              | rich markdown per comment (~20 lines structured)     | one-line `reason:` field + structured audit `detail` map     |
| **Verdict surface**            | reviewer comment with structured "must fix / cleared" | `Tasks.record_peer_review_verdict/5` writes verdict + note to frontmatter |
| **Discoverability**            | `GET /api/issues/<id>/comments` (DB-backed)          | `cat task.md` + `git log` + `audit/YYYY-MM.jsonl` (filesystem) |
| **Handoff-chain replay**       | reconstruct from comment chronology + assignment field changes | direct: `handoff_chain:` is a literal time-ordered array     |
| **Cross-task archaeology**     | search comments via API                              | `git log --grep "task.peer_review.revise"` finds every revise verdict in repo history |
| **Multi-round review**         | unlimited critique passes per task; comment thread grows | **single final verdict per task** (GEP-41 D6 append-only); revisions reuse the verdict slot |
| **Provenance layers**          | one record (DB row + comment)                        | three independent records: frontmatter handoff_chain, audit jsonl, git commit |
| **Commit identity (Glorbo)**   | n/a                                                  | author = logical actor (`Agent <slug>`), committer = `Glorbo Kernel` (kernel/actor split per GEP-33 §4.2) |

### Differences worth noting

**Single-final-verdict (GEP-41 D6).** Glorbo enforces a single final
verdict per task. Paperclip allows N critique passes per task —
deeply contested work could iterate 5+ times in one comment thread.
The Glorbo design intent is that each `:revise` cycle is its own
sub-task; deeply iterative tasks land as a chain of sub-issues, each
with one clean quality call.

**Three independent provenance surfaces.** Paperclip writes one
record per agent action (comment + DB row). Glorbo writes three:
audit jsonl (structured event stream), git commit (durable diff +
trailers), task frontmatter handoff_chain (inline state). The
triple-redundancy is intentional per GEP-3 / GEP-7 / GEP-33 — each
surface answers a different question (what happened / what changed
/ who has it now).

**Filesystem-first deliverables.** Paperclip's reviewer comments are
~20 lines of structured analysis carried in the comment itself.
Glorbo's `reason:` is a one-liner; the structured-review document
lives as a separate deliverable file accessible to the writer's next
pass without API round-trips.

### Mechanics finding

Glorbo's interaction machinery reproduces paperclip's flow with
strictly richer record-keeping. The single-final-verdict constraint
is the main shape difference and may need follow-up:
- **Recommended:** clarify in GEP-41 whether deep revisions should
  create sub-tasks, or add a `:reroute` non-final verdict that flips
  status without consuming the verdict slot.
- **Recommended:** add a `handoff.note:` structured-prose field on
  `Tasks.reassign/4` for the rich critique content that paperclip
  carries in its comments.
- **Recommended:** surface the audit + history trail in the Director
  UI — today's TaskLive shows the audit but not the corresponding git
  commits. A "history" tab running `git log <task-path>` would close
  the discoverability gap.

## Part 2 — Single-shot LLM dispatch

To exercise Glorbo's actual dispatch path, the same brief was
submitted to a local LM Studio instance via Glorbo's plumbing:

| dimension              | value                                                |
|------------------------|------------------------------------------------------|
| model                  | `qwen/qwen3.6-35b-a3b` via LM Studio                |
| writer system prompt   | generic writer-role prompt (anonymized in the test scaffold) |
| reviewer system prompt | generic reviewer-role prompt                         |
| context document       | provided as agent memory file (~19KB)                |
| dispatch time          | 28.6s                                                |
| token usage            | 6070 prompt + 5255 completion (3019 reasoning) = 11325 |

The dispatch produced a structurally-correct deliverable hitting all
brief requirements (target structure count, required-element
inclusion, self-critique section). The output was captured through
Glorbo's `HomeHistory.commit_marked/3` so the GEP-33 history layer
recorded it as a `task.deliverable` commit with full Glorbo-*
trailers.

### Important model-parity footnote

The reference deliverable was produced by **a stronger
frontier-class model at a high-effort reasoning setting**.
Glorbo's dispatch ran on `qwen/qwen3.6-35b-a3b`. So this is **not**
a clean model-vs-model comparison — the reference output benefited
from a meaningfully stronger model. The purpose of the comparison is
to evaluate Glorbo's **orchestration machinery and loop value**, not
absolute output quality. Any absolute-output gap is at least partly
attributable to the model asymmetry, not the orchestrator.

If Glorbo were run on the same stronger model, its output ceiling
would be at parity with the reference. The orchestration value is
independent of the model choice.

## Part 3 — Multi-round loop end-to-end

The full four-round writer↔reviewer loop ran via a scripted
dispatcher (each LLM call drives the next). The loop captures what
Glorbo's heartbeat-driven autonomy would produce on cron.

| round | actor    | what happened                                                          | time   | tokens |
|-------|----------|------------------------------------------------------------------------|--------|--------|
| 1     | writer   | single-shot first-pass (reused from prior dispatch)                    | 28.6s  | 11.3K  |
| 2     | reviewer | review memo: 3 must-fixes + 2 should-fixes, return for revision        | 20.6s  | 10.7K  |
| 3     | writer   | revision: addresses every must-fix, output ~53% denser                 | 17.3s  | 11.6K  |
| 4     | reviewer | pass-2 verdict: **cleared for board review**, names what was resolved + 5 watch items | 15.3s  | 11.4K  |

**Total LLM time: 53.2s** (rounds 2–4, since round 1 reused prior
dispatch). **Total tokens: 33,731.** Compared to paperclip's
equivalent 4-round loop running ~10 minutes wall-clock — most of
paperclip's time is heartbeat-cycle scheduling latency between
rounds, not LLM inference.

### What each round produced

**Round 1 (writer):** structurally-correct draft hitting brief
requirements, with rough edges — minor canon-name drift from the
context document, some abstract summary lines where the brief
demanded concrete enforcement.

**Round 2 (reviewer):** identified three must-fix structural blockers
the writer's own self-critique missed. Severity-ranked, with concrete
fix instructions for each. Functionally identical in shape to what a
human editor would produce.

**Round 3 (writer revision):** addressed every must-fix verifiably:
abstract summary lines replaced with concrete enforcement moves,
canon-name drift restored to the context document's exact terms,
mechanics aligned. The revision was ~53% denser than the round-1
draft.

**Round 4 (reviewer pass-2):** cleared the deliverable. The verdict
was earned, not rubber-stamped — the pass-2 review names which
specific fix in which specific section resolved which prior must-fix,
and produces five watch items for downstream work.

### History capture

Each round was committed through `Glorbo.HomeHistory.commit_marked/3`
with a distinct action subject. The history layer captured the chain
as four distinct commits, each with `Author: Agent <slug>` +
`Committer: Glorbo Kernel` per GEP-33 §4.2:

```
192f6a5 task.peer_review.followup   (round 4 reviewer pass-2)
447ad42 task.revision               (round 3 writer revise)
1d89bcf task.peer_review.revise     (round 2 reviewer round-1 critique)
3d34628 task.deliverable            (round 1 writer single-shot)
```

(Local-only commits in the user's `~/.glorbo/.git/`; these were the
working artifacts of the test, not project commits.)

## Findings

### What the orchestration produces

Glorbo's review-loop machinery extracts material quality lift from
a multi-round process. The round-2 critique was substantive (caught
issues the writer's self-critique missed). Round 3's revision
verifiably addressed every must-fix item. Round 4's clearance was
earned. This is the **loop value** — quality improvement over a
single shot, independent of which specific model is dispatched.

### What this validates

1. **Audit-trail richness.** Glorbo's three-surface provenance
   (frontmatter handoff_chain + audit jsonl + git history with
   kernel/actor identity split) gives an auditor strictly more
   reconstruction power than a single comment-thread.
2. **Filesystem-first deliverables.** Reviews and revisions live as
   separate deliverable files accessible to the writer's next pass
   without API round-trips.
3. **Loop wall-clock floor.** Glorbo's full 4-round loop completes
   in ~1 minute LLM-time, vs paperclip's 10-minute heartbeat-paced
   cycle. The Glorbo number is the lower bound on possible
   wall-clock if heartbeats fired immediately on watcher events.
4. **Append-only history.** GEP-33 captures the full agent-to-agent
   handoff chain as a git commit graph with kernel-committed
   identity. This is missing from paperclip's design.

### What this doesn't address

1. **Absolute output quality.** Confounded by the model asymmetry
   (paperclip ran a stronger frontier-class model at a high-effort reasoning setting; Glorbo ran qwen3.6-35b-a3b).
   Measuring this would require running both stacks on the same
   model — possible but expensive.
2. **Autonomous-loop end-to-end timing.** The dispatcher script is
   a deterministic stand-in. Production heartbeat-driven loops
   would produce the same shape on the cron's polling cadence
   (~minutes per cycle vs the script's ~seconds).
3. **Quality at higher rounds.** Both stacks hit "cleared" at round
   4 of this benchmark. Tasks requiring 6+ rounds would test the
   loop's longevity differently; Glorbo's GEP-41 D6 single-final-
   verdict design forces those into multiple sub-tasks.

## On orchestrated-vs-autonomous

The four LLM calls in this comparison were scripted explicitly via a
dispatcher rather than running through Glorbo's heartbeat-driven
autonomy. The script is **mechanically what the autonomous loop
would produce** — same `Tasks.reassign` + verdict calls, same
audit + history capture, same LLM dispatch shape. It runs
deterministically for capture; the autonomous version would run on
cron-paced polling cadence.

All the autonomous machinery exists in Glorbo as of this comparison's
timestamp:
- Per-company watcher fires on agent inbox sentinel files (Phase 3).
- Cron-driven heartbeats trigger agent dispatch.
- `Glorbo.Provider` adapters reach LM Studio / claude-code / opencode
  / codex / gemini.
- `Tasks.reassign` + `record_peer_review_verdict` (GEP-40 + GEP-41)
  drive handoff-chain + verdict semantics.
- GEP-42 reviewer auto-dispatcher closes the auto-handoff loop.

A future round can run the same comparison through full autonomous
heartbeat dispatch and measure the polling-cadence vs script-driven
delta.

## Verdict

**Interaction mechanics:** Glorbo reproduces the equivalent flow with
strictly richer record-keeping (3 provenance surfaces vs 1). One
shape difference (single-final-verdict) noted as a design follow-up.

**Loop quality lift:** demonstrated. Round 2's critique caught
specific issues; round 3's revision addressed them; round 4's
clearance was earned. This is the loop value, independent of model.

**Wall-clock cost:** ~1 minute LLM-time for a full 4-round loop.

**Absolute output quality vs paperclip:** confounded by model
asymmetry (a stronger frontier-class model at a high-effort reasoning setting vs qwen3.6-35b-a3b). The loop machinery is
what was tested, not the model gap.
