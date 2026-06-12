---
gep: 59
title: hwfit — native hardware→model fit scoring, the missing local-readiness step
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Placeholder
type: Standards
created: 2026-06-12
see-also: [8, 11, 32]
history:
  - date: 2026-06-12
    status: Placeholder
    note: |
      Parked from the 2026-06-12 odysseus cross-pollination review. Re-implements
      odysseus's Cookbook/hwfit (services/hwfit/fit.py) in pure Elixir, embedded,
      to close glorbo's "fully local out of the box" gap: today detect-providers
      only WIRES an already-running server; nothing helps you GET a fitting model
      running. Design space NOT yet worked out; see Open questions.
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
but nothing **downloads or serves** a model.

So the original "drop in and it works fully locally out of the box" promise
holds for everything *except* getting a model running — the one manual step
between a fresh install and a self-contained local deployment. odysseus's
Cookbook/hwfit fills exactly this: scan hardware → recommend a GGUF/quant that
fits VRAM/RAM at a usable tok/s → serve it. Bringing that in (natively, embedded)
makes glorbo genuinely turnkey-local.

## Goals

- A **native, embedded** fit scorer: estimate memory per quant×context, blend
  GPU/system-RAM bandwidth into a tok/s estimate, score quality/speed/fit/context
  per use-case, and auto-downshift quant/context until it fits — ported to **pure
  Elixir** (no C-NIF; Burrito 4-target safe, GEP-53 D13 precedent).
- Close the local-readiness gap: `glorbo fit` recommends, and (optionally)
  downloads + serves + auto-`enable`s a local provider (GEP-8).
- Feed **budget governance** — recommend the cheapest model that clears a role's
  bar, wiring `model:`/`provider:` into `AGENT.md`.

## Non-goals

- **Not** embedded inference — glorbo does not bundle llama.cpp/ONNX; serving an
  engine stays an external subprocess (muontrap), consistent with the CLI-tool /
  sandbox model (GEP-4/5).
- Does not auto-install host GPU runtimes or edit `.env`-style host config
  silently.
- Does not replace `detect-providers` (GEP-8) — it precedes it (get a model
  running, then detect/enable it).

## Design (sketch — to be worked out before Draft)

A `Glorbo.Fit` module = **pure-Elixir scoring** (the fit math: memory estimate,
bandwidth-blended tok/s, quality/speed/fit/context scores, quant-downshift
search — all arithmetic/heuristics, embeddable, no NIF) + a **host probe**
(read `/proc`, `nvidia-smi`/`rocm-smi`/`sysctl` via muontrap) + an **optional
serve path** (download a GGUF from HF over Finch, serve via llama.cpp/ollama
subprocess, then `Providers.Enable` the detected endpoint, GEP-8). CLI:
`glorbo fit [--serve] [--host <remote>]`. The model/quant metadata catalog ships
as static data in-binary.

## Open questions

*(load-bearing — these gate promotion to Draft)*

- **Model catalog freshness:** the quant/param tables + HF model list — ship
  static in-binary (offline-true but staleness) vs. optional online refresh? How
  to refresh without breaking the offline-first promise?
- **Scoring fidelity:** the odysseus heuristics encode chip-specific bandwidth
  tables (Apple Silicon, etc.) — port verbatim, or re-derive a smaller
  glorbo-maintained table?
- **Serve engine ownership:** does glorbo manage the llama.cpp/ollama lifecycle
  (start/stop/health under the daemon) or just kick it off and hand to
  `detect-providers`?
- **Sandbox interaction:** the host probe + serve subprocess run on the host,
  not inside an agent sandbox — confirm that's the right trust placement.

## Decision log

### D1. Pure-Elixir scoring, no C-NIF *(settled)*
- **Decided:** the fit-scoring math is reimplemented in pure Elixir and embedded
  in the binary.
- **Alternatives:** vendor the Python `hwfit` and shell out; a C-NIF port.
- **Why:** keeps the Burrito 4-target cross-build clean (precedent: GEP-53 D13
  rejected argon2's C NIF for the same reason) and the single binary
  dependency-free.

### D2. Serving stays a subprocess, not embedded inference *(settled)*
- **Decided:** the fit *scoring* embeds; *serving* a model is an external engine
  subprocess (muontrap), not bundled inference.
- **Why:** consistent with glorbo's CLI-tool/sandbox model (GEP-4/5); avoids
  pulling a multi-hundred-MB inference stack into the binary.

### D3. Model catalog freshness + serve-engine lifecycle
- *To be captured during the brainstorm that takes this GEP to Draft* (see
  Open questions).

## Related

- GEP-8 provider registry + auto-detect (the step hwfit precedes) ·
  GEP-32 native harness · GEP-11 Zen of Glorbo (boring/local first) ·
  GEP-4/5 CLI-tool agents + sandboxing (subprocess model) ·
  GEP-53 D13 (pure-Elixir / Burrito constraint precedent).
- Prior art: odysseus `services/hwfit/fit.py` + `hardware.py` (fit scoring,
  bandwidth-blended tok/s, quant-downshift) and the Cookbook serve flow.
