---
phase: 5
slug: cli-completeness-backup-restore-portability
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-16
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ExUnit (Elixir built-in) + `Port.open` harness for subprocess / burrito binary tests |
| **Config file** | `test/test_helper.exs`, `mix.exs` `aliases` |
| **Quick run command** | `mix test --stale` |
| **Full suite command** | `mix test --include integration` |
| **Estimated runtime** | ~15 seconds (unit), ~45 seconds (with portability + up/down integration) |

---

## Sampling Rate

- **After every task commit:** `mix test --stale`
- **After every plan wave:** `mix test --include integration`
- **Before `/gsd-verify-work`:** Full suite green + a live smoke test of `./glorbo up → glorbo status → glorbo down` against the rebuilt burrito binary
- **Max feedback latency:** 60 seconds full suite

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 5-01-* | 01 (scaffolding) | 0 | CLI-01 | — | Every verb stub returns `{verb_atom, 1, help_text}` for unimplemented paths | unit | `mix test test/glorbo/cli/ test/glorbo/config_test.exs` | ❌ W0 creates | ⬜ pending |
| 5-02-* | 02 (lifecycle + scaffolding verbs) | 1 | CLI-01 | T-05-01 | Pidfile 0644; path traversal rejected in `new company/agent/project` slugs | unit + integration | `mix test test/glorbo/cli/ test/integration/up_down_status_test.exs` | ❌ W0 creates | ⬜ pending |
| 5-03-* | 03 (backup/restore + doctor --fix + console + portability) | 1 | CLI-01, CLI-03 | T-05-02, T-05-03 | `:erl_tar.extract` traversal pre-check; WAL checkpoint fails closed; cookie 0600 | unit + integration | `mix test test/glorbo/cli/ test/integration/backup_restore_roundtrip_test.exs test/integration/portability_test.exs` | ❌ W0 creates | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

*Exact task IDs and threat refs will be finalized by the planner in `/gsd-plan-phase`. Rows above reflect the 3-plan / 2-wave shape from RESEARCH.md §Plan Decomposition.*

---

## Wave 0 Requirements

- [ ] `test/glorbo/cli/up_test.exs` — `{:up, exit_code, out}` happy/missing/already-running paths
- [ ] `test/glorbo/cli/down_test.exs` — `{:down, exit_code, out}` happy/no-pidfile/stale-pidfile
- [ ] `test/glorbo/cli/status_test.exs`
- [ ] `test/glorbo/cli/backup_test.exs` — stubbed Backup.run returning tuple; full-path test lands in Plan 03
- [ ] `test/glorbo/cli/restore_test.exs`
- [ ] `test/glorbo/cli/doctor_fix_test.exs`
- [ ] `test/glorbo/cli/console_test.exs`
- [ ] `test/glorbo/cli/new_company_test.exs`, `new_agent_test.exs`, `new_project_test.exs`
- [ ] `test/glorbo/cli/logs_test.exs`, `migrate_test.exs`, `run_test.exs`, `serve_test.exs`
- [ ] `test/support/cli_case.ex` — shared harness (isolated `~/.glorbo` per test via `GLORBO_HOME` override)
- [ ] `test/support/portability_fixtures.ex` — acme stage helpers for portability_test
- [ ] `test/integration/up_down_status_test.exs`, `backup_restore_roundtrip_test.exs`, `portability_test.exs` — all Plan 02/03 integration stubs scaffolded

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Cross-host portability: machine A → `scp` → machine B → `restore` → `up` | CLI-03 | Requires two machines (or two VMs) with SSH; cannot be hermetically scripted in CI | Backup on host A; scp to host B with only the glorbo binary; restore + doctor --fix + up; open dashboard; verify ceo agent can dispatch a task |
| `glorbo console` remote shell | CLI-01 | Requires `glorbo up` in another terminal, distribution actually wired (cookie+sname). LV-test cannot verify remsh. | In terminal 1: `./glorbo up`. In terminal 2: `./glorbo console`. Execute `Glorbo.Doctor.run_checks()` in the remsh; verify same data as main node |
| `glorbo serve` + browser UAT | UI-01 (phase 4 UAT already captures this) | Browser verification | Covered by phase 4's UAT bundle |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references above
- [ ] No watch-mode flags
- [ ] Feedback latency <60 s full suite
- [ ] `nyquist_compliant: true` set in frontmatter after planner finalises task IDs

**Approval:** pending (planner fills task IDs, then executor marks `nyquist_compliant: true` after Wave 0 lands)
