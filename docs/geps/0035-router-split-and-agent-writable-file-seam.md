---
gep: 0035
title: Router split — per-kind outbox handlers behind a shared AgentWritableFile seam
author: Glorbo Maintainers <security@example.invalid>
status: Placeholder
type: Standards
created: 2026-04-24
history:
  - date: 2026-04-24
    status: Placeholder
    note: |
      Both codex and opencode round-2 flagged `Glorbo.Company.Router`
      as the project's largest module (~1,850 lines, 8+
      responsibilities) and as a source of safety-check drift —
      some outbox readers got the lstat guard, some did not, until
      the round-3 sweep wired them all up. The dual-review finding
      was: centralise the host-side agent-writable-file policy and
      split the Router's per-kind outbox handling into siblings.
see-also: [30]
---

# GEP-35: Router split + AgentWritableFile seam

## Problem

`Glorbo.Company.Router` owns 8+ distinct outbox sub-routers today:

| Handler                         | Lines (approx) |
|---------------------------------|---------------:|
| `handle_outbox_message`         | 80             |
| `handle_outbox_task`            | 120            |
| `handle_outbox_comment`         | 60             |
| `handle_outbox_memory`          | 150            |
| `handle_outbox_path_request`    | 90             |
| `handle_outbox_proposal`        | 250            |
| `route_mentions`                | 100            |
| Classification + shared helpers | 200            |

Each opens a file the agent authored. Each then writes to a
Director-owned destination. The round-1 sweep had to add
`read_agent_writable_file/1` guards to six read sites. The round-3
sweep added lstat to the task-file destination. This pattern will
repeat every time a new outbox kind is added, and the Router becomes
more unreadable with each iteration.

Separately, the Actions-layer write paths (`wake_agent`,
`Approvals.Gate.write_sentinel`) also have agent-writable-destination
concerns (round-3 fix). Two unrelated modules with the same class of
bug is evidence we need one seam.

## Proposal sketch

1. **`Glorbo.AgentWritableFile` module.** Central module exposing:
   - `read/1` — lstat + read-regular, refuse symlinks.
   - `write_replacing/2` — lstat the destination, refuse symlinks,
     then atomic tmp + rename.
   - `append/2` — lstat, refuse symlinks, append-only.
   Every Elixir-side access to an agent-writable path goes through
   here. Credo rule / compile-time check forbids raw `File.read`
   / `File.write` on known-agent-writable trees.

2. **Split `Glorbo.Company.Router`** into:
   - `Glorbo.Company.Router` — dispatcher only; ~200 lines.
     Receives `:file_event`, classifies, delegates.
   - `Glorbo.Company.Outbox.TaskRouter` — task-filing
   - `Glorbo.Company.Outbox.CommentRouter` — comment routing
   - `Glorbo.Company.Outbox.MessageRouter` — classic message routes
   - `Glorbo.Company.Outbox.MemoryRouter` — memory write/delete
   - `Glorbo.Company.Outbox.PathRequestRouter`
   - `Glorbo.Company.Outbox.ProposalRouter`
   - Mentions + channel-rotation moved to a shared layer.

3. Target: Router < 500 lines. Each sub-router < 400.

## Open questions

- **Process model.** Single GenServer that delegates to pure
  modules, vs. per-kind GenServer under the CompanySupervisor?
  Single is cleaner but moves ALL outbox work through one mailbox
  — a slow memory write blocks a fast message route.
- **Shared state.** `director_pending`, `permissions` lookup —
  where does that live after the split? Likely in the Router
  dispatcher with sub-routers taking opaque opts.
- **Testability.** Current Router tests exercise the pipeline
  end-to-end via `{:file_event, ...}` messages. Post-split, can
  the sub-routers be unit-tested as pure functions, and does
  the integration surface shrink?
- **Audit ordering.** Several handlers emit `*.rejected` audits
  alongside `*.accepted`. Those need to remain in-order with
  respect to filesystem writes.

## Related

- GEP-30 — TUI redesign (introduced the comment thread file)
- Round 1 sweep `read_agent_writable_file/1` — proof that we
  already have the helper shape locally in Router
- Round 3 sweep `ensure_regular_file_for_write/1` + sentinel lstat
  — the Actions-layer equivalent that should fold into the same
  seam
