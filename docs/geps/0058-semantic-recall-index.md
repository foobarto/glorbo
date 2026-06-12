---
gep: 58
title: Semantic recall index — optional, unbundled vector layer over the home tree
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Placeholder
type: Standards
created: 2026-06-12
see-also: [7, 21, 34, 43]
history:
  - date: 2026-06-12
    status: Placeholder
    note: |
      Parked from the 2026-06-12 odysseus cross-pollination review. Extends
      file-based agent memory (GEP-21) with OPTIONAL semantic retrieval over the
      markdown home tree, modelled on odysseus's vector+keyword recall but kept
      out of the core Burrito binary. Design space NOT yet worked out; see Open
      questions.
---

# GEP-58: Semantic recall index

## Problem

Agent memory and company knowledge in glorbo are file-based (GEP-21): channels,
tasks, audit, memory, and skills are markdown/JSONL that agents reach by path
and keyword. That is grep-true and portable, but it has no **semantic** recall —
an agent cannot ask "what did we decide about X three months ago" and get the
relevant chunks unless it knows where to look. odysseus pairs a keyword store
with a local vector index (fastembed/ONNX) for exactly this. glorbo has no
equivalent, and naively adding one risks bloating the single-binary, lean,
pure-Elixir design (the Burrito 4-target cross-build rejects C-NIF deps — see
GEP-53 D13).

## Goals

- **Optional** semantic recall over the home tree, default **OFF**, **not
  bundled** into the core binary.
- A **rebuildable derived index** — never the source of truth (GEP-7); the
  markdown files stay authoritative and `glorbo reindex` (GEP-34) rebuilds it.
- **Hybrid** retrieval: keyword/grep stays the always-on path; semantic is an
  augmentation, never a replacement.

## Non-goals

- **No bundled inference** and no mandatory dependency — the lean binary stays
  lean.
- **Never** the source of truth — files remain authoritative; the index is
  disposable.
- Not a cross-company knowledge pool — must respect company isolation
  (`~/.glorbo/companies/<co>/`).
- No C-NIF embedder in the default build (Burrito constraint, GEP-53 D13).

## Design (sketch — to be worked out before Draft)

Keep embeddings **out of the core binary**. Two candidate sources, both
keeping the binary pure-Elixir: (a) call a **local embeddings endpoint** — the
operator's own ollama/llama.cpp/LM Studio `/v1/embeddings`, discovered like
other native providers (GEP-8) — over Finch; or (b) shell out to an optional
embedder sidecar via muontrap. Vectors land in a derived SQLite table
(`ecto_sqlite3`, already a dep) keyed by source path + chunk, rebuilt by
`glorbo reindex` (GEP-34) and optionally snapshot via ETS (GEP-43). CLI:
`glorbo memory index --enable` opts a company in.

## Open questions

*(load-bearing — these gate promotion to Draft)*

- **Embedder source:** local `/v1/embeddings` endpoint (zero extra deps, but
  requires a running server — ties into the GEP-59 hwfit local-readiness gap)
  vs. an optional sidecar. Which is canonical?
- **Storage:** SQLite derived table vs. ETS snapshot (GEP-43) vs. a flat file —
  what survives `reindex` cleanly and stays grep-adjacent?
- **Scope/isolation:** per-company indexes only; how to guarantee no
  cross-company bleed at query time?
- **When to embed:** on write (inotify-triggered) vs. lazily at `reindex` —
  cost vs. freshness.
- **Is it worth it** at all, given grep already covers most recall and adds
  zero deps? The bar for adding *any* optional dependency is high.

## Decision log

### D1. Optional, unbundled, default-off *(settled)*
- **Decided:** semantic recall is an opt-in feature that does not ship in or
  bloat the core binary; keyword/grep remains the default always-on path.
- **Alternatives:** bundle a vector store by default; replace keyword search.
- **Why:** preserves the lean single-binary, pure-Elixir, portable design;
  honours "boring/local first" (GEP-11).

### D2. Derived, rebuildable, never authoritative *(settled)*
- **Decided:** the index is derived state rebuilt by `glorbo reindex` (GEP-34);
  the markdown files are the source of truth (GEP-7).
- **Why:** a corrupt or stale index must be a `reindex` away from correct, never
  a data-loss risk.

### D3. Embedder source + storage substrate
- *To be captured during the brainstorm that takes this GEP to Draft* (see
  Open questions).

## Related

- GEP-21 file-based agent memory · GEP-7 SQLite as derived data ·
  GEP-34 reindex v2 · GEP-43 ETS-first derived state · GEP-8 provider
  auto-detect (local `/v1/embeddings`) · GEP-11 Zen of Glorbo ·
  GEP-53 D13 (pure-Elixir / Burrito constraint precedent).
- Prior art: odysseus `src/memory_vector.py` (Chroma + fastembed, vector +
  keyword hybrid).
