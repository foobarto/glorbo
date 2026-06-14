---
gep: 59
title: hwfit — native hardware→model fit scoring, the missing local-readiness step
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
implemented-in: v0.27.0
type: Standards
created: 2026-06-12
see-also: [8, 11, 32]
extended-by: [67]
history:
  - date: 2026-06-12
    status: Placeholder
    note: |
      Parked from the 2026-06-12 odysseus cross-pollination review. Re-implements
      odysseus's Cookbook/hwfit (services/hwfit/fit.py) in pure Elixir, embedded,
      to close glorbo's "fully local out of the box" gap.
  - date: 2026-06-12
    status: Draft
    note: |
      Design resolved in brainstorm; SLATED FOR IMPLEMENTATION this cycle.
      D3 v1 scope = scorer + `glorbo fit` RECOMMEND only; the `--serve` path
      (download/serve/auto-enable) is fully designed but DEFERRED, so glorbo
      takes on no inference-engine process-management burden yet. D4 catalog =
      static in-binary for v1 (offline-true; online refresh deferred). D5 scoring
      = port the proven odysseus heuristics into a glorbo-maintained table.
  - date: 2026-06-14
    status: Implemented
    note: |
      Flipped to Implemented (v1). `glorbo fit` scorer + recommend ship
      (`lib/glorbo/fit.ex` + `lib/glorbo/fit/`); the `--serve` model-download
      path is deferred (tracked). Merged to main, [Unreleased];
      `implemented-in:` at the next release cut.
---

# GEP-59: hwfit — native hardware→model fit

## Problem

glorbo's orchestration substrate is fully local and offline-capable (sandbox,
dashboard, audit, router, scheduler, SQLite — `mix.exs` bundles no inference and
no cloud SDK). But the **LLM brain is bring-your-own, and the default isn't
local**: `glorbo init` scaffolds the `acme` CEO with `provider: claude-code,
network: proxy` (a cloud CLI). `glorbo detect-providers` only **probes localhost
for an already-running server** (`providers/detect.ex`) and `enable.ex` makes
**no network calls** — glorbo can *wire up* a local server you started yourself,
but nothing **helps you pick or get** a fitting model running.

So the "drop in and it works fully locally out of the box" promise holds for
everything *except* choosing and running a model — the manual step between a
fresh install and a self-contained local deployment. odysseus's Cookbook/hwfit
fills exactly this: scan hardware → recommend a GGUF/quant that fits VRAM/RAM at
a usable tok/s. Bringing the **scoring** in (natively, embedded) makes glorbo's
local-readiness story honest.

## Goals

- A **native, embedded, pure-Elixir** fit scorer: estimate memory per
  quant×context, blend GPU/system-RAM bandwidth into a tok/s estimate, score
  quality/speed/fit/context per use-case, and auto-downshift quant/context until
  it fits — no C-NIF (Burrito 4-target safe, GEP-53 D13 precedent).
- A `glorbo fit` command that **recommends** a model/quant for the detected
  hardware (v1), feeding budget governance and `model:`/`provider:` choices in
  `AGENT.md`.
- Fully design (but defer) the optional **serve** path so the local-readiness
  story is complete on paper.

## Non-goals

- **Not** embedded inference — glorbo does not bundle llama.cpp/ONNX; serving an
  engine stays an external subprocess (muontrap), consistent with the CLI-tool /
  sandbox model (GEP-4/5).
- Does not auto-install host GPU runtimes or edit host config silently.
- Does not replace `detect-providers` (GEP-8) — it precedes it.
- **v1 does not serve or download models** (D3) — recommend only.

## Design

### v1 scope: scorer + recommend (D3)

`Glorbo.Fit` = **pure-Elixir scoring** + a **host probe**, exposed as
`glorbo fit`:

- **Scoring (pure Elixir, embeddable, no NIF):** memory estimate per
  quant×context; bandwidth-blended tok/s; quality/speed/fit/context scores per
  use-case; quant-downshift search until a candidate fits. All
  arithmetic/heuristics — unit-testable against fixtures.
- **Host probe:** read `/proc/meminfo` + `nvidia-smi` / `rocm-smi` (Linux) and
  `sysctl` (macOS) via muontrap to get RAM/VRAM/bandwidth. Probe failures
  degrade to RAM-only scoring, never crash.
