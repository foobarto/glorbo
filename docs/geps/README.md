# Glorbo Enhancement Proposals (GEPs)

This directory holds **Glorbo Enhancement Proposals** — numbered design
records that capture the *what* and *why* of non-trivial changes to the
project. See [GEP-1](./0001-gep-purpose-and-guidelines.md) for the full
process, conventions, and lifecycle.

## When to write one

Write a GEP if you're introducing a new public contract, touching a
load-bearing invariant, reversing a prior decision, or answering a
"should we do X or Y?" question that isn't obvious from the code. Skip
it for bug fixes, dep bumps, and contained refactors.

## How to write one

1. Copy `0000-template.md` to `NNNN-short-kebab-title.md` with the next
   unused number (see the index below).
2. Fill in the frontmatter and the expected sections.
3. Open a PR. Iterate. When accepted, update `status: Accepted` and
   merge.

## Index

| #    | Title                                       | Type          | Status   |
|------|---------------------------------------------|---------------|----------|
| 0001 | [GEP Purpose and Guidelines](./0001-gep-purpose-and-guidelines.md)                       | Process       | Accepted    |
| 0002 | [Glorbo Architecture Overview](./0002-architecture-overview.md)                          | Informational | Accepted    |
| 0003 | [Filesystem as Source of Truth](./0003-filesystem-as-source-of-truth.md)                 | Informational | Implemented |
| 0004 | [CLI-Tool Agents over a Custom LLM Client](./0004-cli-tool-agents.md)                    | Informational | Implemented |
| 0005 | [Sandboxing — bwrap / Podman](./0005-sandboxing-bwrap-then-podman.md)                    | Informational | Implemented |
| 0006 | [Phoenix LiveView + Channels for the Dashboard](./0006-phoenix-liveview-dashboard.md)    | Informational | Implemented |
| 0007 | [SQLite as Derived Data](./0007-sqlite-as-derived-data.md)                               | Informational | Implemented |
| 0008 | [Provider Registry + CLI Auto-Detect](./0008-provider-registry-and-auto-detect.md)       | Standards     | Implemented |
| 0009 | [Protocol-Level Integration — MCP, ACP](./0009-protocol-integration-mcp-acp.md)          | Informational | Accepted    |
| 0010 | [Agent and Role-Specific Skill Templates](./0010-agent-and-skill-templates.md)           | Standards     | Implemented |
| 0011 | [The Zen of Glorbo](./0011-zen-of-glorbo.md)                                             | Informational | Accepted    |
| 0012 | [No User-Input Atoms — Registry Over Process Names](./0012-no-user-input-atoms.md)       | Standards     | Implemented |
| 0013 | [Project-prefixed Task IDs](./0013-project-prefixed-task-ids.md)                         | Standards     | Implemented |
| 0014 | [Agent Heartbeat Semantics and HEARTBEAT.md](./0014-agent-heartbeat-semantics.md)        | Standards     | Implemented |
| 0015 | [ALLCAPS Convention for Agent-facing Markdown](./0015-allcaps-agent-md-convention.md)    | Informational | Implemented |
| 0016 | [Agent Wake + Dispatch Pipeline](./0016-agent-wake-dispatch-pipeline.md)                 | Informational | Implemented |
| 0017 | [Cross-OS Sandbox and Filesystem Watcher Landscape](./0017-cross-os-sandbox-and-watcher.md) | Informational | Draft       |
| 0018 | [agentcompanies/v1 interop — adopt paperclip.ai schema?](./0018-agentcompanies-v1-interop.md) | Informational | Placeholder |
| 0019 | [Director Approval Workflow Protocol](./0019-director-approval-workflow.md)              | Informational | Implemented |
| 0020 | [Director Dashboard UX Sweep — Rounds 2+3](./0020-round-2-3-ux-sweep.md)                  | Informational | Implemented |
| 0021 | [File-based Agent Memory](./0021-file-based-agent-memory.md)                             | Standards     | Implemented |
| 0022 | [skills.sh Registry — Browse and Install Skills](./0022-skills-registry-browse-install.md) | Standards     | Draft       |
| 0023 | [Egress Proxy with Host Filtering and Smart Mode](./0023-egress-proxy-with-filtering.md) | Standards     | Draft       |
| 0024 | [Task Scheduler — Firing Scheduled Dispatches](./0024-task-scheduler.md)                 | Informational | Implemented |
| 0025 | [On-disk File Format Specs, `glorbo validate`, `glorbo fmt`](./0025-file-format-spec-and-tooling.md) | Standards     | Draft       |
| 0026 | [Benchmark Templates and Provider A/B Comparison](./0026-benchmark-templates-and-ab-comparison.md) | Standards     | Draft       |
| 0027 | [Agent Sandbox Path Requests via Director Approval](./0027-agent-sandbox-path-requests.md) | Standards     | Implemented |
| 0028 | [Agent-Created Proposals via Director Approval](./0028-agent-created-proposals.md)        | Standards     | Implemented |
| 0029 | [Glorbo as MCP Server (Localhost HTTP-SSE, R/W)](./0029-mcp-server-for-glorbo.md)         | Standards     | Implemented |
| 0030 | [Director Dashboard TUI Redesign (V1)](./0030-tui-redesign.md)                             | Standards     | Implemented |
| 0031 | [Network-namespace isolation for `:proxy` agents](./0031-netns-isolation-for-proxy-agents.md) | Standards  | Implemented |
| 0032 | [Native Agent Harness — OpenAI v1-Compatible Provider](./0032-native-agent-harness.md)     | Standards     | Implemented |
| 0033 | [Git History Layer for Glorbo Home](./0033-git-history-layer-for-glorbo-home.md)           | Standards     | Draft       |

