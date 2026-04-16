---
date: "2026-04-16"
promoted: false
---

# Plan-only GSD workflow — decouple planning from implementation

## Intent

Keep using GSD for the parts it does well — structured planning, research,
verification, audits — but step outside the `/gsd-execute-phase` harness for
actual implementation. This opens the door to trying other agent/AI setups
(Codex, Gemini CLI, opencode, hermes, direct manual coding) on a per-phase
basis, without abandoning GSD's milestone rigor.

## What stays in GSD

- `/gsd-new-milestone`, `/gsd-new-project` — milestone scaffolding
- `/gsd-discuss-phase` — requirements elicitation before planning
- `/gsd-research-phase` — upstream research into RESEARCH.md
- `/gsd-plan-phase` — produces PLAN.md + goal-backward plan check
- `/gsd-ui-phase` — design contract where relevant
- `/gsd-verify-work` — UAT validation against implemented code
- `/gsd-code-review`, `/gsd-secure-phase`, `/gsd-validate-phase` — retroactive audits
- `/gsd-audit-milestone` — milestone gate before archiving
- `/gsd-cleanup`, `/gsd-complete-milestone` — housekeeping

These commands read the codebase and planning artifacts; none require that
the code was produced by `/gsd-execute-phase`.

## What to avoid (to not break GSD's assumptions)

- `/gsd-execute-phase` — writes its own commit trailers, state manifests,
  and wave ordering. Don't mix partial executor runs with hand-implemented
  work on the same phase.
- `/gsd-undo` — relies on the executor's phase manifest to know what to
  revert. Without it, fall back to plain `git revert`.
- `/gsd-progress` phase-completion signals — the "executed" marker won't
  exist; mark phase status manually in ROADMAP.md instead.

## Suggested per-phase loop

1. `/gsd-discuss-phase` → capture intent, open questions, constraints.
2. `/gsd-research-phase` (or inline in plan) → RESEARCH.md.
3. `/gsd-plan-phase` → PLAN.md with tasks, dependencies, verification hooks.
4. **Implement outside GSD** using whatever agent/tool fits: manual, Codex,
   Gemini, opencode, a plain Claude Code session without the executor, etc.
   Commit atomically on your own cadence; PLAN.md is the contract, not the
   executor.
5. `/gsd-verify-work` → conversational UAT against PLAN.md success criteria.
6. `/gsd-code-review` + `/gsd-secure-phase` → retro audits.
7. Manually mark phase complete in ROADMAP.md (or via a small helper if
   one emerges).
8. At milestone end: `/gsd-audit-milestone` → gate before archiving.

## Why this is appealing

- **Tool portability:** try Codex / Gemini / opencode / hermes on specific
  phases without committing the whole repo to that tooling.
- **Human-in-the-loop control:** some phases (refactors, risky migrations,
  security-sensitive code) benefit from tight manual implementation even
  if planning is AI-assisted.
- **Reduced lock-in:** GSD becomes a planning framework you can layer onto
  any implementation workflow, not a full harness you must stay inside.

## Open questions

- Does ROADMAP.md phase-status need a new convention (e.g. `implemented-external`)
  to distinguish hand-implemented phases from executor-driven ones?
- Can `/gsd-verify-work` + `/gsd-audit-milestone` catch everything the executor
  normally enforces (atomic commits, wave ordering, manifest)? Probably not —
  what's the minimum safety net for plan-only phases?
- Worth a one-phase pilot to measure whether the audit commands give enough
  signal without executor metadata.
- If this works, could `/gsd-plan-phase` gain a `--plan-only` flag that
  tweaks downstream verification expectations?

## Next step

Pilot on one upcoming v0.0.3 phase. Keep a short retro note here comparing
the plan-only loop against a prior executor-driven phase (velocity, defect
rate, friction points).
