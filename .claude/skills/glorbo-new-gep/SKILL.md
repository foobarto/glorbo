---
name: glorbo-new-gep
description: Use when the user wants to create a new GEP (Glorbo Enhancement Proposal) — a design document describing a proposed change to Glorbo. Triggers on phrases like "new GEP", "write a GEP", "propose X as a GEP", "document this decision as a GEP". Guides the user through a structured Q&A to produce a well-formed GEP file in docs/geps/ with correct frontmatter, numbering, and the required sections including a decision log. Also handles superseding or extending existing GEPs with bidirectional-link updates.
---

# Glorbo: Write a New GEP

Guide the user through creating a new **Glorbo Enhancement Proposal**
in `docs/geps/`. A GEP is a numbered design record — see
`docs/geps/0001-gep-purpose-and-guidelines.md` for the full process.

The process is deliberately Q&A-driven: skip steps at your peril. Most
GEP anti-patterns (missing rationale, unclear scope, no alternatives
documented) come from skipping the brainstorming and jumping straight
to writing.

## When to use this skill

- User says "let's write a GEP", "new GEP for X", "document this as a
  GEP", "propose X".
- User is describing a design change that touches a public contract,
  on-disk layout, CLI surface, permission model, or any of Glorbo's
  architectural invariants (see GEP-2).
- User is reversing or extending a prior GEP.

**Do NOT use this skill for:**

- Bug fixes, doc tweaks, dep bumps, perf work with no API change.
- Open-ended brainstorming that hasn't narrowed down to a concrete
  proposal yet — finish the brainstorm first, then GEP the decision.
- Questions about GEPs (read GEP-1 directly).

## Prerequisites — always check first

1. **Read GEP-1.** `docs/geps/0001-gep-purpose-and-guidelines.md` is
   the authority on format, numbering, lifecycle, and conventions. If
   it has been updated since this skill was written, GEP-1 wins.
2. **Read GEP-2.** `docs/geps/0002-architecture-overview.md` is the
   architectural baseline. Almost every Standards GEP will reference
   it via `requires: [2]`. Knowing what's already captured there
   prevents re-deriving architecture in every new GEP.
3. **Read the index.** `docs/geps/README.md` shows existing GEPs; pick
   the next unused number and survey what's already decided.

## Process

### Phase 1 — Scope and framing (one question at a time)

Ask these one at a time. Don't batch. Wait for each answer before the
next.

**Q1: What are you proposing?** One sentence. If the answer takes a
paragraph, the scope is probably too wide — push back and ask the user
to narrow it to one decision space.

**Q2: What triggered this?** Concrete problem, missing capability,
contested part of the codebase, or a conversation that needs a stable
record. If the answer is "it seemed like a good idea," that's a red
flag — GEPs are for load-bearing decisions.

**Q3: Is this Standards, Informational, or Process?**

- **Standards** — changes code, on-disk layout, CLI, API, or user
  behaviour.
- **Informational** — captures a decision record or convention
  without proposing implementation.
- **Process** — changes how contributors work.

**Q4: Does this supersede or extend an existing GEP?**

