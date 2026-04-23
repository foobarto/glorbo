---
gep: 0028
title: Agent-Created Proposals via Director Approval
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-21
history:
  - date: 2026-04-21
    status: Draft
    note: Initial draft.
  - date: 2026-04-22
    status: Draft
    note: |
      Wave 2b — outbox-indirection pivot. Agents no longer write
      `proposals/` directly; all agent-sourced writes go through
      the Router via `agents/<sender>/outbox/proposals/<id>.md`.
      `proposals:write:*` replaced by `proposals:propose:*` and
      `proposals:decide:*`. Adds D7.
  - date: 2026-04-23
    status: Draft
    note: |
      Protocol is on `main`; holding in Draft until UI + auto-approve
      land. Shipped: `Glorbo.FileSpec.ProposalMd` (`proposal/v1`),
      `Glorbo.Company.ProposalsSink` audit emitter, Router classifier
      with per-field validation (`require_proposal_kind`,
      `require_proposal_id_match`, `require_proposal_subtype`,
      `check_proposal_create_status`, `reject_self_approval`),
      `proposals:{propose,decide}:*` permission namespace mounted
      by `Glorbo.Sandbox.PermissionMapper`, `Watcher` classification
      broadcasting on `company:<co>:proposals` PubSub topic, MCP tools
      (`glorbo.list_proposals`, `glorbo.get_proposal`,
      `glorbo.create_proposal`), and the `headcount_budget:` field
      plumbed through `company.md` + MCP. Still open: dedicated
      ProposalsLive view (today proposals only surface via MCP tools +
      inbox PubSub), and auto-approve-hire-within-headcount-budget
      policy per GEP-28 §Goals bullet 4.
  - date: 2026-04-23
    status: Implemented
    note: |
      Final pieces landed: `GlorboWeb.ProposalsLive` at
      `/companies/:co/proposals` groups proposals by status with
      inline Approve / Deny actions (deny opens a reason-capture
      modal); `Glorbo.Company.Proposals.{list,fetch,flip}/4` is the
      read + flip API the LV and future clients share; and the
      Router now auto-approves `subtype: hire` when current agent
      count `<` `company.md` `headcount_budget:`, stamping
      `approved_by: system/auto-approve-hire` and emitting a
      `proposal.auto_approved` audit. Absent / zero budget or
      over-budget headcount falls through to Director approval.
      Sidebar gets a dedicated `Proposals` nav item.
requires: [3, 5, 10, 19, 25]
see-also: [27]
---

# GEP-28: Agent-Created Proposals via Director Approval

## Problem

Glorbo has a rich task-approval workflow (GEP-19) for `requires_approval: director` on
individual tasks, but no filesystem-based mechanism for agents to propose *structural*
changes that require Director approval. Concretely:

- **Hiring.** The CEO template says "propose hiring in #general," which is
  unstructured and invisible to the Router and Inbox. A Director who misses the
  channel post never sees the proposal.
- **Budget increases.** An agent that hits its budget cap has no way to request
  more without human DMing.
- **New projects / workspaces.** No agent can autonomously propose a new project
  and have it go through an approval queue.

The Paperclip comparison test demonstrated that autonomous hiring proposals are a
core multi-agent workflow pattern. Glorbo needs a first-class filesystem contract
for it.

## Goals

- Introduce `proposal/v1` — a new markdown+YAML file kind for agent-created
  structural proposals.
- Provide a Director approval flow (frontmatter-driven, sentinel-optional) that
  surfaces in the Inbox alongside task approvals and path requests.
- Define per-subtype *execution hints* so the Director knows what action to take
  on approval (e.g., "run `glorbo new agent …`").
- **Auto-approve `hire` proposals within a configurable headcount budget** so
  routine team scaling doesn't block on the Director, while preserving oversight
  for large teams.
- Fit into existing GEP-25 `FileSpec` infrastructure and GEP-3
  filesystem-as-source-of-truth invariants.
- Require zero changes to GEP-19 task approval.

## Non-goals

- **Unifying task approval and proposals.** GEP-19's task approval stays separate.
  A future GEP may unify them if real-world pain justifies the refactor.
- **Multi-director or delegated approval.** One Director literal, same as GEP-19.
- **Automatic proposal execution.** The GEP defines *execution hints* (human-readable
  instructions + optional CLI snippet), not automated side-effects. The Director
  manually runs the hinted command or action.
