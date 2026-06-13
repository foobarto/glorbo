---
gep: 57
title: Deep-research task type — governed multi-step gather/read/synthesise
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Draft
type: Standards
created: 2026-06-12
requires: [56]
see-also: [13, 24, 26, 32, 40, 56]
history:
  - date: 2026-06-12
    status: Placeholder
    note: |
      Parked from the 2026-06-12 odysseus cross-pollination review. Adapts the
      odysseus Deep Research pipeline (services/research/*, src/deep_research.py)
      into a first-class glorbo task kind that emits a portable, sanitised report
      artifact into the company tree.
  - date: 2026-06-12
    status: Draft
    note: |
      Design resolved in brainstorm. D3 shape = template + orchestration module
      (no FileSpec schema change; YAGNI). D4 budget = degrade-to-partial-report
      (falls out of the existing 80%/100% gates). D5 source content framed as
      untrusted via GEP-56 (now Draft). D6 runner = any agent holding the
      research template + web_fetch + network (a `researcher` role ships as the
      example). Draft-only this cycle; implementation follows GEP-56/59.
---

# GEP-57: Deep-research task type

## Problem

Glorbo agents can already research informally — a CEO agent with `web_fetch`
(GEP-32) and `network: proxy` can crawl, read, and write a markdown summary.
But there is no **first-class, repeatable, governed** research *task*: no
bounded multi-step gather→read→synthesise loop, no budget-aware depth control,
no standard portable artifact, and no way to schedule one (GEP-24) or thread it
through the chain-observability machinery (GEP-40). Each agent reinvents it ad
hoc, with no consistent output an operator can review or `scp`.

## Goals

- A bounded, governed research task: explicit step/budget caps, gather → read →
  synthesise.
- Emit a **portable artifact** — a self-contained, sanitised HTML report
  (via the existing `html_sanitize_ex`) plus its markdown source — into
  `projects/<slug>/reports/<id>/`, consistent with filesystem-as-source-of-truth
  (GEP-3).
- Reuse existing rails: native web tools (GEP-32), budget governance, task IDs
  (GEP-13), task-chain observability (GEP-40), scheduler (GEP-24).
- Treat every fetched source as **untrusted content** (GEP-56) end to end.

## Non-goals

- **Not** a general autonomous-agent framework — depth and budget are bounded.
- **Not** a new crawler/search engine — rides `web_fetch` + the egress proxy.
- Does not bypass `network:` policy or per-agent egress authz (GEP-50).
- No bundled headless browser or JS rendering in v1.
- **Not** a new `kind:` in the FileSpec — a template + module (D3).

## Design

### Shape: template + orchestration module (D3)

A `research/` skill template (GEP-10) whose frontmatter declares the bounds:

```yaml
max_steps: 8
max_sources: 20
budget_usd: 2.00
```

driven by a `Glorbo.Research` module:

1. **Plan** — one LLM call turns the task prompt into a search/gather plan.
2. **Gather** — fetch up to `max_sources` via `web_fetch` (GEP-32), through the
   agent's `network: proxy` egress (GEP-23/50). Each fetched page is an
   **untrusted chunk** (GEP-56, D5).
3. **Read/extract** — per-source extraction LLM calls (untrusted-framed input).
4. **Synthesise** — a final LLM call composes the report from the framed
   sources.
5. **Render** — emit `report.md` + a self-contained, sanitised `report.html`
   (Earmark → `html_sanitize_ex`) under `projects/<slug>/reports/<id>/`.

No FileSpec schema change: the research task is an ordinary task whose body
points at the `research/` template; the dashboard/Kanban render it as a normal
task with a report artifact attached. (Promotion to a first-class
`kind: task/research` is a deliberate follow-up *if* it earns a board slot.)

### Governance: each step is an ordinary budgeted, audited call (D2)

Every plan/gather/read/synthesise step is a normal dispatch — company/agent
budgets (80% warn / 100% refuse) and the audit log apply unchanged. No
special-casing: a research task is exactly as governed as any other.

### Budget semantics: degrade to a partial report (D4)

The cap is enforced by the *existing* gates, not new logic. When the 100% gate
**refuses** the next step's dispatch (or `max_steps`/`max_sources` is reached),
the loop **finalizes a partial report** from whatever was gathered, with a
`> Truncated at budget` banner at the top of `report.md`. The operator always
gets a reviewable artifact; the gather/read work already paid for is never
discarded. (A synthesis-reserve refinement — carve out budget so the writeup is
always coherent rather than mid-sentence — is noted for a follow-up.)

### Source framing (D5)

Research output is built entirely from untrusted web content. Every fetched
page, every extracted span, and the intermediate context that flows into the
synthesis call is framed via **GEP-56** (`:untrusted` provenance, matched-random
boundaries). The rendered report is data; it never re-enters an agent's prompt
as instructions without re-framing.

### Runner (D6)

Any agent holding the `research/` template **and** `web_fetch` **and** a
`network:` policy that permits egress can run a research task — no new
privilege. A `researcher` role `AGENT.md` ships as the canonical example
(the template + a `network: proxy` grant), but research is template-gated, not
role-locked.

## Decision log

### D1. Output is a portable filesystem artifact *(settled)*
- **Decided:** `report.md` + self-contained sanitised `report.html` under
  `projects/<slug>/reports/<id>/`.
- **Why:** matches GEP-3 (everything is a file) — `tar`/`scp`/`git` (GEP-33).

### D2. Reuse budget + audit rails, no special-casing *(settled)*
- **Decided:** each research step is an ordinary budgeted, audited LLM call.
- **Why:** governance is glorbo's differentiator; research must be as governed
  as any dispatch.

### D3. Template + orchestration module, not a new task kind *(settled)*
- **Decided:** a `research/` template + `Glorbo.Research` module; no FileSpec
  schema change.
- **Alternatives:** a first-class `kind: task/research` (cleaner board
  integration, heavier — schema + validator + UI before the feature is proven).
- **Why:** YAGNI; ride the existing task rails. Promote to a kind later if it
  earns a board slot.

### D4. Budget = degrade to a partial report *(settled)*
- **Decided:** on the 100% gate refusing the next step (or hitting
  `max_steps`/`max_sources`), finalize a partial report with a truncation
  banner.
- **Alternatives:** hard-stop/fail (wastes paid work, no artifact);
  synthesis-reserve (a refinement, deferred).
- **Why:** the operator always gets something reviewable; aligns with the
  existing gates rather than adding new budget logic.

### D5. Sources framed as untrusted via GEP-56 *(settled)*
- **Decided:** all fetched/extracted content carries `:untrusted` provenance and
  is matched-random-framed (GEP-56) through to the report.
- **Why:** research input is the canonical untrusted-content case.

### D6. Runner = template-gated, any qualifying agent *(settled)*
- **Decided:** any agent with the `research/` template + `web_fetch` + egress;
  a `researcher` role ships as the example.
- **Why:** template-first; no new privilege axis.

## Migration

None required — additive, template-first:

- **No FileSpec/schema change** (D3) — a research task is an ordinary task; no
  validator, SQLite, or dashboard schema change, no `glorbo reindex`.
- **New content only** — the `research/` template + the `Glorbo.Research` module
  + the `report.md`/`report.html` output layout. Existing companies gain the
  capability by installing the template; nothing they already have changes.
- **Depends on GEP-56** (`requires: [56]`) — source framing must land first.

## Related

- GEP-32 native harness (`web_fetch`) · GEP-24 task scheduler · GEP-13 task IDs ·
  GEP-40 task-chain observability · GEP-26 benchmark/A-B comparison ·
  GEP-3 filesystem as source of truth · GEP-56 untrusted content framing.
- Prior art: odysseus `services/research/service.py`, `src/deep_research.py`,
  `src/visual_report.py` (server-rendered sanitised report).

## Implementation reconciliation (2026-06-14)

This is an append-only record (GEP-1: the body of an Accepted/Implemented GEP is not rewritten; deviations from what shipped are recorded here instead).

- **D6 — canonical `researcher` role does not carry the `research/` template it is defined by — known-gap.** D6 (lines 116-120, 156-159) states the runner is template-gated and that "a `researcher` role `AGENT.md` ships as the canonical example (the template + a `network: proxy` grant)." The shipped role template `priv/templates/agents/researcher.md:13-15` lists `skills: [glorbo, web-search]` — not `research` — and its body (`:35`, `:127-131`) directs the agent to the `web-search` skill, never the `research/` template; the bench example `priv/templates/companies/bench-tech-blog/agents/researcher/AGENT.md` lists only `skills: [glorbo]`. So neither shipped "researcher" actually holds the template per D6. Both the `research/` skill template (`priv/templates/skills/research.md`, frontmatter `name: research` with the `max_steps`/`max_sources`/`budget_usd` bounds) and the orchestrator (`lib/glorbo/research.ex`, `Glorbo.Research`) *do* ship — the gap is narrowly that the canonical role example was never wired to hold the template, leaving the artifact D6 names as "the canonical example" incomplete. Note: `Glorbo.Research.run/2` is invoked with `:company`/`:slug` and does not itself enforce the agent-holds-`research`-skill gate, so D6's gating is a documented capability model rather than code-enforced; that makes the role's `skills:` list the only place the gate is expressed, which is exactly where it is missing. Fix later by adding `research` to `priv/templates/agents/researcher.md`'s `skills:` list (and the bench researcher), or amend the GEP body's D6 example claim — but the GEP body stays as-is per GEP-1; recorded here as the gap to close.
