---
gep: 0038
title: "Frontend adapter contracts — one internal service layer, N frontends"
author: Glorbo Maintainers <security@example.invalid>
status: Placeholder
type: Standards
created: 2026-04-24
history:
  - date: 2026-04-24
    status: Placeholder
    note: |
      Parked during the GEP-37 (glorbo tui) session. User
      observation: "we may need another standards GEP that would
      put a rule on every feature/functionality in glorbo to have
      well defined internal interface so that new systems such
      like TUI, MCP, webUI, <whatever next protocol> can be hooked
      into them easily." This GEP reserves the number and captures
      the principle; the concrete sub-proposals are GEP-35 (read
      seam) and GEP-36 (write seam). GEP-37's deliverable includes
      most of GEP-36's extraction as a side effect.
see-also: [6, 29, 35, 36, 37]
---

# GEP-38: Frontend adapter contracts — one internal service layer, N frontends

## Problem

Glorbo now has three Director-facing surfaces and a clear
trajectory toward a fourth:

| Surface | Status | Entry point |
|---|---|---|
| `glorbo_web` LiveView | shipped, primary | `GlorboWeb.*Live` modules |
| `glorbo_web` MCP server | shipped (GEP-29) | `GlorboWeb.MCP.*` |
| `glorbo tui` terminal client | proposed (GEP-37) | `Glorbo.Tui.*` |
| Hypothetical: agent-facing native API, remote CLI, … | future | TBD |

Each surface needs to read and mutate the same orchestrator
state. Today there is no single internal contract that all
frontends consume. The picture is:

- **MCP** is fully compliant — every write routes through
  `GlorboWeb.Actions` (GEP-29 D3 enforces this).