- **Proposal editing after submission.** Once a proposal is created, the agent should
  not modify it; a new proposal supersedes the old.

## Design

### On-disk layout

```
companies/<co>/
  proposals/
    hire-writer-2026-04-21.md
    increase-ceo-budget.md
    new-blog-workspace.md
```

- One file per proposal. Filename is agent-chosen but conventionally includes a
  short descriptor + date. The file stem is the proposal ID.
- `proposals/` is a new directory at the company root, peer to `agents/`,
  `projects/`, `channels/`, etc.
- **Only the Router and trusted Elixir processes (LiveView actions, CLI) write
  directly to `proposals/`.** Agents never mount `proposals/` read-write — see
  D7. Agents submit create/flip requests via their own outbox; the Router
  validates and performs the on-disk write.
- **bwrap enforcement:** `proposals/` is either `--ro-bind` (when the agent has
  `proposals:read:*`) or omitted. No agent template carries `proposals:write:*`
  any more.

### File format: `proposal/v1`

```yaml
---
kind: proposal/v1
id: hire-writer-2026-04-21          # stem of filename; must match
subtype: hire                        # enum: hire | budget | project | custom
status: pending-approval             # pending-approval | approved | denied | superseded
proposed_by: ceo                     # agent slug
requires_approval: director          # literal; future GEPs may extend
proposed_at: 2026-04-21T10:00:00Z    # ISO8601
approved_by: ~                       # null until approved
approved_at: ~                       # null until approved
denial_reason: ~                     # null unless denied
superseded_by: ~                     # null unless superseded
---

# Proposal body — freeform markdown

## Rationale

We need a Writer to handle the editorial calendar. Current roster: CEO only.
Workload: 7 articles queued. Estimated cost: $0 (local model).

## Execution hint

```bash
glorbo new agent techblog/writer --role writer --provider opencode \
  --model lmstudio/qwen/qwen3.6-35b-a3b --reports-to ceo
```

## Alternatives considered

- CEO writes all articles: infeasible, CEO should delegate.
- Hire an Editor first: Writer is the bottleneck.
```

#### Frontmatter schema

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `kind` | yes | `proposal/v1` | GEP-25 D8 discriminator |
| `id` | yes | string | must match filename stem |
| `subtype` | yes | enum | `hire`, `budget`, `project`, `custom` |
| `status` | yes | enum | `pending-approval`, `approved`, `denied`, `superseded` |
| `proposed_by` | yes | string | agent slug |
| `requires_approval` | yes | string | `director` for now |
| `proposed_at` | yes | ISO8601 | |
| `approved_by` | no | string\|null | Director literal or null |
| `approved_at` | no | ISO8601\|null | |
| `denial_reason` | no | string\|null | |
| `superseded_by` | no | string\|null | ID of newer proposal that replaces this one |

#### Execution hints

The body should contain an `## Execution hint` section (convention, not enforced)
with a human-readable instruction and an optional copy-paste CLI command. This
is advisory — the Director decides whether to follow it.

### Headcount budget and auto-approval

Companies may declare a `headcount_budget` in `company.md` frontmatter:

```yaml
---
kind: company/v1
slug: techblog
name: TechBlog Inc
headcount_budget: 3    # CEO + 2 agents; default 1 if absent
---
```

When the Router sees a `hire` or `fire` proposal, it evaluates auto-approval:

| Proposal subtype | Auto-approve condition | Result |
|------------------|------------------------|--------|
| `hire` | Current active agents < `headcount_budget` | `status: approved`, `approved_by: auto`, emit `proposal.auto-approved` |
| `hire` | Current active agents ≥ `headcount_budget` | Stays `pending-approval`; Director must review |
| `fire` | Target agent has no `assigned_to:` tasks | `status: approved`, `approved_by: auto`, emit `proposal.auto-approved` |
| `fire` | Target agent has assigned tasks | Stays `pending-approval`; Director must review to avoid orphaning work |

**Active agent count** = agents with `AGENT.md` present minus agents with
`status: retired` (or `RETIRED.md` sentinel). The Router scans `agents/*/` on
every proposal write; this is cheap (filesystem cache) and deterministic.

**Non-hire/fire proposals** (`budget`, `project`, `custom`) always require
Director manual approval. They never auto-approve.

### Approval flow

Proposals use a **frontmatter-only** approval flow. No sentinel file under
`agents/<slug>/state/` is required. The rationale: proposals are naturally
owned by the company, not by a specific agent, and the `status:` field is
sufficient.

