---
gep: 21
title: File-based Agent Memory
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-21
requires: [2, 3, 5, 15, 16]
see-also: [4, 19]
history:
  - date: 2026-04-21
    status: Draft
    note: Initial draft capturing the memory-per-agent design agreed in the /loop session.
  - date: 2026-04-21
    status: Implemented
    note: "R17 shipped the memory read path (compose_prompt threads a memory digest). R17b shipped the write path — outbox classifier, atomic writes, MEMORY.md upsert, audit trail. R17c proved both ends via live qwen dispatch (read + write). R20/R22 added the sidebar memory-count badge UX."
---

# GEP-21: File-based Agent Memory

## Problem

Every agent dispatch today is prompt-stateless. The CEO who heard "we
don't ship on Fridays" from the director three weeks ago cannot recall
it when a Friday task arrives. The engineer who learned that the
staging VPN is at `10.0.5.*` re-learns it every time. Context that
would shape better decisions is lost to the gap between dispatches.

Claude Code itself solved this problem with a persistent file-based
memory system — Glorbo should mirror the pattern rather than invent
its own. The cost of a second convention is higher than the cost of
adopting a well-understood one.

Two things are actually being asked of this GEP:

1. **A writing discipline** — a place agents can ask to remember
   things, gated by the same outbox routing that every other
   agent-originated side effect goes through (GEP-16's inbox/outbox
   one-way flow).
2. **A reading discipline** — how remembered content lands back into
   the next prompt without blowing the context budget.

## Goals

- Give each agent its own isolated memory under
  `agents/<slug>/memory/` (filesystem-first, per GEP-3).
- Four fixed memory types (`user | feedback | project | reference`)
  with fixed meanings directors can learn once and agents can adopt
  from the `glorbo.md` skill.
- Agent writes land through outbox routing (new routing kind), so
  GEP-5's bwrap mount invariant holds: an agent never writes to its
  own `memory/` directly — the Elixir Router mediates.
- Reads compose into the system prompt via `Agent.Server.compose_prompt/4`
  with a hard size cap so long-running agents don't balloon prompts.
- Cross-agent memory access is impossible: bwrap only mounts the
  agent's own `memory/`, and the Router rejects outbox writes whose
  target is another agent's memory.
- Audit trail for every memory mutation (`memory.write`, `memory.delete`).

## Non-goals

- **No semantic retrieval.** v1 composes *all* of an agent's memory
  into the prompt, bounded by the cap. LLM-decided relevance is a
  follow-up GEP if and when the cap proves limiting.
- **No cross-agent memory sharing.** If the CEO wants the engineer to
  know something, that's a channel message or a task comment, not a
  memory.
- **No memory UI** on AgentLive in this GEP. Ships after the data
  model + write path are validated in production.
- **No automatic compaction.** An agent that accumulates past the cap
  loses oldest-by-mtime entries; director compaction happens by
  editing or deleting files directly.
- **No explicit memory versioning.** git history covers this for
  directors who care; we don't duplicate it.

## Design

### On-disk layout

```
companies/<co>/agents/<slug>/memory/
├── MEMORY.md                    # index, always loaded (≤150 chars per line)
├── user_<topic>.md              # user (= director) profile
├── feedback_<topic>.md          # corrections + confirmations
├── project_<topic>.md           # project facts, deadlines, stakeholders
└── reference_<topic>.md         # pointers to external systems (URLs, dashboards)
```

**Filenames** are always `<type>_<topic>.md` where:
- `<type>` ∈ `{user, feedback, project, reference}` (enforced).
- `<topic>` matches `[a-z][a-z0-9_-]{0,63}` (same slug regex as skill
  names in `Glorbo.Agent.Parser`).

**Each memory file** has frontmatter + body:

