---
gep: 57
title: Deep-research task type — governed multi-step gather/read/synthesise
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Placeholder
type: Standards
created: 2026-06-12
see-also: [13, 24, 26, 32, 40, 56]
history:
  - date: 2026-06-12
    status: Placeholder
    note: |
      Parked from the 2026-06-12 odysseus cross-pollination review. Adapts the
      odysseus Deep Research pipeline (services/research/*, src/deep_research.py)
      into a first-class glorbo task kind that emits a portable, sanitised report
      artifact into the company tree. Design space NOT yet worked out; see Open
      questions.
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

## Non-goals

- **Not** a general autonomous-agent framework — depth and budget are bounded.
- **Not** a new crawler/search engine — rides `web_fetch` + the egress proxy.
- Does not bypass `network:` policy or per-agent egress authz (GEP-50).
- No bundled headless browser or JS rendering in v1.

## Design (sketch — to be worked out before Draft)

Likely a task **template + orchestration module** rather than a brand-new task
schema: a `research/` skill/template (GEP-10) whose frontmatter declares
`max_steps`, `max_sources`, `budget_usd`, and a `Glorbo.Research` module that
drives the loop (plan → fetch N sources via `web_fetch` → extract → synthesise →
render report). Each step is an ordinary budgeted LLM call so company/agent
budgets and the audit log apply unchanged. Output is `report.md` + a
`report.html` rendered through Earmark + `html_sanitize_ex`.

## Open questions

*(load-bearing — these gate promotion to Draft)*

- **First-class task kind vs. template?** A new `kind: task/research` in the
  FileSpec (GEP-25) is cleaner for the dashboard/Kanban but heavier than a
  template + module. Lean template-first.
- **Source provenance:** research output is built from untrusted web content —
  must the report (and the intermediate context) be framed via GEP-56? Almost
  certainly yes; sequence GEP-56 first.
- **Budget semantics:** hard-stop at the cap mid-synthesis, or degrade to a
  partial report? How does it interact with the 80%/100% governance gates?
- **Who runs it:** any agent with `web_fetch` + a privilege, or a dedicated
  `researcher` role template?

## Decision log

### D1. Output is a portable filesystem artifact *(settled)*
- **Decided:** reports land as `report.md` + self-contained sanitised
  `report.html` under `projects/<slug>/reports/<id>/`.
- **Alternatives:** DB-only storage; an external report service.
- **Why:** matches GEP-3 (everything is a file) — back up with `tar`, move with
  `scp`, diff with git (GEP-33).

### D2. Reuse budget + audit rails, no special-casing *(settled)*
- **Decided:** each research step is an ordinary budgeted, audited LLM call.
- **Why:** governance is glorbo's differentiator; a research task must be as
  governed as any other dispatch.

### D3. Task-kind vs template, source-framing, budget semantics
- *To be captured during the brainstorm that takes this GEP to Draft* (see
  Open questions).

## Related

- GEP-32 native harness (`web_fetch`) · GEP-24 task scheduler · GEP-13 task IDs ·
  GEP-40 task-chain observability · GEP-26 benchmark/A-B comparison ·
  GEP-3 filesystem as source of truth · GEP-56 untrusted content framing.
- Prior art: odysseus `services/research/service.py`, `src/deep_research.py`,
  `src/visual_report.py` (server-rendered sanitised report).
