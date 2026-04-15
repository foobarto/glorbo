---
phase: 2
slug: filesystem-foundation-container-runtime-local-llm
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-15
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ExUnit (Elixir) — established in Phase 1 |
| **Config file** | `test/test_helper.exs`, `config/test.exs` |
| **Quick run command** | `mix test --stale` |
| **Full suite command** | `mix test` |
| **Estimated runtime** | ~15s quick, ~60s full (container-gated tests add ~30s when enabled) |

Container/Ollama integration tests are gated behind `@tag :podman` and `@tag :ollama` — excluded by default, included by `mix test --include podman` on dev hosts with rootless Podman + kernel support.

---

## Sampling Rate

- **After every task commit:** `mix test --stale`
- **After every plan wave:** `mix test` (host-only tests)
- **Before `/gsd-verify-work`:** `mix test --include podman --include ollama` must be green on a Fedora-like dev host
- **Max feedback latency:** 60 seconds (host-only); 120 seconds (with container tags)

---

## Per-Task Verification Map

_Populated by gsd-planner. Each PLAN.md task must add a row here or reference an existing row. Planner populates Task ID, Plan, Wave, Requirement, Test Type, and Automated Command; gsd-executor flips Status as tasks complete._

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `test/support/tmp_glorbo_home.ex` — ExUnit helper that creates an isolated `~/.glorbo/`-shaped tree under `System.tmp_dir!()` for filesystem tests (keeps tests hermetic; avoids touching real `$HOME`)
- [ ] `test/support/podman_case.ex` — test case template with `@moduletag :podman` and a fixture that skips gracefully when `podman` or user namespaces are unavailable
- [ ] `test/support/ollama_case.ex` — test case template with `@moduletag :ollama`; fixture skips when `~/.glorbo/bin/ollama` is absent

*All three helpers follow the `.ex`-under-`test/support/` convention established by Phase 1 Plan 01 (decision row in STATE.md).*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Airplane-mode Ollama inference | Success Criterion #6 | Requires operator to physically disable networking (`nmcli radio all off` or unplug) — cannot be reliably simulated inside CI | Run `glorbo init` on a connected host, then disable all network, then run the documented `glorbo llm ping` (or equivalent) command; assert a non-empty completion is returned in under 10s |
| `glorbo init` on a fresh Fedora-like host completes in ~1 minute (Success Criterion #1) | CLI-02, RT-01..06 | First-run behavior depends on host state (no `~/.glorbo/`, no podman, no ollama) — automated test can simulate but cannot prove "fresh host" | Document `podman system reset && rm -rf ~/.glorbo && time glorbo init` as the acceptance ritual; record timing in phase SUMMARY.md |
| SELinux/AppArmor label interaction with bind mounts (`:Z`) | RT-03 | Behavior differs across Fedora Silverblue, Ubuntu, RHEL; ExUnit cannot assert enforcement context | Doctor check reports the active LSM; operator verifies labels on a Silverblue host as part of phase sign-off |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags (no `--watch`, no `mix test.watch`)
- [ ] Feedback latency < 120s with container tags
- [ ] `nyquist_compliant: true` set in frontmatter
- [ ] All 6 Success Criteria from ROADMAP.md are mapped to at least one row in the Per-Task Verification Map or the Manual-Only table

**Approval:** pending