```yaml
---
name: Director prefers concise commit messages
description: One-line hook used by the index — keep ≤150 chars
type: feedback
---

Rule: commits should lead with the why, not the what.

Why: the director said on 2026-04-20 that commit noise was a recurring
frustration; terse, concrete messages pass review without round-trips.

How to apply: draft the commit body first, ruthlessly cut anything
already obvious from the diff, and save the "I did X" narrative for
the PR description instead.
```

**`MEMORY.md`** is an append-only index maintained by the Router:
```markdown
- [Director prefers concise commit messages](feedback_commit_style.md) — lead with the why, not the what
- [Staging VPN address](reference_staging_vpn.md) — 10.0.5.0/24, set via `wg-quick up staging`
```

Each line ≤150 chars. The index itself is always loaded into the
prompt; individual body files are loaded subject to the total cap.

### Writing (outbox routing)

Agents request a memory write by dropping a file into their outbox:

```
agents/<slug>/outbox/memory/<type>_<topic>.md
```

`Glorbo.Company.Router.classify_outbox_file/3` (GEP-16) gains a new
clause matching `["memory", filename]`. On match:

1. Parse the file's frontmatter; reject if `type` field disagrees
   with the filename prefix.
2. Reject if `<topic>` fails the slug regex.
3. Reject if body size exceeds **8 KB** (per-memory cap — keeps the
   total fitting under the read cap even with dozens of memories).
4. Reject if it's an attempt to write to *another agent's* path (the
   outbox path already implies the writing agent — a Router check
   that `target_slug == sender_slug` is belt-and-braces).
5. Atomic-write (tmp + rename) into
   `agents/<slug>/memory/<type>_<topic>.md`.
6. Update `agents/<slug>/memory/MEMORY.md`: replace existing line for
   this filename (match by path), or append new line. Preserves all
   other index entries verbatim.
7. Emit `memory.write` audit event (`actor: <agent>`, `target:
   memory/<type>_<topic>.md`, `bytes: N`).
8. Delete the outbox source file.

**Deletes** happen the same way: agent drops
`agents/<slug>/outbox/memory/delete/<type>_<topic>.md` (an empty
marker file). Router removes the on-disk file + index line, emits
`memory.delete`.

### Reading (prompt composition)

`Agent.Server.compose_prompt/4` gains a new section, inserted
between the permission-mount summary and the inbox body:

```
## Memory

<MEMORY.md body, verbatim>

<selected memory bodies, newest-first by mtime, truncated to total cap>
```

**Cap**: 20 KB total (index + bodies combined). Index is always
included; bodies fill the remaining budget newest-first. An agent
that overwrites memories has their most-recent view surface first.

