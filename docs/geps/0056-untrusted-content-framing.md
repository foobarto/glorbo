---
gep: 56
title: Untrusted content framing — data-not-instructions across agent boundaries
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Placeholder
type: Standards
created: 2026-06-12
see-also: [16, 21, 22, 23, 32, 35, 50]
history:
  - date: 2026-06-12
    status: Placeholder
    note: |
      Parked from the 2026-06-12 odysseus cross-pollination review. Borrows the
      `untrusted_context_message` / UNTRUSTED_CONTEXT_POLICY pattern from
      pewdiepie-archdaemon/odysseus (src/prompt_security.py) and adapts it to
      glorbo's MULTI-AGENT case, which that single-assistant app does not have.
      Priority item of the batch — promote to Draft first. Design space NOT yet
      worked out; see Open questions.
---

# GEP-56: Untrusted content framing

## Problem

Glorbo's primary trust boundary is the kernel sandbox, and `SECURITY.md`
deliberately scopes **"prompt injection within already-granted permissions"
out of scope** — sound for a *single* agent: misuse of a held capability is a
permission question, tighten `AGENT.md`.

But glorbo is **multi-agent**, and content crosses trust boundaries *into* an
agent's prompt: web-fetched pages via the native `web_fetch` tool (GEP-32);
inter-agent message bodies routed inbox→outbox (GEP-35); recalled file-based
memory (GEP-21) and installed skill text (GEP-22) authored elsewhere. A
compromised or injection-steered agent A can emit text that reads to agent B as
a peer instruction. The sandbox does not catch this — both agents act within
their grants — but the **propagation of injected instructions across the org**
is uncontained. That is a multi-agent risk the single-assistant prior art never
had, and it warrants a deliberate *defense-in-depth* answer that does not
pretend to replace the sandbox.

## Goals

- Frame content that crosses a trust boundary as **data, not instructions**
  when composed into an agent prompt.
- Carry a per-chunk **provenance** tag (`trusted` | `untrusted`) through the
  prompt-composition seam.
- State the policy once in the agent system preamble.
- Reduce cross-agent injection *propagation* without touching permission
  enforcement or the sandbox.

## Non-goals

- **Not** a replacement for the sandbox or permission model — strictly
  additive.
- **Not** a claim that prompt injection is "solved."
- Does **not** change router transport (GEP-35), egress (GEP-23/50), or the
  Actions write-channel (GEP-36).
- Does not control prompt assembly *inside* third-party CLI providers
  (claude/gemini/codex) — see D3.

## Design (sketch — to be worked out before Draft)

A small `Glorbo.Prompt.Untrusted` helper wraps a content chunk in an UNTRUSTED
sentinel block + short policy line, applied at the **prompt-composition seam in
the wake/dispatch pipeline (GEP-16)** — not in the router. Each assembled
context chunk gains `provenance: :trusted | :untrusted`; the composer wraps
untrusted chunks and emits the preamble when any is present. Native providers
get the full prompt; for CLI providers the markers travel on stdin best-effort.

## Open questions

*(load-bearing — these gate promotion to Draft)*

- **Inter-agent granularity:** frame the **whole** message vs. only
  **externally-sourced quoted spans** within it? Whole-message framing risks
  breaking legitimate delegation (B *should* often act on A's request). A
  per-edge trust setting in `AGENT.md` permissions is the heavier alternative.
- **SECURITY.md reconciliation:** amend the scope-out to "single-agent
  injection within grants = out of scope; cross-agent *propagation* mitigated
  by GEP-56 (DiD)"? Needs maintainer sign-off — this revisits a documented
  decision.
- **CLI-provider efficacy:** do claude/gemini/codex re-frame stdin enough to
  nullify the markers? Needs an empirical per-adapter check.
- **Provenance model:** where does the `trusted|untrusted` flag live in the
  context-assembly data shape, and does it survive the GEP-16 pipeline?

## Decision log

### D1. Defense-in-depth, not a sandbox replacement *(settled)*
- **Decided:** the sandbox stays the primary boundary; content framing is
  additive DiD for content that propagates *across* agents.
- **Alternatives:** do nothing (rely solely on the sandbox); attempt full
  prompt-injection prevention (infeasible).
- **Why:** the cross-agent propagation path is real and uncontained; a
  text-framing mitigation is cheap and reversible.

### D2. Apply at the prompt-composition seam, not the router *(settled)*
- **Decided:** the router (GEP-35) stays a content-agnostic transport; framing
  happens where chunks become a prompt (GEP-16).
- **Why:** preserves transport invariants; keeps framing at the LLM boundary.

### D3. Inter-agent granularity + provenance model
- *To be captured during the brainstorm that takes this GEP to Draft* (see
  Open questions).

## Related

- GEP-16 wake/dispatch pipeline · GEP-32 native harness (`web_fetch`) ·
  GEP-35 router split · GEP-21 file-based memory · GEP-22 skills registry ·
  GEP-23 egress proxy · GEP-50 per-agent egress authorization.
- Prior art: odysseus `src/prompt_security.py`
  (`untrusted_context_message`, `UNTRUSTED_CONTEXT_POLICY`) +
  `THREAT_MODEL.md` §Prompt-Injection.
