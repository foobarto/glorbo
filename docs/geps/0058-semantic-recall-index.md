---
gep: 58
title: Semantic recall index — optional hybrid keyword+vector retrieval over the home tree
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Draft
type: Standards
created: 2026-06-12
see-also: [7, 8, 21, 34, 43]
history:
  - date: 2026-06-12
    status: Placeholder
    note: |
      Parked from the 2026-06-12 odysseus cross-pollination review. Extends
      file-based agent memory (GEP-21) with OPTIONAL semantic retrieval over the
      markdown home tree, modelled on odysseus's vector+keyword recall but kept
      out of the core Burrito binary.
  - date: 2026-06-12
    status: Draft
    note: |
      Designed fully in brainstorm; implementation DEFERRED until there is
      demand (this is design-complete, not built this cycle). Operator steer:
      "elasticsearch-like" — a real HYBRID retrieval model, not a bolt-on vector
      store. D3 = SQLite FTS5 (keyword/BM25) + pure-Elixir dense-vector re-rank
      over the FTS5 candidate set + reciprocal-rank fusion; no `sqlite-vec` C-NIF
      (Burrito constraint, GEP-53 D13). D4 embedder = local `/v1/embeddings`
      (GEP-8 discovery) with a sidecar alternative. D5 lazy embed at reindex v1.
---

# GEP-58: Semantic recall index

## Problem

Agent memory and company knowledge in glorbo are file-based (GEP-21): channels,
tasks, audit, memory, and skills are markdown/JSONL that agents reach by path
and keyword. That is grep-true and portable, but it has no **semantic** recall —
an agent cannot ask "what did we decide about X three months ago" and surface
the relevant chunks unless it knows the words to grep for. odysseus pairs a
keyword store with a local vector index for exactly this. glorbo has no
equivalent, and naively adding one risks bloating the single-binary, lean,
pure-Elixir design (the Burrito 4-target cross-build rejects C-NIF deps —
GEP-53 D13).

## Goals

- **Optional** semantic recall over the home tree, default **OFF**, **not
  bundled** into the core binary.
- A **hybrid** retrieval model (elasticsearch-style): keyword recall stays the
  always-on path; dense-vector similarity *augments* and re-ranks it — never
  replaces it.
- A **rebuildable derived index** — never the source of truth (GEP-7); the
  markdown files stay authoritative and `glorbo reindex` (GEP-34) rebuilds it.
- Stay **pure-Elixir / Burrito-clean** — no C-NIF embedder or vector extension
  in the default build.

## Non-goals

- **No bundled inference** and no mandatory dependency — the lean binary stays
  lean; semantic recall is strictly opt-in.
- **Never** the source of truth — files remain authoritative; the index is
  disposable.
- Not a cross-company knowledge pool — strict company isolation
  (`~/.glorbo/companies/<co>/`).
- **No `sqlite-vec` / fastembed / ONNX C-NIF** in the default build (Burrito
  constraint, GEP-53 D13).

## Design

### Hybrid retrieval (D3) — FTS5 + vector re-rank + RRF

Modelled on elasticsearch's hybrid search, within glorbo's pure-Elixir/SQLite
constraints:

1. **Keyword (always-on):** SQLite **FTS5** (built into SQLite; `ecto_sqlite3`
   already a dep — no new dependency) gives BM25-ranked full-text recall over
   the chunked home tree. This is the floor; it works with the semantic layer
   off.
2. **Vector (augmentation):** chunk embeddings are stored as BLOBs in a derived
   SQLite table. At query time the FTS5 keyword pass **narrows to a candidate
   set** (top-K), then a **pure-Elixir cosine** re-rank scores those candidates
   against the query embedding. Cosine runs only over the K FTS5 candidates, not
   the whole corpus — so no vector index extension (no C-NIF) is needed and the
   cost is bounded.
3. **Fusion:** **reciprocal-rank fusion (RRF)** combines the FTS5 rank and the
   vector-cosine rank into the final ordering — pure arithmetic, embeddable.

Keyword-only is the default; turning on the semantic layer adds the vector
re-rank + RRF on top. Grep/keyword recall is never removed.

### Embedder source (D4)

Embeddings come from a **local `/v1/embeddings` endpoint** — the operator's own
ollama / llama.cpp / LM Studio server, discovered like any native provider
(GEP-8) and called over Finch. Zero extra binary dependencies, offline-capable,
and it ties into the GEP-59 local-readiness story (get a model — including an
embedder — running locally). A muontrap **sidecar embedder** is the documented
alternative for operators who want embeddings without a running endpoint;
either way nothing C-NIF lands in the default build.

### Storage (D5)

A derived SQLite schema (`ecto_sqlite3`):

- an FTS5 virtual table over the chunked home tree (keyword), and
- a `chunk_vectors(source_path, chunk_id, embedding BLOB, model, dims)` table.

Both are **derived state**, keyed by source path + chunk, rebuilt by
`glorbo reindex` (GEP-34); the markdown files are authoritative (GEP-7). A
corrupt or stale index is a `reindex` away from correct, never a data-loss risk.
Optionally snapshot hot vectors via ETS (GEP-43).

### When to embed (D6)

**Lazy at `reindex`** for v1 (simplest; embeds the corpus when the operator
opts in / rebuilds). **On-write** (inotify-triggered incremental embedding) is
the freshness optimization, deferred.