- List any related GEPs by number. If one is being superseded, its
  frontmatter must be updated in the same PR (see GEP-1 "Updating
  GEPs" section).
- If it extends one, add a `requires: [N]` entry and be ready to
  update that GEP's `extended-by` field.

**Q5: What's explicitly NOT in scope?** This matters. GEPs sprawl
without firm non-goals. Ask the user to list 2–4 things this proposal
deliberately doesn't do.

**Q6: Is this ready for a full Draft, or should it land as a
Placeholder first?** A Placeholder is a lower-bar parking spot —
problem statement + goals + open questions + one or two settled
decisions. Appropriate when:

- The idea is worth capturing now but the design space is only
  partially worked out.
- The author (maintainer or triage-approved contributor) wants to
  reserve a GEP number without committing to the full shape.
- Most design decisions are still genuinely open.

A full Draft is appropriate when the design space is substantially
explored and the author is ready to defend concrete choices.

Default: if the user has clear answers to Q1–Q5 and 3+ decisions
they can articulate, go Draft. If they're iterating on the shape
and have more open questions than decisions, suggest Placeholder.

After Q1–Q6: summarize what you've heard and ask "does that sound
right?" before moving on. If the user revises, update your summary;
don't silently re-interpret.

### Phase 2 — Design (adaptive)

Now dig into the *design*. Depth depends on complexity:

- **Small GEP** (one module, one decision): maybe 2–3 questions.
- **Large GEP** (multi-module, affects contracts): 5–10 questions.
- **Informational retrofit**: mostly summarizing existing state, fewer
  questions — but still capture alternatives considered in the
  original design if the user remembers them.

Cover, in order:

1. **Design shape** — modules, data structures, contracts. For
   Informational GEPs, this is the "what is" being documented.
2. **Interfaces** — what callers see, what dependents expect.
3. **Migration or rollout** — how does this land without breaking
   anything? Skip for Informational GEPs.
4. **Failure modes** — what can go wrong? How does it surface? Skip
   for Informational and Process.
5. **Testing** — how is correctness validated? Skip for Informational
   and Process.

Each question should be **one question at a time**. Offer 2–3 options
with tradeoffs where possible, with your recommendation. The user
refining a recommendation is faster than a blank-page "what do you
think?"

### Phase 3 — Decision log (required, load-bearing)

This is the part most authors want to skip. Don't let them.

For every non-obvious choice the GEP makes, capture:

- **Decided:** what the GEP commits to.
- **Alternatives:** what else was considered.
- **Why:** one or two sentences of reasoning.

Walk the user through every material choice from phases 1–2 and
extract the decision log format. Number them **D1, D2, …** (not
hierarchical — easier to cite).

Minimum bars by status:

- **Placeholder:** at least 1–2 decision log entries for things
  already settled. Remaining entries explicitly flagged "to be
  captured during the brainstorm that takes this GEP to Draft."
  The §"Open questions" section carries the weight for a
  Placeholder.
- **Draft:** at least 3 decision log entries for a Standards GEP.
  If you can't find three, either the GEP is trivial (shouldn't be
  a GEP) or you haven't dug deep enough into alternatives.

For Informational retrofits, capture the decisions from the original
design even if the author isn't present — "why did the original design
pick X?" is still the question. If the answer is "I don't know,"
record that honestly (`Why: rationale not preserved; current code
reflects this choice`).

### Phase 4 — Write the file

Once the Q&A is complete:

1. **Pick the next GEP number.** Check `docs/geps/README.md` index
   for the highest existing number. Add 1. Example: if GEP-8 is the
   latest, write GEP-9.
2. **Copy the template.** `docs/geps/0000-template.md` is the
   skeleton. Rename to `docs/geps/NNNN-short-kebab-title.md`.