When the budget is exhausted mid-body:
- Finish the current body (don't truncate mid-paragraph).
- Emit a trailing `[N older memories not shown]` line so the agent
  knows the truncation happened.

### Bwrap mount policy (GEP-5 invariant)

The agent's sandbox mounts `memory/` read-only, same as
`priv/templates/skills/`. The agent sees the whole memory via its
prompt; it cannot `cat` or `grep` around in there. Write path is
outbox-only.

Cross-agent: each sandbox only mounts its *own* `memory/` via `bwrap
--bind`. No mount of other agents' memory ever occurs; there's no
way to see what siblings remember.

### Audit events

- `memory.write` — `%{target, type, topic, bytes, action: "memory.write"}`
- `memory.delete` — `%{target, type, topic, action: "memory.delete"}`

`AuditEntry.action_phrase/4` gains sentence renderers:
- `memory.write` → "wrote a memory: `<topic>`"
- `memory.delete` → "deleted memory `<topic>`"

### Module layout

| Module | Role |
|--------|------|
| `Glorbo.Agent.Memory` | Pure read + compose functions — no IO except `File.read`. `list/2`, `compose_into_prompt/3`, `index_lines/1`. |
| `Glorbo.Company.Router` | Extended: new `classify_outbox_file/3` clause for `memory/*`; new `perform_routing/3` clause for memory writes + deletes. |
| `Glorbo.Agent.Server.compose_prompt/4` | Extended: insert memory section. |
| `priv/templates/skills/glorbo.md` | Documents the write protocol for agents. |

`Glorbo.Agent.Memory` is pure enough that its tests don't need bwrap
or Router; Router tests cover the mediated-write path.

### Filesystem cap enforcement

Per-memory: 8 KB body. Total-per-agent: 100 KB on disk (soft cap).
When total exceeds 100 KB, `Memory.compose_into_prompt/3` emits a
`memory.over_cap` warning audit (once per dispatch, not once per
memory). The 20 KB prompt cap continues to apply at compose time
— the on-disk cap is a director-visible signal, not an enforcement.

## Migration / rollout

- Existing agents: no `memory/` directory initially. `Memory.list/2`
  handles missing dir by returning `[]`; prompt renders identically
  to today.
- `glorbo new agent` scaffolding: creates an empty `memory/` dir +
  empty `MEMORY.md` (so the Router's index-append path always has a
  file to write).
- Existing installations: `glorbo reindex` creates missing memory
  dirs but does NOT populate them. Empty memory is the correct
  initial state.
- `priv/templates/skills/glorbo.md` gets a new section teaching
  agents the outbox-write protocol. This ships with v0.0.4.

Backward-compat: zero breakage. The feature is additive. Agents that
never write to memory behave identically to pre-GEP-21 agents.

## Failure modes

| Failure | Surface |
|---------|---------|
| Outbox memory file has invalid `type` | Router rejects, emits `memory.rejected` audit, file stays in outbox for director inspection |
| Body > 8 KB | Same as above |
| Body has no frontmatter | Same as above |
| MEMORY.md index write fails (disk full) | Router refuses the memory write (atomic: either both land or neither); emits `memory.rejected` |
| Memory dir corrupted / unreadable | `Memory.compose_into_prompt/3` returns empty; prompt renders without the Memory section; `memory.read_failed` audit |
| Agent tries to write into another agent's memory via path manipulation (e.g. `../../other-agent/memory/…`) | Router path-prefix check rejects; `memory.rejected` with reason `cross_agent` |
| Prompt-size total exceeds cap | Truncation with `[N older memories not shown]` marker, no audit (expected behaviour) |

## Test strategy

- **Unit** (`Glorbo.Agent.Memory`):
  - Compose with no memory dir → empty string.
  - Compose with index + 1 body → full body + index.
  - Compose with 50 bodies summing > 20 KB → cap honoured, newest
    first, truncation marker present.
  - Missing MEMORY.md but memory files present → bodies still load.

- **Integration** (`Glorbo.Company.Router`):
  - Valid memory write lands, index updated, outbox cleared, audit
    emitted.
  - Invalid frontmatter rejected, file stays in outbox.
  - Delete marker removes file + index line.
  - Cross-agent path attempt rejected with specific reason.
  - Concurrent writes to same topic: last-wins (fsync + rename
    atomicity already provides this).

- **End-to-end** (`Glorbo.Agent.Server`):
  - Agent prompt before a write contains no Memory section.
  - Agent drops outbox memory, next wake sees it in prompt.
  - Prompt token count before/after memory composition within 20 KB
    budget.

No bwrap needed in any test — the Router check is application-level;
kernel-layer enforcement is tested in GEP-5's invariants and doesn't
need re-proving here.

## Open questions

- **Memory compaction policy**: do we ship a scheduled task that
  periodically summarises redundant memories, or wait for real
  accumulation to motivate it? Deferred — ship without compaction;
  add if and when a company hits the 100 KB soft cap regularly.
- **Promotion**: should a feedback memory "graduate" to a project
  memory after some consistency check? Deferred — directors can
  manually move/rename.
- **Search**: should `Glorbo.Search` include memory content in the
  Ctrl+K palette? Not yet — memory is per-agent; palette is
  company-wide. Different index, different lane.

## Decision log

### D1. Four fixed memory types, not free-form

- **Decided:** types constrained to `user | feedback | project |
  reference`.
- **Alternatives:** free-form types (any string); three types (drop
  `reference`); hierarchical types (e.g. `project.budget`).
- **Why:** the Claude Code memory system already ships this taxonomy
  and directors pattern-match onto it from their own daily use.
  Free-form types lead to taxonomy drift within a single company
  (three agents, three slightly different schemes). Hierarchical is
  over-engineered for a ≤20 KB prompt payload.

### D2. Write via outbox, not direct filesystem

- **Decided:** agents drop files into `outbox/memory/`, Router
  mediates the write into `memory/`.
- **Alternatives:** bwrap `--bind` `memory/` as writable; expose a
  Glorbo API (e.g. HTTP endpoint) agents can call.
- **Why:** preserves GEP-5's one-way bwrap mount invariant. Mediated
  write lets the Router enforce size/type/path validation uniformly;
  a writable bind would push validation into the agent (which we
  don't trust) or into the kernel layer (which we can't teach about
  YAML). An HTTP endpoint introduces a new surface we'd have to
  audit separately. The outbox is a proven discipline.

### D3. 20 KB total prompt cap + 8 KB per-memory + 100 KB soft on-disk

- **Decided:** hard 20 KB combined (index + bodies) at compose time;
  hard 8 KB per individual memory body; soft 100 KB total on-disk
  (warning audit, not enforcement).
- **Alternatives:** unbounded; configurable per agent; dynamic based
  on the model's context window.
- **Why:** 20 KB is a rough fifth of an 80 KB model window — the
  agent still has room for inbox + skills + system. 8 KB per body
  prevents any single memory from monopolising the budget. Soft 100 KB
  on-disk gives directors a clear "time to review" signal without
  breaking dispatch. Dynamic per-model would couple the write path
  to model details that change more often than memories do.

### D4. Newest-first body selection when over cap

- **Decided:** bodies selected by descending mtime until budget is
  exhausted.
- **Alternatives:** selection by topic relevance (LLM-decided);
  manual priority field in frontmatter; round-robin.
- **Why:** newest-first matches how directors work — they write down
  the most recent correction / fact / rule first. A manual priority
  field adds burden to the director and bias to the agent's writes.
  LLM-decided relevance is speculative until we see real accumulation
  failures; that's a separate GEP if the simple rule proves limiting.

### D5. Index file (`MEMORY.md`) always loaded

- **Decided:** `MEMORY.md` is included in every prompt even when
  bodies are truncated.
- **Alternatives:** no index file (agent reconstructs from body
  frontmatter each time); index always truncated proportionally.
- **Why:** the index is small (N lines × ≤150 chars) and gives the
  agent awareness of memories it can't fully read this pass.
  "You know there's a feedback memory about commit style; here's the
  one-line hook" is more useful than silently dropping it. Matches
  Claude Code's own memory pattern.

### D6. Memory reads are per-dispatch (no caching)

- **Decided:** `Agent.Server.compose_prompt/4` re-reads the memory
  tree on every dispatch.
- **Alternatives:** ETS cache keyed by (slug, mtime); in-memory
  maintained in `Agent.Server` state.
- **Why:** dispatches are infrequent (seconds apart at best; typically
  minutes). Memory tree is O(≤100 KB). File.read of ≤20 files is
  cheap enough that caching complexity isn't justified. A cache would
  also miss out-of-band edits (director editing `memory/*.md` by
  hand, which is a supported workflow).

### D7. No agent-to-agent memory visibility

- **Decided:** bwrap only mounts the agent's own `memory/`; Router
  rejects cross-agent outbox writes.
- **Alternatives:** company-wide shared memory (`companies/<co>/memory/`);
  opt-in sharing via frontmatter (`readers: [engineer]`).
- **Why:** the director-to-director communication channels (chat,
  task comments) already serve the "make sure agent X knows about Y"
  use case. Shared memory creates cross-agent coupling that
  contradicts the agent-as-isolated-employee model (GEP-2). Opt-in
  sharing reopens the cross-agent surface we explicitly don't
  want to audit.

## Related

- GEP-2 — Architecture overview (agents-as-employees model, filesystem-
  first invariant).
- GEP-3 — Filesystem as source of truth; memory/ lives here, SQLite
  stays uninvolved.
- GEP-5 — Sandboxing (bwrap mount namespaces); memory/ is a new
  per-agent mount point.
- GEP-15 — ALLCAPS agent-facing markdown; `MEMORY.md` follows this
  convention.
- GEP-16 — Agent wake/dispatch pipeline; this GEP extends
  `Agent.Server.compose_prompt/4`.
- GEP-19 — Director approval workflow; memory writes don't need
  approval (they're scoped to the agent's own state; the director
  can delete any file they don't want).

## Implementation reconciliation (2026-06-14)

This is an append-only record (GEP-1: an Accepted/Implemented GEP's body above is not rewritten in place; deviations from what shipped are recorded here).

- **Finding 1 — glorbo.md skill omits the memory write protocol — known-gap.** The GEP's Module-layout table (line 204) and rollout note (line 229) say `priv/templates/skills/glorbo.md` gains a section teaching agents the outbox memory-write protocol, shipping with v0.0.4. The actual file (`/var/home/foobarto/Dokumenty/glorbo/priv/templates/skills/glorbo.md`) contains zero occurrences of "memory" (`grep -ci memory` → 0); its outbox section documents only tasks/comments/messages. Agents that read this skill have no documented path to the `outbox/memory/<type>_<topic>.md` write surface even though the Router fully implements it. Real doc gap to fix later; the runtime is unaffected.

- **Finding 2 — GEP example frontmatter omits the required `kind` field — as-shipped (GEP body stale).** GEP-0021's canonical memory-file example (lines 96-111) and write-path validation list (lines 133-148) show frontmatter with only `name`/`description`/`type`. The shipped write path requires `kind: agent-memory/v1`: `check_memory_kind/1` rejects any other value (`router.ex:1888-1894`, returning `{:error, {:memory_bad_kind, other}}`), it is wired into the write `with` chain (`router.ex:1360`), and `FileSpec.MemoryEntryMd` lists `:kind` as required and pins it to `"agent-memory/v1"` (`memory_entry_md.ex:13, 23`). The code is correct (its own `docs/examples` include the `kind:` line, `memory_entry_md.ex:48`); the GEP example and the failure-mode table (missing a `memory_bad_kind` / wrong-kind row) are stale. No code change.

- **Finding 3 — cross-agent memory-write rejection has no test and the `cross_agent` reason is not implemented — known-gap.** GEP-0021 makes cross-agent isolation load-bearing: the failure-mode table (line 243) requires a `../../other-agent/memory/…` path-manipulation attempt to be rejected with reason `cross_agent`, and the Test strategy (line 260) requires an integration test for it. The `memory write routing (GEP-21)` describe block (`router_test.exs:1052-1207`) covers accept / upsert / type-mismatch / oversize / delete but has no traversal or cross-agent case (`grep -i cross_agent|traversal|other-agent` → none). Structurally the invariant *is* enforced: `sender` is bound only from the slug-constrained outbox regex (`@outbox_rel_re`, `router.ex:65`), the memory filename is gated by `memory_filename_valid?` / `@memory_filename_re` (`router.ex:750-756, 811-812`) so a `../`-bearing name falls through to `:message` rather than classifying as a memory write, the destination is rebuilt from `sender` not the filename (`router.ex:1336-1339`), and an `lstat` guard refuses a symlinked dest (`router.ex:1356`). So the security property holds, but there is no `cross_agent` named reason and no regression test proving it — a real gap to close (add the test; and either implement the named reason or correct the failure-mode row to match the actual reject-as-`:message` / `memory_bad_kind` behaviour).