| State transition | Trigger | Side effects |
|------------------|---------|--------------|
| `pending-approval` | Agent writes proposal file | `proposal.requested` audit event; Inbox renders card |
| `approved` | Director edits `status:` to `approved`, fills `approved_by`, `approved_at` | `proposal.approved` audit event; Inbox archives card |
| `approved` | Router auto-approves (headcount budget rule) | `proposal.auto-approved` audit event; Inbox may skip card or show "auto" badge |
| `denied` | Director edits `status:` to `denied`, fills `denial_reason` | `proposal.denied` audit event; Inbox archives card |
| `superseded` | Agent or Director edits `status:` to `superseded`, fills `superseded_by` | `proposal.superseded` audit event |

**No wake-on-approval.** Unlike GEP-19 task approval, proposals do not trigger
agent wake. The proposing agent observes `approved` on its next heartbeat or
channel check. This avoids coupling the proposal system to the dispatch pipeline.

**No history move.** Denied proposals stay in `proposals/`. They are part of the
company record. A future `glorbo prune` or manual cleanup can remove old ones.

### Router integration

Agent writes flow through the outbox:

```
agents/<sender>/outbox/proposals/<id>.md   (agent writes)
  → Router.classify_outbox_file/3 → {:proposal, id}
  → Router.handle_outbox_proposal/4 (validate + write + delete source)
  → proposals/<id>.md                       (canonical location)
```

The Router handler distinguishes **create** vs **flip** by the existence of the
destination file:

| Case | Existing `proposals/<id>.md`? | Required permission | Frontmatter rules |
|------|-------------------------------|---------------------|-------------------|
| Create | no | `proposals:propose:*` | `status: pending-approval`; `approved_by` / `approved_at` / `denial_reason` / `superseded_by` all null; Router stamps `proposed_by: <sender>` (forge-proof) |
| Flip | yes | `proposals:decide:*` | New `status ∈ {approved, denied, superseded}`. `id`, `subtype`, `proposed_by`, `proposed_at` preserved from existing file. For `approved` / `denied`: `approved_by` must not equal `proposed_by`. Router stamps `approved_by: <sender>` and `approved_at: <now>` |

On accept the Router writes `proposals/<id>.md`, deletes the outbox source, and
lets `Filesystem.Watcher` broadcast on `company:<co>:proposals` — the existing
`ProposalsSink` (wave 2a) emits the canonical audit event
(`proposal.requested` / `.approved` / `.denied` / `.superseded`). On reject the
Router emits a `proposal.rejected` audit with reason and drops the outbox
source so the agent doesn't retry on the same bad input.

`FileSpec.ProposalMd` validation applies at both layers (Router pre-write and
`glorbo validate` / `fmt` offline).

### Inbox surface

`InboxLive` renders proposal cards in the **Mine** tab alongside task approvals
and path requests. Each card shows:

- `subtype` badge (`hire`, `budget`, etc.)
- `id` and first line of rationale
- `proposed_by` agent
- `proposed_at` timestamp
- **Approve** / **Deny** / **Archive** buttons

**Auto-approved proposals.** When the Router auto-approves a `hire` or `fire`
proposal, the Inbox may either (a) not render a card at all (silent approval),
or (b) render a compact "auto-approved" entry that collapses after one view.
The default is (a) to avoid noise; a company setting could toggle (b).

**Manual approval.** The Approve button opens the proposal file in a modal with
pre-filled `status: approved`, `approved_by: director`, `approved_at: <now>`.
The Director clicks **Save**; the Router sees the filesystem change and emits the
audit event. Deny works similarly with `denial_reason`.

Archive hides the proposal from Mine (same archival mechanism as task approvals).

### Permissions model

Proposals introduce a three-verb permission namespace (write access is
indirect — always via the outbox):

| Permission | Meaning |
|------------|---------|
| `proposals:read:*` | RO bwrap mount of `proposals/` — agent can read all proposals |
| `proposals:propose:*` | Router accepts `agents/<sender>/outbox/proposals/<id>.md` from the agent as new proposals (create only) |
| `proposals:decide:*` | Router accepts agent-sourced flips of existing proposals to `approved` / `denied` / `superseded` |

The CEO template carries `proposals:read:*` + `proposals:propose:*`. Director-
class agents carry `proposals:read:*` + `proposals:decide:*`. Neither carries
write access to the `proposals/` mount point directly.