3. **Fill in the frontmatter** — `gep`, `title`, `author`, `status:
   Draft`, `type`, `created` (today's date), and relevant optional
   fields (`requires`, `supersedes`, `see-also`).
4. **Initialize the `history` field** with one entry for the Draft
   state. Date is today. Status is `Draft`. Note should be concise —
   "Initial draft" or "Retrofitted from pre-GEP notes" for retrofits.
   Every subsequent status change (Draft→Accepted, Accepted→
   Implemented, etc.) appends a new entry in the PR that changes the
   status. Never edit or delete history entries.
5. **Write the content** drawing on the Q&A answers. Scale each
   section to its complexity — short is fine. Kill placeholders.
6. **Write the decision log** from Phase 3. This is the part that
   makes it a GEP and not just a spec.
7. **Update the README index.** Add a row in the table in
   `docs/geps/README.md`.
8. **If extending/superseding, update the linked GEP's frontmatter.**
   Add/update `extended-by`, `superseded-by`, or `see-also` fields.
   Same PR, not later.

### Phase 5 — Self-review before handing back

**Run `mix gep.validate`** (defined in `lib/mix/tasks/gep.validate.ex`)
via Bash. It checks every mechanical concern in parallel:

- Required frontmatter fields + enum values (`type`, `status`).
- Filename number matching the `gep:` field.
- `status` ↔ `history` consistency (latest history entry's status
  must equal the top-level `status`).
- Bidirectional links (`supersedes` ↔ `superseded-by`, `requires` ↔
  `extended-by`).
- Cross-reference resolution (every GEP number referenced in
  `requires` / `supersedes` / `extended-by` / `see-also` must exist).
- README index ↔ file sync (every GEP file has a README row; every
  README row points at a real file; status matches).
- Required body sections for Standards Draft GEPs (Problem, Design,
  Decision log, etc.).

The task prints a green `✓` list on success and exits 0; on failure
it prints per-GEP error lines and exits 1. Treat a non-zero exit as
blocking — fix reported issues before handoff.

Then read through the new GEP for the things the validator can't
check:

- **Placeholders and TBD.** Replace or delete every one.
- **Internal consistency.** Does the design match the problem?
- **Scope creep.** Is this still one decision space?
- **Ambiguity.** Could any requirement be interpreted two ways? Pick
  one.
- **Decision log honesty.** Does each "Why" answer the question, or
  does it just restate the "Decided"? If the latter, the reasoning
  isn't captured — push the user for it.

Fix inline. No need to ask the user for permission to clean up
mechanical issues — just fix and note them in the handoff.

If `mix gep.validate` fails, fix the reported issue and re-run
until it's green. Don't hand off a GEP that doesn't validate.

### Phase 6 — Handoff

Tell the user:

- Path to the new GEP.
- Outcome of `mix gep.validate` (the green summary is fine as-is;
  if there were failures you had to fix, briefly mention them).
- What other GEPs' frontmatter was updated (if any).
- That the status is `Draft` — they need to review and approve before
  flipping to `Accepted`.
- Whether the README index was updated.
- Any open questions you captured in §"Open questions" that they need
  to decide before acceptance.

Do **not** flip the status to `Accepted` without explicit user
approval. Do **not** commit to git without asking — GEP PRs are
typically reviewed before landing.

## Rules

- **One question at a time.** Don't batch questions. The whole point
  of the skill is the guided Q&A.
- **Push back on low-bar GEPs.** If the proposal is trivial (a one-off
  refactor, a doc tweak), say so and suggest the user skip the GEP
  process. Respect their call if they still want one, but don't rubber
  stamp.
- **Always write a decision log.** Non-negotiable for Standards GEPs.
- **Always update the README index** when creating a new GEP.
- **Always update linked GEPs' frontmatter** when extending or
  superseding — same session, not "I'll do it later."
- **Use today's date** for `created:`. Check the current date before
  writing the file (the harness exposes this via the system reminder;
  fall back to `date +%Y-%m-%d` via Bash if uncertain).
- **Default `status: Draft`.** Only flip to `Accepted` when the user
  explicitly approves.

## Red flags to watch for

| Signal                                      | What it means                          |
|---------------------------------------------|----------------------------------------|
| "Just put X in the decision log"            | User is skipping the "why." Push back. |
| "Let's just use the old plan as the GEP"    | Retrofit is fine but capture alternatives if they remember any. |
| Answer-in-a-paragraph to scope questions    | Scope is probably too wide. Split.     |
| No non-goals                                | Scope is unbounded. Ask for 2–4.       |
| Single decision log entry on a big proposal | Not dug deep enough. Find more.        |
| "We decided this last week, just write it"  | That's fine — write it, but include the alternatives that lost. |

## Reference

- **Process authority:** `docs/geps/0001-gep-purpose-and-guidelines.md`
- **Template:** `docs/geps/0000-template.md`
- **Index:** `docs/geps/README.md`
- **Architectural baseline:** `docs/geps/0002-architecture-overview.md`
- **Validator:** `mix gep.validate` — runs structural + link checks
  (`lib/mix/tasks/gep.validate.ex`, implemented by `Gep.Validator` in
  `lib/gep/validator.ex`).