- **LiveView** is partially compliant — `post_message`,
  `post_task_comment`, `set_approval`, `wake_agent` go through
  `GlorboWeb.Actions`; task creation, move, trash, dispatch, and
  several project/agent mutations bypass via raw `File.*!`
  (documented in GEP-36's Placeholder).
- **Reads** — there is no shared read layer; both LV and MCP
  call directly into `Glorbo.*` modules, SQLite, and the
  filesystem. `Glorbo.Company.Router` carries 8+ responsibilities
  with no central `AgentWritableFile` seam (GEP-35's Placeholder).

As soon as a third surface (the TUI) enters, the cost of "each
frontend reinvents the plumbing" compounds. GEP-37 carves out the
subset of mutations the TUI needs, creating `Glorbo.Actions` in
core — but that's a point solution to a pattern problem.

GEP-38 exists to name the principle and hold future frontends to
it, rather than re-arguing the seam every time a new one is added.

## The principle (sketch)

Every Director-facing capability must be exposed through a single
internal service module pair:

- **`Glorbo.Actions.*`** — all state mutations (write seam; the
  focus of GEP-36 and GEP-37's extraction).
- **`Glorbo.Queries.*`** — all state reads (read seam; the focus
  of GEP-35's `AgentWritableFile` seam, generalised).

Frontends — `GlorboWeb.*Live`, `GlorboWeb.MCP.*`, `Glorbo.Tui.*`,
and anything that comes next — are thin adapters. They are
allowed to:

- call `Glorbo.Actions.*` for mutations;
- call `Glorbo.Queries.*` for reads;
- subscribe to `Phoenix.PubSub` topics for reactive updates;
- hold their own surface-specific UI state (view cursor,
  pagination, composer buffer) in-process.

Frontends are **not** allowed to:

- call `File.write!`, `File.rename`, `File.mkdir_p!`, `File.rm!`
  for domain state;
- read domain state from the filesystem or SQLite directly (they
  go through `Glorbo.Queries.*`);
- emit audit entries directly (Actions owns that);
- enforce permissions locally (Actions owns that — one
  enforcement point, per GEP-2 D4).

Enforcement is a Credo custom check that runs in `mix precommit`.

## Open questions

- **Scope of `Glorbo.Queries`.** What's the right partitioning?
  `Queries.Tasks`, `Queries.Agents`, `Queries.Channels`,
  `Queries.Audit`, `Queries.Health` — likely one module per
  orchestrator concern, but the exact boundaries depend on the
  GEP-35 extraction work.
- **Pagination + streaming contract.** LiveView wants PubSub +
  snapshots. MCP wants SSE tails + snapshots. TUI wants PubSub +
  snapshots. Is `Glorbo.Queries` snapshot-only with PubSub kept
  separately (yes, probably — PubSub is already the canonical
  fan-out) or do queries return `{:stream, ...}` shapes?
- **Permission scoping.** `Glorbo.Actions` takes an `actor`
  parameter today (`director`, `mcp:<client>`, `agent:<slug>`).
  Should `Queries` too, for audit-of-reads? Probably no — reads
  don't mutate audit — but the question deserves capturing.
- **Credo check shape.** Likely a custom check that bans
  `File.write!`, `File.rename`, `File.mkdir_p!`, `File.rm!`,
  `File.rm_rf!` in `lib/glorbo_web/live/*.ex` and
  `lib/glorbo/tui/**/*.ex`, with an explicit allow-list file for
  the handful of genuinely UI-local state writes (e.g.
  `_inbox_archive.json` per GEP-20 D2). Exact mechanism TBD.
- **Relationship to `Phoenix.PubSub` topics.** The topics today
  are shared infrastructure — LV, MCP, and TUI all subscribe to
  `company:<co>:*`. Is the topic schema part of the frontend
  contract (stable, documented, versioned)? It probably should
  be. Unclear how strictly.
- **Testing the contract.** Property-based or exhaustive-match
  tests that assert every `Glorbo.Actions.*` mutation emits an
  audit entry, and every `Glorbo.Queries.*` read is side-effect
  free. Shape TBD.
- **Does GEP-38 need to happen before or after GEP-35/36 land?**
  Current thinking: GEP-35 and GEP-36 are the concrete sibling
  GEPs; GEP-38 graduates from Placeholder to Draft after those
  two have made enough progress that the principle can be
  extracted from the lived experience rather than speculated
  into existence. Draft-promotion marker: GEP-36's Credo gate is
  in place and `Glorbo.Queries` has at least four modules.

## Relationship to neighbouring GEPs

- **GEP-6 D6** — "dashboard reads state from filesystem + SQLite
  via Ecto; mutations go through the same Elixir action
  functions agents use." GEP-38 generalises D6 from "dashboard"
  to "every frontend."
- **GEP-29 D3** — "all MCP mutations via the shared Elixir
  action layer." GEP-38 generalises D3 from MCP to all frontends.
- **GEP-35** — proposes `Glorbo.AgentWritableFile` as a read
  seam; this is a concrete piece of `Glorbo.Queries`.
- **GEP-36** — proposes consolidating `GlorboWeb.Actions` and
  sweeping raw writes in LV; this is the write-seam piece of
  GEP-38's principle. GEP-37's extraction completes most of it.
- **GEP-37** — first non-Phoenix frontend. Its shipping creates
  the existence proof that makes GEP-38 worth writing: a third
  surface is now real, not speculated.

## Not yet decided

This is a Placeholder. Concrete design — module boundaries, Credo
check exact syntax, PubSub topic schema versioning, migration
plan for non-compliant LV handlers that GEP-37 did not touch —
is deferred to the Draft that supersedes this Placeholder.

## Related

- **GEP-6** — the LiveView dashboard; sets precedent for D6's
  one-write-path rule.
- **GEP-29** — the MCP server; sets precedent for D3's
  all-frontends-go-through-Actions rule.
- **GEP-35** — `Router` split and agent-writable-file read seam
  (Placeholder). The concrete read-seam proposal.
- **GEP-36** — Actions layer as single Director-write channel
  (Placeholder). The concrete write-seam proposal.
- **GEP-37** — `glorbo tui` interactive terminal client (Draft).
  First non-Phoenix frontend; side-effect of its extraction work
  is most of GEP-36's intended cleanup.
