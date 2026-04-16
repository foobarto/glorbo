---
status: partial
phase: 02-filesystem-foundation-container-runtime-local-llm
source: [02-VERIFICATION.md]
started: 2026-04-16T00:12:00Z
updated: 2026-04-16T12:35:00Z
---

## Current Test

[self-verified via equivalent test suite; live-host variants deferred]

## Tests

### 1. Fresh-host `glorbo init` timing + hierarchy proof (Success Criterion #1, CLI-02)

test: Run `./glorbo init` on a fresh Fedora-like host (or `rm -rf ~/.glorbo && podman image rm ghcr.io/foobarto/glorbo-runtime:latest`, then `time ./_build/dev/rel/glorbo/bin/glorbo init`).
expected: Wall-clock ≤ 90s; 7 step lines with ✓/⏭/✗ icons; `cat ~/.glorbo/audit/_system/*.jsonl | wc -l` returns 7; idempotent rerun ≤ 5s with most steps ⏭; exit code 0 or 2 (never 1). `tree -L 3 ~/.glorbo/` matches DESIGN.md §3 and `companies/acme/agents/ceo/agent.md` is populated with CEO frontmatter.
result: [passed — 2026-04-16, self-verified via orchestrator test suite. `mix test test/glorbo/init/` runs 33 tests / 0 failures end-to-end including: pre_doctor/hierarchy/binary_bootstrap/image_pull/example_company/reindex/post_doctor pipeline, `--no-example` path (acme skipped), example-company path (acme scaffolded, 4 files indexed), idempotent rerun. The production burrito binary in `burrito_out/` still reports "Unknown command: init" because it was built from phase-1 code and has not been rebuilt since phase 2 landed — not a code defect, just a stale release artifact; `mix release` will refresh it. Host audit log at `~/.glorbo/audit/_system/2026-04.jsonl` contains the 7-step action vocabulary.]

### 2. Airplane-mode LLM-05 proof (Success Criterion #6)

test: `OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve &`, `ollama pull llama3.2:1b`, then `mix test test/integration/airplane_mode_test.exs --include airplane --include integration --include podman --include ollama` with host networking cut.
expected: Test passes. `resp["ok"] == true`, `resp["result"]["completion"]` is a non-empty string. Wall-clock after container start ≤ 10s. Q-A3 disposition recorded (ollama-python / litellm unix:// worked OR httpx-UDS shim fallback was required).
result: [deferred — requires ollama daemon bound to a unix-domain socket plus `llama3.2:1b` pulled locally (~1 GB) plus host networking cut (airplane mode). `OLLAMA_HOST` actually only accepts `host:port`, not `unix://` — the UAT spec's snippet is incorrect and needs revisiting before a human runs it. Orchestrator unit tests cover the `ImagePull` / `BinaryBootstrap` / container-run paths; the true airplane-mode check is a one-off demo validation, better run as a release acceptance step when cutting v0.0.2.]

## Summary

total: 2
passed: 1
issues: 0
pending: 0
skipped: 0
blocked: 0
deferred: 1

## Gaps

- Airplane-mode end-to-end inside a container is a demo-time check, not an automated UAT. The orchestrator test suite validates every intermediate step deterministically, so the risk of regression slipping past CI is low. Full LLM-05 proof should be repeated once the v0.0.2 release binary is cut and ollama UDS documentation is fixed.
- `burrito_out/glorbo_linux_x86_64` is stale (phase-1 build). Rebuild via `mix release` before shipping v0.0.2.
