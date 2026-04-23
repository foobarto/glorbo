# Agent Templates

Reusable instruction-bundle templates for agent-shaped companies. A
**CEO-bootstrapped company** spins up, self-governs, and self-improves
via the patterns encoded here.

## Files

| File              | Purpose                                                                 |
|-------------------|-------------------------------------------------------------------------|
| `ceo.md`          | CEO agent operating bundle — bootstrap, delegation, oversight, hiring   |
| `new-hire.md`     | Meta-template the CEO fills in to compose an instruction bundle for any newly approved agent (AGENTS.md + HEARTBEAT.md + TOOLS.md skeletons) |

## Origin and intent

These templates are distilled from the post-mortem on `Example Publishing Co`
(`docs/testing/example-co-benchmark.md`), a real Paperclip company that
shipped a 3-volume book trilogy but revealed systemic weaknesses
across self-governance, research-convergence, and cross-branch
visibility.

The templates bake in the patterns that **worked** in EXA and add
explicit structure for the patterns that **didn't**:

| EXA pattern                                    | Template codifies                              |
|------------------------------------------------|------------------------------------------------|
| Writer ⇄ CritiqueOps QA loop with severity tags| *Forcing function* requirement on every role   |
| Rule codification → decision log + AGENTS.md   | Self-governance playbook in CEO.md             |
| Monitoring-comment spam (7 identical comments) | Self-redundancy check in HEARTBEAT.md          |
| AudioOps POC non-convergence (5 POCs, 0 ships) | Explicit forcing function, no elastic N        |
| UXDesigner stalled with nobody noticing        | Cross-branch health audit in CEO.md            |
| Trilogy pivot redo cascade                     | Pivot impact assessment before routing         |
| Credential blockers parked indefinitely        | Fallback-required rule in TOOLS.md             |
| Every follow-up = new ticket (director noise)  | Reuse > spawn principle in both templates      |

## Usage

1. **Instantiate `ceo.md`** for a new company: replace placeholders,
   commit to the CEO's managed instruction bundle path.
2. **CEO's day-0 bootstrap** (per `ceo.md` § Day-0 bootstrap
   playbook) sets up governance files, proposes the first hire, and
   delegates seed work.
3. **On each approved hire**, CEO composes the new agent's bundle
   via `new-hire.md`, running the composition checklist at the
   bottom before posting `## Onboarded`.

Templates are framework-agnostic markdown. They do not yet wire into
Glorbo code — promote to a GEP when/if they become load-bearing
defaults.

## Status

Draft. Not yet used to seed a live company. Validate against the
example-co benchmark UAT procedure before promoting to authoritative.
