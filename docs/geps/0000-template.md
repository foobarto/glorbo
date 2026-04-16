---
gep: 0000                          # replace with your number (next free)
title: Short descriptive title     # ~60 chars max
author: Your Name <you@example.com>
status: Draft                      # Placeholder for early idea capture; Draft for active iteration (see GEP-1)
type: Standards                    # Standards | Informational | Process
created: YYYY-MM-DD
history:
  - date: YYYY-MM-DD
    status: Draft
    note: Initial draft.
# Optional — add only the fields you need:
# updated: YYYY-MM-DD
# requires: [N]
# supersedes: [N]
# superseded-by: N
# extended-by: [N, M]
# see-also: [N, M]
# implemented-in: vX.Y.Z
# discussion-at: <URL>
---

# GEP-NNNN: Title

<!--
  Template instructions (delete before merging):
  - Scale each section to its complexity. Short is fine.
  - Informational GEPs can skip Migration, Failure Modes, and Test Strategy.
  - The Decision Log is load-bearing — do not skip.
  - Once status flips to Accepted, the document is append-only. Edits
    that change a decision go in a new GEP that supersedes this one.
  - If this GEP extends or supersedes an existing one, update that
    GEP's frontmatter in the same PR (see GEP-1 §"Updating GEPs").
-->

## Problem

What's broken or missing today? One to three paragraphs.

## Goals

What does this proposal achieve? Bullet points.

## Non-goals

What does this proposal explicitly not do? Important for scope control.

## Design

Modules, data shapes, contracts, interfaces. For Informational GEPs,
this is the "what is" — the architecture or convention being
documented. For Standards GEPs, this is the proposed implementation
shape.

## Migration / rollout

How does this land without breaking existing users or code? Skip for
Informational GEPs that describe current state.

## Failure modes

What can go wrong, and how is it surfaced to the user/operator? Skip
for Informational GEPs.

## Test strategy

How is the implementation validated? Unit, integration, end-to-end.
Skip for Informational and Process GEPs.

## Open questions

Decisions deferred to implementation or future GEPs. Be honest — "we'll
figure this out" is better than pretending it's decided.

## Decision log

One entry per non-obvious design choice. Use `DX` (D1, D2, …) rather
than hierarchical numbering — easy to cite from later GEPs.

### D1. Short name of the decision

- **Decided:** what this GEP commits to.
- **Alternatives:** what else was considered (even if briefly).
- **Why:** one or two sentences on the reasoning.

### D2. ...

## Related

- Prior GEPs, archived notes, DESIGN.md sections, external references.