- **`glorbo fit`** prints a ranked recommendation (model, quant, est. tok/s, fit
  margin) and the `AGENT.md` `model:`/`provider:` lines to use. `--host <remote>`
  scores a remote box's reported hardware.

The **`--serve` path** (download a GGUF over Finch, start llama.cpp/ollama via
muontrap, then `Providers.Enable` the detected endpoint, GEP-8) is fully
specified here but **deferred** — see D3. When it lands, the serve-engine
**ownership** question (glorbo-supervised lifecycle vs fire-and-hand-off to
`detect-providers`) is its own decision; v1 takes on neither.

### Model catalog (D4)

The quant/param tables + a curated model list ship **static in-binary** for v1:
offline-true, no network call to recommend. The data is a compiled-in module
(`@catalog`). An **optional online refresh** (fetch an updated catalog without
breaking the offline-first promise — explicit `glorbo fit --refresh-catalog`,
never automatic) is designed but deferred.

### Scoring fidelity (D5)

Port the **proven odysseus heuristics** (chip-specific bandwidth tables,
quant-size formulas, the bandwidth-blended tok/s model, quant-downshift) into a
**glorbo-maintained** table/module, rather than re-deriving from scratch. Start
from the battle-tested math; curate/trim the table to glorbo's needs over time.

## Decision log

### D1. Pure-Elixir scoring, no C-NIF *(settled)*
- **Decided:** the fit-scoring math is reimplemented in pure Elixir, embedded.
- **Alternatives:** vendor the Python `hwfit` and shell out; a C-NIF port.
- **Why:** keeps the Burrito 4-target cross-build clean (GEP-53 D13 precedent)
  and the single binary dependency-free.

### D2. Serving stays a subprocess, not embedded inference *(settled)*
- **Decided:** fit *scoring* embeds; *serving* a model is an external engine
  subprocess (muontrap), never bundled inference.
- **Why:** consistent with glorbo's CLI-tool/sandbox model (GEP-4/5); avoids a
  multi-hundred-MB inference stack in the binary.

### D3. v1 = scorer + recommend; serve deferred *(settled)*
- **Decided:** implement the scorer + host probe + `glorbo fit` (recommend).
  The `--serve` download/serve/auto-enable path is designed but not built in v1.
- **Alternatives:** scorer + serve with glorbo owning the engine lifecycle
  (glorbo becomes a process manager — real supervision/serve-quirk surface);
  scorer + serve fire-and-hand-off (operator owns the process).
- **Why:** the scorer is the clean, fully-testable, self-contained win and the
  honest first step; serving adds OS-specific lifecycle weight that should be its
  own deliberate increment.

### D4. Catalog = static in-binary for v1 *(settled)*
- **Decided:** quant/param tables + curated model list ship compiled-in;
  recommendation needs no network. Explicit opt-in online refresh deferred.
- **Why:** offline-first (GEP-11); a stale-but-present catalog beats a network
  dependency for the core recommend path.

### D5. Scoring = port the odysseus heuristics *(settled)*
- **Decided:** port the proven odysseus fit math into a glorbo-maintained table,
  not a from-scratch re-derivation.
- **Why:** start from battle-tested heuristics; curate over time.

## Migration

None required — additive:

- **New CLI + module only** — `glorbo fit` and `Glorbo.Fit` (+ the compiled-in
  catalog). No change to `~/.glorbo/companies/`, the SQLite schema, or any
  existing command; no `glorbo reindex`.
- **Precedes `detect-providers`** (GEP-8) — it does not alter it. An operator
  runs `glorbo fit` to choose a model, starts it themselves (v1), then
  `detect-providers` + `enable` wires it as today.
- **Forward-only** — pre-1.0, no back-compat shim; the catalog is compiled in.

## Related

- GEP-8 provider registry + auto-detect (the step hwfit precedes) ·
  GEP-32 native harness · GEP-11 Zen of Glorbo (boring/local first) ·
  GEP-4/5 CLI-tool agents + sandboxing (subprocess model) ·
  GEP-53 D13 (pure-Elixir / Burrito constraint precedent) · GEP-58 (a local
  embedder is one model hwfit can help run).
- Prior art: odysseus `services/hwfit/fit.py` + `hardware.py` (fit scoring,
  bandwidth-blended tok/s, quant-downshift) and the Cookbook serve flow.
