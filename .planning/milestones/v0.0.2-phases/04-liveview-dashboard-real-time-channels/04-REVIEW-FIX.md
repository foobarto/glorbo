---
phase: 04-liveview-dashboard-real-time-channels
fixed_at: 2026-04-16T00:00:00Z
review_path: .planning/phases/04-liveview-dashboard-real-time-channels/04-REVIEW.md
iteration: 1
findings_in_scope: 8
fixed: 8
skipped: 0
status: all_fixed
---

# Phase 04: Code Review Fix Report

**Fixed at:** 2026-04-16
**Source review:** `.planning/phases/04-liveview-dashboard-real-time-channels/04-REVIEW.md`
**Iteration:** 1

**Summary:**
- Findings in scope: 8 (Critical + Warning — 0 criticals, 8 warnings)
- Fixed: 8
- Skipped: 0

All 8 Warning-severity findings fixed atomically. Full test suite (`mix test --stale`) passes: 498 tests, 0 failures, 43 excluded (integration/inotify tags not run in this iteration; all excluded tags match pre-fix CI exclusion policy). 6 Info-severity findings from REVIEW.md are out of scope (`fix_scope: critical_warning`) and were not addressed.

## Fixed Issues

### WR-01: HEEx interpolation bug — `#{@channel}` renders as literal text

**Files modified:** `lib/glorbo_web/live/channel_live.ex`
**Commit:** 3c2c2ac
**Applied fix:** Rewrote the two non-attribute HEEx body interpolations (heading on line 96, empty-state paragraph on line 104) from the Elixir-string-interpolation form `#{@channel}` to the HEEx-compatible form `{"##{@channel}"}` — building the string in an EEx expression so `#` is a literal prefix and `@channel` is interpolated once. The attribute-form `placeholder={"Message ##{@channel} as Director…"}` on line 116 was intentionally left unchanged: HEEx attribute expressions evaluate Elixir string interpolation, so the original is correct there.

### WR-02: LiveView mounts do not validate slug shape before filesystem reads

**Files modified:** `lib/glorbo_web/slug.ex` (new), `lib/glorbo_web/live/overview_live.ex`, `lib/glorbo_web/live/company_live.ex`, `lib/glorbo_web/live/kanban_live.ex`, `lib/glorbo_web/live/agent_live.ex`, `lib/glorbo_web/live/channel_live.ex`, `lib/glorbo_web/live/approval_queue_live.ex`, `lib/glorbo_web/live/audit_live.ex`
**Commit:** d4dfb4c
**Applied fix:** Extracted the slug regex (`~r/\A[a-z0-9-]+\z/`, same as `GlorboWeb.Actions.@slug_re`) into a shared `GlorboWeb.Slug.valid?/1` helper. Added a `valid?` gate to every LV `mount/3` that accepts `:company`, `:agent`, or `:channel` params, *before* any `Path.join`/`File.dir?`/`File.read` call. Invalid company slug → flash "Invalid company identifier." + `push_navigate(to: ~p"/companies")`. Invalid agent/channel slug (when company is valid) → flash + redirect to the parent company view. OverviewLive takes no slug params so the guard is a documented no-op. Closes T-04-08 read-path side-channel; writes were already gated by `Actions`.

### WR-03: `AuditLive` row-expansion IDs collide across filter/poll refreshes

**Files modified:** `lib/glorbo_web/live/audit_live.ex`
**Commit:** 75b9b05
**Applied fix:** Replaced the render-order `"audit-#{idx}"` key with a stable `entry_id/2` helper that SHA-256-hashes the tuple `(ts, actor, action, target)` from the audit entry and takes the first 16 url-safe base64 bytes. Falls back to `"audit-#{idx}"` only when every stable field is empty (defensive — shouldn't occur for well-formed JSONL rows). Polls and filter changes no longer drift expansion state to adjacent rows.

**Status:** fixed: requires human verification (logic change). The index-to-hash rebind is mechanical but the reviewer should sanity-check that audit expansion survives a filter change + a 1 s poll tick under manual smoke. Existing `audit_live_test.exs` (3 tests) continues to pass; no test covers the expansion-drift scenario directly, so behavior under real-time drift is only regression-asserted by the filter tests passing.

### WR-04: Runtime config falls back to a deterministic `secret_key_base` derived from `$HOME`

**Files modified:** `config/runtime.exs`
**Commit:** 78fdf51
**Applied fix:** Removed the `:crypto.hash(:sha256, $HOME)` derivation. Replaced with an ephemeral `:crypto.strong_rand_bytes(64) |> Base.url_encode64()` generated in-memory only (not persisted to config.md — sessions die on restart, adequate entropy). Failure of `Glorbo.Config.load/0` now emits `Logger.error` with the inspected reason so ops notice session invalidation. No fallback that leaks $HOME-derived entropy remains.

### WR-05: `wake_agent` reason is unbounded and incompletely YAML-escaped

**Files modified:** `lib/glorbo_web/actions.ex`
**Commit:** f5de75e (combined with WR-06)
**Applied fix:** Added `@reason_max_bytes 500` module attribute, a `validate_reason/1` guard (`is_binary` + byte_size check), and a local `yaml_scalar/1` function matching `Glorbo.TaskDefinition.yaml_scalar/1` semantics — quotes the value when it contains YAML-ambiguous chars / reserved words / control bytes, escapes `\`, `"`, `\n`, `\r`, `\t`, and strips any remaining control bytes to keep the emitted scalar single-line. The frontmatter emitter now uses `reason: #{yaml_scalar(reason)}` (no longer hard-codes the wrapping quotes) so simple values stay unquoted matching `TaskDefinition` and ambiguous values are safely escaped.

### WR-06: `Actions.wake_agent/3` calls `mkdir_p!` before the write-try block

**Files modified:** `lib/glorbo_web/actions.ex`
**Commit:** f5de75e (combined with WR-05)
**Applied fix:** Moved `dir = Path.join(...)` and `File.mkdir_p(dir)` (non-bang) into the `with` chain so a `{:error, :eacces | :enospc | ...}` from the kernel now flows back through the function's documented `:ok | {:error, term()}` contract instead of raising. AgentLive's `handle_event("wake", ...)` now surfaces such failures as flash messages rather than crashing the LiveView.

### WR-07: `assets/js/app.js` null-dereferences the CSRF meta tag

**Files modified:** `assets/js/app.js`
**Commit:** 51137be
**Applied fix:** Hoisted the `querySelector` result into a `csrfMeta` const, null-checked before calling `getAttribute`, and emits a `console.error` when the meta is absent. LiveSocket boots with an empty token in that edge case — the server rejects on CSRF check with a legible error instead of killing the whole dashboard JS bundle with an uncaught `TypeError`.

### WR-08: Director action error messages leak low-level atoms to the UI

**Files modified:** `lib/glorbo_web/live/channel_live.ex`, `lib/glorbo_web/live/agent_live.ex`, `lib/glorbo_web/live/approval_queue_live.ex`
**Commit:** 083c808
**Applied fix:** Replaced every `put_flash(socket, :error, "... #{inspect(err)}")` in the action-error branches with a generic user-facing string ("Could not post message.", "Could not wake agent.", "Could not record approval.") plus a `Logger.warning/2` that records the raw reason + structured context (company, channel/agent/task_path). Added `require Logger` at the top of each affected LV. Pre-existing named-atom branches (`:empty_body`, `:body_too_large`) remain as specific user-facing messages since those are not information-disclosure risks.

---

_Fixed: 2026-04-16_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
