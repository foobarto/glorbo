# Session 2026-06-16 — GEP reconciliation pickup

## Task picked

Resume abandoned-agent WIP on `main` (mixed doc reconciliation + L78 prep).

**Mode:** Bugfix + docs.

## What shipped

### L45 / v0.28.2 (prior session, already on main)

Not redone — see `docs/sessions/2026-06-15-codex-genuine-open-queue.md`.

### L78 — dispatcher ANSI DoS (PR #85)

- `Dispatcher.strip_ansi/1` + `StdoutStreamer` delegate to
  `Glorbo.Terminal.Sanitizer` (linear scan).
- Regression test for 100k unterminated `\e]`.
- `mix precommit` green.

### Docs reconciliation (this PR)

- `docs/architecture.md` — GEP-50/35 notes; GEP-67 section corrected
  (phases 1–3 shipped, not "dead code").
- `docs/DESIGN.md` — GEP-67 supervision tree + dependency table aligned.
- `docs/state.md` — stronger superseded warning.
- `docs/sessions/2026-06-14-gep-codebase-reconciliation.md` — tracked
  (gap report from prior multi-agent sweep).

**Dropped from abandoned WIP:**

- `scripts/gep_sync_checker.exs` — redundant with `mix gep.validate`
  README↔frontmatter status check.
- `config/test.exs` `:ansi_enabled` — unrelated to shipped fixes.

## Gates

- L78: precommit 3386 pass.

## Task: v0.28.3 release cut (2026-06-18)

**What shipped:** PR [#87](https://github.com/foobarto/glorbo/pull/87) folded
#83–#86 + earmark→MDEx migration → `49b166dc`; tag `v0.28.3` pushed.

**Commit(s):** squash on main `49b166dc`; tag `v0.28.3`

---

## Task: codex L94 — memory frontmatter scalar guard

**Task picked:** Reject YAML mappings/sequences in memory `name`/`description`/`type` before write; harden read paths.

**What shipped:** Router `check_memory_scalar_fields/1`; `memory_index_scalar/2` in index upsert; `memory_display_scalar/2` in AgentLive memory tab. Regression tests in `router_memory_scalar_test.exs` + `agent_live_test.exs`.

**Gates:** `mix precommit` green (3388 pass).

**Commit(s):** (pending)

---

## Things I'd like your review

- Release workflow for `v0.28.3` (binaries + tap).
- PR for L94 → merge → v0.28.4 PATCH if `[Unreleased]` ready.
