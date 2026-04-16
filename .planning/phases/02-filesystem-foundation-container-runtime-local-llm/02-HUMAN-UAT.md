---
status: partial
phase: 02-filesystem-foundation-container-runtime-local-llm
source: [02-VERIFICATION.md]
started: 2026-04-16T00:12:00Z
updated: 2026-04-16T00:12:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Fresh-host `glorbo init` timing + hierarchy proof (Success Criterion #1, CLI-02)

test: Run `./glorbo init` on a fresh Fedora-like host (or `rm -rf ~/.glorbo && podman image rm ghcr.io/foobarto/glorbo-runtime:latest`, then `time ./_build/dev/rel/glorbo/bin/glorbo init`).
expected: Wall-clock ≤ 90s; 7 step lines with ✓/⏭/✗ icons; `cat ~/.glorbo/audit/_system/*.jsonl | wc -l` returns 7; idempotent rerun ≤ 5s with most steps ⏭; exit code 0 or 2 (never 1). `tree -L 3 ~/.glorbo/` matches DESIGN.md §3 and `companies/acme/agents/ceo/agent.md` is populated with CEO frontmatter.
result: [pending]

### 2. Airplane-mode LLM-05 proof (Success Criterion #6)

test: `OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve &`, `ollama pull llama3.2:1b`, then `mix test test/integration/airplane_mode_test.exs --include airplane --include integration --include podman --include ollama` with host networking cut.
expected: Test passes. `resp["ok"] == true`, `resp["result"]["completion"]` is a non-empty string. Wall-clock after container start ≤ 10s. Q-A3 disposition recorded (ollama-python / litellm unix:// worked OR httpx-UDS shim fallback was required).
result: [pending]

## Summary

total: 2
passed: 0
issues: 0
pending: 2
skipped: 0
blocked: 0

## Gaps
