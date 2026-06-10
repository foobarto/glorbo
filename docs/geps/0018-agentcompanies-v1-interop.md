---
gep: 18
title: agentcompanies/v1 interop — adopt paperclip.ai's vendor-neutral schema?
author: Glorbo Maintainers <security@example.invalid>
status: Placeholder
type: Informational
created: 2026-04-18
see-also: [3, 4, 10, 13, 14, 15]
extended-by: [54]
history:
  - date: 2026-04-18
    status: Placeholder
    note: >-
      Captured after researching paperclip.ai (task #132). Their
      agentcompanies/v1 spec is MIT-licensed and explicitly vendor-
      neutral. This GEP is a placeholder to think about whether
      Glorbo's on-disk layout should converge onto that schema, or
      stay divergent and document the differences.
  - date: 2026-06-02
    status: Placeholder
    note: >-
      GEP-54 extends this placeholder on the read side: it teaches
      `glorbo import paperclip` the live paperclip-instance on-disk
      layout (deep, UUID-named agent dirs, contract files under
      `instructions/`). No write-side schema convergence — the open
      questions here remain open.
---

# GEP-18: agentcompanies/v1 interop — adopt paperclip.ai's schema?

## Problem

[Paperclip.ai](https://paperclip.ai) publishes `agentcompanies/v1`
(MIT-licensed, https://agentcompanies.io/specification), a
vendor-neutral markdown schema for representing agent-run companies
on disk:

```
COMPANY.md              — org-level metadata
TEAM.md                 — per-team metadata (organisational unit)
AGENTS.md               — agent roster under the team (single file,
                          not per-agent directory)
PROJECT.md              — per-project metadata
TASK.md                 — per-task metadata
```

Glorbo has its own evolved layout (GEP-3, GEP-13, GEP-14, GEP-15):

```
companies/<co>/company.md
               channels/<name>.md
               projects/<proj>/project.md + tasks/<proj>-NN.md
               agents/<slug>/AGENT.md + HEARTBEAT.md + SOUL.md
               goals/<id>.md
               audit/<YYYY-MM>.jsonl
```

Two file trees for the same conceptual structure (company → teams →
agents/projects → tasks). Every load-bearing concept exists in both,
but the filenames, nesting, and frontmatter shapes are different.

## Question

Is there an interop opportunity, and is it worth pursuing?

## What convergence would buy us

1. **Import/export.** A Director with an existing paperclip.ai
   company could point Glorbo at the tree and have it work; a Glorbo
   company could be opened in any other `agentcompanies/v1` runtime.
2. **Cross-runtime agent portability.** Agents defined in one
   runtime run in another without re-specification.
3. **Smaller documentation surface.** The canonical "what's in an
   agent definition" doc is the spec, not Glorbo-specific invention.
4. **Signalling.** Glorbo joining the spec is a cheap credibility
   move for the agent-orchestration ecosystem.

## What convergence would cost

1. **Two-way migration.** Every existing Glorbo install has on-disk
   state in the current layout. A flag day conversion isn't
   realistic; a reader that accepts both shapes is a permanent
   maintenance burden.
2. **Semantic drift.** The spec is vendor-neutral; Glorbo's
   peculiarities (one-way inbox/outbox, bwrap permission mounts,
   SQLite derivation) don't fit cleanly into frontmatter fields.
   They'd end up in a `.glorbo.yaml` vendor extension that the spec
   allows — but then we have a two-file model (spec + extension)
   rather than our current one-file-per-concern model.
3. **AGENTS.md vs per-agent dirs.** The spec puts all agents in a
   single team-level `AGENTS.md` array. Glorbo's per-agent dir tree
   (with inbox/outbox/workspace/state siblings) is load-bearing for
   the bwrap sandbox boundary — every bind mount is keyed to one
   agent's tree. This isn't a "frontmatter field" difference; it's
   an OS-level invariant.
4. **Teams.** Glorbo has no teams layer. The spec treats teams as
   first-class. Mapping requires either inventing a team concept
   (scope creep) or flattening to "one team per company" (loses
   spec fidelity).

## Open questions

To be resolved if and only if someone actually wants cross-runtime
interop:

1. **Is the per-agent-dir sandbox architecture compatible with
   AGENTS.md as a single file?** Probably: the spec describes the
   *schema* of an agent definition, not its on-disk filename. A
   reader could synthesise Glorbo's per-dir state from a single
   AGENTS.md + each agent's runtime dirs. Exploring this is the
   first real unknown.
2. **Does anyone actually want this?** Paperclip.ai is one
   implementation; the spec is new (2025). Until a second non-
   trivial runtime adopts it, interop has limited practical value.
3. **What's the minimum subset we'd converge on?** Even partial
   compliance (same COMPANY.md shape, same PROJECT.md shape) would
   be useful without requiring the full AGENTS.md restructure.
4. **Is `.glorbo.yaml` a good home for the sandbox/router fields,
   or do they stay in AGENT.md frontmatter?** Spec allows vendor
   extensions but doesn't mandate the split.

## Non-decision

This GEP doesn't decide anything. It stays at Placeholder until a
concrete interop need surfaces (example: a Director wants to import
a paperclip.ai company; or a second runtime adopts the spec and
interop becomes a plural question).

If/when that happens, the work becomes:

1. Pilot compatibility layer: a `Glorbo.Compat.AgentCompaniesV1`
   module that reads `AGENTS.md` into Glorbo's existing
   `Agent.Spec` shape without touching the on-disk files. No
   write-side convergence yet.
2. Write-side: `glorbo new company --schema agentcompanies-v1` that
   produces a spec-compliant tree alongside the current Glorbo-
   native layout.
3. Flag-day decision: do we make the spec-compliant shape the
   default, or keep the native shape and offer spec as a
   compatibility mode?

## Related

- **GEP-3** — filesystem as source of truth. The invariant this GEP
  would either extend (to include the spec's file list) or leave
  unchanged (if we deferred).
- **GEP-10** — agent/skill templates. If we adopt the spec,
  templates need to generate spec-compliant output.
- **GEP-13** — project-prefixed task IDs. Spec's TASK.md uses a
  different id format; convergence would change the task-naming
  convention.
- **GEP-14** — heartbeat semantics. Paperclip's env-var injection
  model (`PAPERCLIP_AGENT_ID`, `WAKE_REASON`) parallels our wake
  triggers; would need mapping.
- **GEP-15** — ALLCAPS convention. Spec uses ALLCAPS too —
  compatible by coincidence.

## Prior art

- agentcompanies/v1 spec: https://agentcompanies.io/specification
- Paperclip.ai source: https://github.com/paperclipai/paperclip
  (MIT license, 2025).
- Task #132 research report (not in repo — see task description).