**bwrap mapping:** `proposals/` is `--ro-bind` mounted for `proposals:read:*`;
nothing additional for `propose` / `decide` (the agent's own outbox is already
RW; the Router handles the move). Direct-write permission has been removed.

### Audit events

```jsonl
{"timestamp":"2026-04-21T10:00:00Z","action":"proposal.requested","actor":"ceo","target":"proposals/hire-writer-2026-04-21.md","detail":{"subtype":"hire"}}
{"timestamp":"2026-04-21T10:00:01Z","action":"proposal.auto-approved","actor":"system","target":"proposals/hire-writer-2026-04-21.md","detail":{"subtype":"hire","reason":"headcount_budget_available"}}
{"timestamp":"2026-04-21T10:05:00Z","action":"proposal.approved","actor":"director","target":"proposals/increase-ceo-budget.md","detail":{"approved_by":"director"}}
```

Canonical keys: `target:` points at the proposal file (GEP-19 D3).

### FileSpec module

`FileSpec.ProposalMd` implements the `FileSpec` behaviour:

- `match?/1` — path ends with `proposals/*.md`
- `kind/0` — `proposal/v1`
- `frontmatter_schema/0` — required + optional keys with types
- `canonical_key_order/0` — `kind, id, subtype, status, proposed_by, requires_approval, proposed_at, approved_by, approved_at, denial_reason, superseded_by`
- `docs/0` — link to this GEP

### Subtypes (extensible)

| Subtype | Typical execution hint | Example |
|---------|------------------------|---------|
| `hire` | `glorbo new agent …` | Scaffold a new agent |
| `fire` | `glorbo retire agent …` | Remove an idle agent |
| `budget` | `glorbo edit agent … --budget …` | Increase monthly budget |
| `project` | `glorbo new project …` | Create a new project |
| `custom` | Freeform | Anything not covered above |

New subtypes can be added without a GEP change — they are string values. The
validator accepts any string for `subtype` to avoid blocking creative uses.
However, the dashboard may only render rich UI for known subtypes.

## Migration / rollout

1. **New directory.** `glorbo init` (or `glorbo new company`) creates an empty
   `proposals/` directory. Existing companies get one lazily — the Router
   tolerates a missing `proposals/` dir.
2. **No breaking changes.** Task approval (GEP-19) is untouched. The Inbox
   surfaces proposals alongside existing approval types; no UI removal.
3. **CEO template update.** The CEO template gains `proposals:read:*` +
   `proposals:propose:*` and a new system-prompt section: "When you need to
   hire, increase a budget, or create a project, write a proposal file to
   `agents/<you>/outbox/proposals/<id>.md` — the Router moves it into
   `proposals/<id>.md` after validating the frontmatter."
4. **Reindex.** `glorbo reindex` learns to index `proposals/*.md` into the
   SQLite `proposals` derived table.

## Failure modes

| Failure | Surface | Mitigation |
|---------|---------|------------|
| Agent lacks `proposals:propose:*` | Router rejects outbox file; emits `proposal.rejected` audit with `reason: :permission_denied`; outbox source dropped | Frontmatter schema + Router permission check |
| Agent sets `proposed_by` to someone else on create | Ignored — Router stamps `proposed_by: <sender>` from outbox owner on every accept | Outbox-owner identity is forge-proof |
| Agent flips own proposal to `approved` | Router's flip path rejects when `approved_by == proposed_by`; emits `proposal.rejected` audit | D7 content rule |
| Proposal `id` doesn't match filename stem | Router rejects create; `FileSpec.ProposalMd` validator also flags it offline | Schema + Router pre-write check |
| Flip targets a non-existent `proposals/<id>.md` | Router rejects (treats absent-destination as create, but flip payload fails create rules) | Classify by destination existence |
| Race: two decisions on the same proposal | Last writer wins (filesystem semantics); both get audited | `proposal.approved` + later `proposal.denied` both land in audit log; UI surfaces the latest status |
| `subtype` is unknown string | Validator passes; dashboard renders generic card | Subtype is intentionally open |

## Implementation status (2026-04-22)

This GEP is **Draft**. Landed in the scaffolding commit:

- `FileSpec.ProposalMd` (spec + canonical key order + docs)
- `proposals:{read,propose,decide}:*` permission namespace
  (ACLMapper, PermissionMapper) — `write` retired in wave 2b
