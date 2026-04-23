---
gep: 0036
title: Actions layer as the single Director-write channel
author: Glorbo Maintainers <security@example.invalid>
status: Placeholder
type: Standards
created: 2026-04-24
history:
  - date: 2026-04-24
    status: Placeholder
    note: |
      Opencode round-2 flagged `KanbanLive`, `AgentLive`, and
      `TaskLive` bypassing the `GlorboWeb.Actions` layer (GEP-6 D6
      explicitly forbids this — "Actions is the enforcement point
      for permissions + audit and must not be bypassed"). They
      mutate filesystem state via `File.mkdir_p!`, `File.write!`,
      `File.rename` directly. That means two surfaces — LV + MCP —
      can produce divergent on-disk shapes, audit gaps, and
      permission bypasses.
see-also: [6, 29]
---

# GEP-36: Actions layer as the single Director-write channel

## Problem

GEP-6 D6 says `GlorboWeb.Actions` is the single enforcement point
for permissions + audit + filesystem writes originating from the
Director surface. MCP tools (GEP-29) honour this rigorously —
every write goes through the same Actions API LiveView uses. But
several LiveView handlers do not:

- **`KanbanLive`** — task creation, drag-to-column moves, new-task
  wizard. Writes `projects/<p>/tasks/<id>.md` via raw
  `File.mkdir_p!` + `File.write!` + `File.rename`.
  ([kanban_live.ex:1140-1280](../../lib/glorbo_web/live/kanban_live.ex#L1140-L1280))
- **`AgentLive`** — wake requests (already via Actions), but some
  file-tree mutations bypass.
- **`TaskLive`** — task trash (move to `.history/tasks/`) via raw
  `File.rename`.
  ([task_live.ex:270-285](../../lib/glorbo_web/live/task_live.ex#L270-L285))

Consequences:

1. **Audit gaps.** The LV path may forget to emit the
   corresponding `*.trashed` / `*.moved` audit event that the
   Actions path would have.
2. **Permission drift.** Actions enforces slug + size + role
   checks at the boundary; raw LV writes do not.
3. **Divergent on-disk shape.** MCP and LV produce different
   artefacts. A task created by MCP carries `Actions`'s stamp (Context
   footer, frontmatter normalisation); a LV-created task does not.
4. **Future invariants impossible to enforce.** Any new audit-
   trail rule or permission system has to be re-applied to every
   LV that writes.

## Proposal sketch

1. **Enumerate every `File.*!` write in `lib/glorbo_web/live/`** and
   classify: belongs in Actions (most), belongs in MCP Resources
   (queries), or genuinely local-only (LV-scoped UI state).
2. **Extract per-operation modules** — `Glorbo.Tasks.Creator`,
   `Glorbo.Tasks.Mover`, `Glorbo.Tasks.Trasher` — each a pure-ish
   function with the permission check + audit emit + atomic
   write.
3. **Rewrite the LV handlers** to call the per-operation modules
   (through `GlorboWeb.Actions` as the web-facing surface, so
   input validation stays in one place).
4. **MCP tools already go through `Actions`** — converge them on
   the per-operation modules too for DRY.
5. **Compile-time gate.** Credo check: a LiveView module must not
   call `File.write!`, `File.rename`, `File.mkdir_p!` directly.
   Exception list for the cases that genuinely need it
   (LV-scoped UI state).

## Open questions

- **Do we need a new process?** No — Actions is a function-level
  module today, which is fine. The per-operation modules can be
  the same.
- **How to handle LV-speculative UI state?** E.g. drag-to-column
  optimistic updates. Can those still go through Actions, or do
  they need a pre-commit stage?
- **How to audit the refactor itself?** This is a cross-cutting
  change across ~5 LVs. Budget: 2 commits per LV (extract +
  reroute) to keep diffs reviewable.

## Related

- GEP-6 — Phoenix LiveView + Channels for the Dashboard (original
  "Actions is the single enforcement point" rule)
- GEP-29 — MCP server (the other write surface that already
  honours the rule)