<!-- Add new entries in numerical order. Keep the table tidy. -->

## Status legend

- **Placeholder** — triage-approved idea with a reserved number and
  a problem statement + open questions. Not yet a worked design.
  Low review bar to merge; the point is rapid capture. See GEP-1
  §"Placeholders."
- **Draft** — author is iterating. Design space being actively
  worked out. Content may change.
- **Accepted** — approved for implementation (or, for Informational
  GEPs, approved as the canonical record). Content is append-only.
- **Implemented** — a Standards GEP that has shipped. Optional
  `implemented-in: vX.Y.Z` in frontmatter points at the release.
- **Superseded** — replaced by a later GEP. Frontmatter points forward
  via `superseded-by`.
- **Withdrawn** — author pulled it before acceptance.
- **Rejected** — maintainers declined it. Kept for historical context.

## Types

- **Standards** — proposes a change to code, on-disk layout, CLI, API,
  or user-visible behaviour.
- **Informational** — documents a decision record, convention, or
  historical context. No implementation work implied.
- **Process** — changes how contributors work (e.g., this process doc).

## Frontmatter fields

Required:

```yaml
gep: N
title: Short, descriptive title
author: Name <email@example.com>
status: Placeholder | Draft | Accepted | Implemented | Superseded | Withdrawn | Rejected
type: Standards | Informational | Process
created: YYYY-MM-DD
```

Optional, added as relevant (see GEP-1 for full semantics):

```yaml
updated: YYYY-MM-DD
requires: [N, M]          # must-read-first dependencies
supersedes: [N]           # this GEP replaces these
superseded-by: N          # this GEP has been replaced
extended-by: [N, M]       # later GEPs build on this one
see-also: [N, M]          # loosely related
implemented-in: vX.Y.Z
discussion-at: <URL>
```

All GEP-reference fields are YAML lists even when holding a single
value (`extended-by: [8]`), for tooling consistency.

## Bidirectional links

When a new GEP extends or supersedes an older one, **the same PR must
update the older GEP's frontmatter** so navigation works in both
directions. See GEP-1 §"Updating GEPs" for the full rule.

## Conventions

- **Filename:** `NNNN-short-kebab-title.md`. Titles under ~60 chars.
- **Numbers:** sequential, four-digit, claimed at merge time. Rebase on
  conflict.
- **Decision log:** every Standards GEP must have one. Informational
  GEPs should have one when they capture rationale (most do).
- **Append-only after Acceptance:** substantive edits go in a new GEP
  that supersedes the old.