- Company scaffold creates `proposals/` + `headcount_budget: 3`
- CEO template carries `proposals:read:*` + `proposals:propose:*`
- `/proposals` listed in CEO runtime mount summary

**Landed in runtime-wiring wave 1:**

- `Filesystem.Watcher` classifies `proposals/*.md` as `:proposals`,
  reindexes on write, and broadcasts on `company:<co>:proposals`
  PubSub topic so downstream subscribers can subscribe without
  scanning disk.

**Landed in runtime-wiring wave 2a:**

- `Glorbo.Company.ProposalsSink` observer GenServer subscribes to
  the `proposals` topic and emits canonical audit events
  (`proposal.requested` / `.approved` / `.denied` / `.superseded`)
  whenever the file content transitions into a known status.
  Best-effort — never crashes the supervisor on a bad file.

**Landed in runtime-wiring wave 2b:**

- Router outbox indirection: `agents/<sender>/outbox/proposals/<id>.md`
  is classified as `{:proposal, id}` and handled by
  `Glorbo.Company.Router.handle_outbox_proposal/4`. Create vs flip
  dispatched by destination existence; permission + content rules
  enforced before the Router writes `proposals/<id>.md`.
- Drop `proposals:write:*`. Replace with `proposals:propose:*` +
  `proposals:decide:*`. bwrap no longer RW-mounts `proposals/`
  for any template.

**Deferred to runtime-wiring follow-up waves:**

- InboxLive proposal card rendering + approve/deny actions (wave 2c).
- Reindex `proposals` derived table (wave 2d).
- Auto-approval evaluator (headcount budget rule for `hire` / `fire`)
  (wave 2e).
- Integration + E2E tests from the Test strategy section.

## Test strategy

- **Unit:** `FileSpec.ProposalMd` schema validation, canonical key ordering.
- **Integration:** Router picks up `proposals/*.md` write, emits correct audit
  event, PubSub publishes.
- **E2E:** CEO agent writes a proposal; Director sees it in Inbox; approves it;
  audit event is recorded; reindex reconstructs state.

## Open questions

- **Q1. Should denied proposals be pruned automatically?** Currently no. A
  `glorbo prune --proposals` subcommand could be added later.
- **Q2. Should agents be able to write `superseded_by` on their own proposals?**
  Currently yes (they have `proposals:write:*`). A permission like
  `proposals:supersede:self` could be added if abuse is observed.
- **Q3. Should `custom` subtypes be namespaced (e.g., `custom:workspace`)?**
  Flat strings for now. Hierarchical subtypes are a future concern.
- **Q4. Proposal threading.** If a Director denies a proposal with feedback,
  the agent may want to submit a revised version. Is `superseded_by` enough,
  or do we need a thread/comment mechanism? Punted — superseded proposals
  are the v0.0.5 answer.

## Decision log

### D1. Proposals are separate from task approvals (no unification)

- **Decided:** `proposal/v1` is a new file kind with its own frontmatter schema,
  approval flow, and Inbox surface. GEP-19 task approval is untouched.
- **Alternatives:** Reuse task approval by creating a dummy task with
  `requires_approval: director` and `type: proposal`. Unify everything under
  a single `approval/v1` abstraction.
- **Why:** Task approval is tightly coupled to task execution (assigned_to swap,
  wake-on-grant, deny→history). Those semantics don't map to hiring or budget
  proposals. Unifying would require redesigning GEP-19, which is high-risk and
  not justified by current pain. A future GEP can unify if needed.

### D2. Frontmatter-only approval flow (no sentinel file)

- **Decided:** Proposals use `status:` frontmatter transitions only. No
  `agents/<slug>/state/awaiting-proposal-<id>.md` sentinel is created.
- **Alternatives:** Reuse GEP-19 sentinel pattern exactly (write sentinel on
  submission, delete on resolution).
- **Why:** Proposals are company-scoped, not agent-scoped. A sentinel under
  `agents/ceo/state/` implies the proposal "belongs" to the CEO, but the
  Director and other agents may need to read it. The `proposals/*.md` file
  itself is the single source of truth; adding a sentinel would duplicate
  state and complicate reindex.

### D3. No automatic execution on approval

- **Decided:** Approved proposals surface an execution hint in the body, but
  the Director must manually run the hinted command or action. No automated
  side-effects.