### Isolation

Per-company indexes only: the FTS5 + vector tables live under the company's
derived store, and every query is scoped to the calling company. No cross-company
table is ever queried — company isolation is absolute (a load-bearing
invariant), enforced at query construction, not by filtering after the fact.

### CLI

`glorbo memory index --enable` opts a company into the semantic layer (builds
the vector table on the next reindex); `--disable` drops the derived vector
table (keyword/FTS5 stays). Default is off.

## Decision log

### D1. Optional, unbundled, default-off *(settled)*
- **Decided:** opt-in feature that does not ship in or bloat the core binary;
  keyword/FTS5 remains the always-on default.
- **Why:** preserves the lean single-binary, pure-Elixir, portable design;
  honours "boring/local first" (GEP-11).

### D2. Derived, rebuildable, never authoritative *(settled)*
- **Decided:** the index is derived state rebuilt by `glorbo reindex` (GEP-34);
  the markdown files are the source of truth (GEP-7).
- **Why:** a corrupt/stale index must be a `reindex` away from correct.

### D3. Hybrid = FTS5 keyword + pure-Elixir vector re-rank + RRF *(settled)*
- **Decided:** elasticsearch-style hybrid: FTS5 (BM25) narrows candidates,
  pure-Elixir cosine re-ranks the candidate set, RRF fuses the two rankings.
- **Alternatives:** a `sqlite-vec`/fastembed/ONNX vector index (C-NIF — breaks
  Burrito, GEP-53 D13); replacing keyword search with vectors (loses the
  always-on grep floor).
- **Why:** delivers semantic recall while staying pure-Elixir/SQLite — cosine
  over an FTS5-narrowed candidate set is bounded and needs no native extension.

### D4. Embedder = local `/v1/embeddings`, sidecar alternative *(settled)*
- **Decided:** embeddings from a local `/v1/embeddings` endpoint (GEP-8
  discovery, Finch); muontrap sidecar as the documented alternative.
- **Why:** zero extra binary deps, offline-capable, ties into GEP-59.

### D5. Storage = derived SQLite (FTS5 + vector BLOB table) *(settled)*
- **Decided:** FTS5 virtual table + `chunk_vectors` BLOB table in the company's
  derived store; rebuilt by reindex.
- **Why:** reuses the existing SQLite dep; stays grep-adjacent + rebuildable.

### D6. Lazy embed at reindex for v1 *(settled)*
- **Decided:** embed lazily on reindex/opt-in; on-write incremental embedding is
  a deferred freshness optimization.

## Migration

None required — additive, opt-in, default-off:

- **No change to authoritative files or the existing keyword path** — the
  semantic layer is purely additive; with it off, behaviour is identical to
  today. Keyword/FTS5 recall is the always-on floor.
- **Derived, rebuildable** — enabling builds the vector table on the next
  `glorbo reindex`; disabling drops it. No data migration, no on-disk format
  change to `~/.glorbo/companies/`.
- **Implementation deferred** — this GEP is design-complete (Accepted quality)
  but not built this cycle; nothing ships until demand justifies the opt-in
  dependency surface.

## Related

- GEP-21 file-based agent memory · GEP-7 SQLite as derived data ·
  GEP-34 reindex v2 · GEP-43 ETS-first derived state · GEP-8 provider
  auto-detect (local `/v1/embeddings`) · GEP-11 Zen of Glorbo ·
  GEP-53 D13 (pure-Elixir / Burrito constraint precedent) · GEP-59 hwfit
  (local embedder readiness).
- Prior art: odysseus `src/memory_vector.py` (Chroma + fastembed, vector +
  keyword hybrid).

## Implementation reconciliation (2026-06-14)

This is an append-only record. Per GEP-1, an Accepted/Implemented GEP's body is not rewritten — the body above reflects design-time intent, and any divergence from the shipped code is captured here.

- **GEPs README lists 0058 as "Draft" while the feature is shipped** — *as-shipped (body/index stale).* The GEP frontmatter (`status: Draft`, line 5) and Migration section ("Implementation deferred… not built this cycle", lines 176-178) both claim the feature is design-complete-but-unbuilt; the code contradicts this. The semantic recall index is fully implemented: migration `priv/repo/migrations/20260612120000_create_memory_index.exs`, the `lib/glorbo/memory/` tree (`index.ex`, `chunk_vector.ex`, `vector.ex`, `embedder.ex`, `chunker.ex`), CLI wiring (`lib/glorbo/cli.ex:484-491,628-661` — `glorbo memory index <company> --enable|--disable`), reindex wiring (`lib/glorbo/filesystem/reindex.ex:119-124`, the `:memory_index_opts` D6 lazy-embed path), and tests (`test/glorbo/memory/{index,vector,embedder}_test.exs`) — all landed in commit `4c4a9ce` ("feat(geps): implement GEPs 0056-0059"). The README index row at `docs/geps/README.md:84` reads `Draft`, whereas every comparably-shipped GEP in the same table uses `Implemented` (e.g. lines 29-47). Disposition: flip the GEP-0058 frontmatter to `Implemented` and the README row from `Draft` to `Implemented` in one change so the index, the frontmatter, and the shipped code all agree; the design body stays as-is per GEP-1.