- **Alternatives:** Hook `subtype` → Elixir function that auto-runs on
  `status: approved` transition (e.g., auto-scaffold an agent on `hire`).
- **Why:** Structural changes (hiring, budget) are high-stakes. The Director
  should review the proposal body before acting. Automated execution would
  require a permission model and rollback mechanism that don't exist yet.
  This keeps v0.0.5 simple and auditable.

### D4. Proposals live at company root, not in agent workspace

- **Decided:** `companies/<co>/proposals/<id>.md`, not
  `agents/<slug>/workspace/proposals/<id>.md`.
- **Alternatives:** Agent writes proposal in its workspace, Router copies it
  to `proposals/` on exit.
- **Why:** Workspace is scratch space (GEP-3 D6). Proposals are persistent
  company records. Writing directly to `proposals/` matches the
  filesystem-as-source-of-truth invariant and avoids a copy step that could
  fail or race.

### D5. Subtype enum is open for extension

- **Decided:** `subtype` is a freeform string in the validator, with five
  well-known values (`hire`, `fire`, `budget`, `project`, `custom`). New subtypes
  can be introduced without changing the schema.
- **Alternatives:** Closed enum in the validator; new subtypes require GEP
  amendment. Or no enum at all — purely convention.
- **Why:** A closed enum would block users from inventing subtypes for their
  own workflows. A completely freeform field would lose dashboard UI affordances
  for known subtypes. The compromise: validate as string, render rich UI for
  known values, fall back to generic for unknowns.

### D7. Outbox indirection for all agent-sourced proposal writes (wave 2b)

- **Decided:** Agents no longer have direct write access to the `proposals/`
  directory. All agent-sourced proposal creation and status flips go through
  the per-agent outbox:

  ```
  agents/<sender>/outbox/proposals/<id>.md
  ```

  The Router's `handle_outbox_proposal/4` parses, validates, and (on accept)
  writes `proposals/<id>.md` — then deletes the outbox source. `proposals:write:*`
  is retired in favour of `proposals:propose:*` (create new) and
  `proposals:decide:*` (flip existing).

- **Alternatives:** (B) Keep direct write + add a "detect and reject" observer
  that reverts bad writes by caching prior content. (C) Enforce purely at the
  Inbox-UI layer, trusting that non-UI writes are Director-authored.

- **Why:** Option B requires the sink to maintain prior-state cache per proposal
  and implement a rollback mechanism on top of filesystem events — complex,
  racy, and still leaves a window where the bad state is observable. Option C
  is a lie (any agent with `proposals:write:*` can corrupt state). Outbox
  indirection matches every other Router-mediated write in the system (tasks,
  comments, memory, path requests) and makes the write path forge-proof: the
  outbox subtree is physically owned by the sender via bwrap, so the Router
  always knows who authored the request. Pre-1.0 this is a clean atomic cut;
  no backwards-compat shim.

### D6. Auto-approval for hire/fire within headcount budget

- **Decided:** `hire` proposals are auto-approved when the company's active
  agent count is below `headcount_budget`. `fire` proposals are auto-approved
  when the target agent has no assigned tasks. All other subtypes (`budget`,
  `project`, `custom`) always require Director manual approval.
- **Alternatives:** (a) All proposals require manual approval — high Director
  toil for routine hiring. (b) CEO has direct `agents:write:*` permission and
  creates agents without proposals — bypasses audit trail and approval surface.
  (c) Auto-approve all proposals unconditionally — too risky for budget/project
  changes.
- **Why:** Hiring and firing are reversible (an agent can be retired or
  re-scaffolded), whereas budget increases and project creation have lasting
  side-effects. Headcount is a simple, auditable guardrail. The proposal file
  still exists as an audit trail even when auto-approved, so the Director can
  review the team composition asynchronously.

## Related

- **GEP-3** — Filesystem as source of truth: proposals are on-disk, SQLite derived.
- **GEP-5** — Sandboxing: `proposals/` mount rules.
- **GEP-10** — Agent templates: CEO template gains proposal permissions.
- **GEP-19** — Director approval workflow: separate but analogous patterns.
- **GEP-25** — File format specs: `FileSpec.ProposalMd`, `glorbo validate`, `glorbo fmt`.
- **GEP-27** — Path requests: another Inbox approval type that proposals will sit alongside.
- `lib/glorbo/file_spec/` — existing FileSpec behaviour modules.
- `lib/glorbo_web/live/inbox_live.ex` — Inbox surface to extend.
