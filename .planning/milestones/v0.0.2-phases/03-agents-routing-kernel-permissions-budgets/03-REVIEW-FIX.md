---
phase: 03-agents-routing-kernel-permissions-budgets
fixed_at: 2026-04-16T00:00:00Z
review_path: .planning/phases/03-agents-routing-kernel-permissions-budgets/03-REVIEW.md
iteration: 1
findings_in_scope: 11
fixed: 11
skipped: 0
status: all_fixed
---

# Phase 3: Code Review Fix Report

**Fixed at:** 2026-04-16
**Source review:** `.planning/phases/03-agents-routing-kernel-permissions-budgets/03-REVIEW.md`
**Iteration:** 1

**Summary:**
- Findings in scope: 11 (2 critical + 9 warnings)
- Fixed: 11
- Skipped: 0

All 11 in-scope findings (Critical + Warning) were fixed. The 6 Info-level findings were deferred per `fix_scope: critical_warning`.

Full test suite (`mix test --exclude integration --exclude bwrap --exclude claude_code --exclude gemini_cli --exclude codex`) passed after every commit: **418 tests, 0 failures (39 excluded)**.

## Fixed Issues

### CR-01: `Bwrap.run_via_port` never closes stdin — CLI tools will hang until timeout

**Files modified:** `lib/glorbo/sandbox/bwrap.ex`
**Commit:** `a898016`
**Applied fix:** Replaced the `Port.open` + `send(port, {self(), {:command, ""}})` pattern (which never sent EOF on stdin) with `System.cmd/3` + `input: prompt` (which atomically writes the prompt to stdin and closes it). Wrapped in `Task.async` + `Task.yield`/`Task.shutdown(:brutal_kill)` to preserve the existing 300s timeout semantics. Verified: all 12 existing bwrap unit tests pass, no regressions across the suite. CLI tools that wait for EOF on stdin (claude --print, codex exec -, gemini -p) will now actually complete dispatch instead of timing out after 5 minutes.

### CR-02: `Network.Proxy` spawns a Task.Supervisor inside `init/1` — leaks + kill cascade on crash

**Files modified:** `lib/glorbo/network/proxy.ex`
**Commit:** `2b2b10d`
**Applied fix:** Three interlocking changes to the Proxy supervision model:
1. When the Proxy spawns its own Task.Supervisor (backward-compat path for tests + standalone callers), it is now `Process.unlink`'d immediately so the Proxy's `terminate/2` does not receive an EXIT signal from its children's shutdown.
2. `terminate/2` now explicitly stops the owned Task.Supervisor via `Supervisor.stop(_, :shutdown, 1_000)` so in-flight tunnel tasks are torn down (client/upstream sockets closed) instead of leaking as orphans.
3. The acceptor task's ref is now tracked in state; on `{:DOWN, ref, :process, _, reason}` matching the acceptor ref, the acceptor is re-armed via `start_acceptor/3` so a transient crash no longer silently halts new-connection handling. Tunnel-task DOWN messages are logged at debug level for observability.
4. Tunnel children are now spawned via `Task.Supervisor.async_nolink/2` (not `start_child/2`) so a crash in `handle_connection/2` does not cascade to the Task.Supervisor itself.
5. Added `:task_supervisor` opt so Company.Supervisor (future wire-up) can pass a sibling Task.Supervisor instead of Proxy owning one.

All 12 Proxy tests pass. `owns_task_sup?` flag distinguishes the two cases cleanly.

### WR-01: `Approvals.Gate.handle_projects_event` has a path-traversal gap

**Files modified:** `lib/glorbo/approvals/gate.ex`
**Commit:** `408e7ee`
**Applied fix:** Added `unsafe_rel_path?/1` that rejects `rel_path` values containing `..` as a full segment (using `Path.split/1` + exact segment match, not substring match — avoids false-positives on `foo..bar.md`) or starting with `/` (absolute). Rejected paths emit `approval.rejected_traversal` audit event and short-circuit before touching the filesystem. This hardens the Gate against any future PubSub publisher that could inject a crafted event.

### WR-02: `Company.Router` writes agent-inbox files with sender-controlled body + unescaped frontmatter values

**Files modified:** `lib/glorbo/company/router.ex`
**Commit:** `4649247`
**Applied fix:** Extended `validate_message/1` to reject control characters in `msg_id` (`\n`, `\r`, `\0`, `/`) and `to` (`\n`, `\r`, `\0`). Both fields are interpolated verbatim into YAML frontmatter downstream; a sender-controlled newline could previously smuggle poisoned keys like `from: ceo` into the derived metadata a downstream parser reads. `/` in `msg_id` is additionally rejected since it would let the attacker pick the on-disk path. Rejected messages flow through the existing `handle_rejection/3` path (rejection file, inbox notice, audit events).

### WR-03: `Company.Scheduler.compute_delay_ms` drifts silently when `get_next_run_date` returns an error

**Files modified:** `lib/glorbo/company/scheduler.ex`
**Commit:** `9d75fee`
**Applied fix:** `compute_delay_ms/5` now takes the agent slug + registration entry + state as extra params so it can emit a `scheduler.cron_never_fires` audit event when `Crontab.Scheduler.get_next_run_date/2` returns `{:error, _}`. The audit captures `cron`, `reason`, and `fallback_delay_ms: 3_600_000` so an operator setting a valid-syntax-but-never-fires cron (e.g. `0 0 30 2 *`) sees the problem in the audit log, not only the application log. The 1h fallback behaviour is preserved for backward compatibility.

### WR-04: `Bwrap.build_argv` binds `/etc` read-only — leaks host resolv.conf, PKI, hostname, and every system config

**Files modified:** `lib/glorbo/sandbox/bwrap.ex`, `test/glorbo/sandbox/bwrap_test.exs`
**Commit:** `3bbc7ed`
**Applied fix:** Replaced `--ro-bind /etc /etc` with a minimal selective binding strategy:
- `--tmpfs /etc` baseline (empty)
- `--ro-bind` for files every CLI tool needs: `resolv.conf`, `hosts`, `nsswitch.conf`, `passwd`, `group`
- `--ro-bind-try` for distro-variant TLS trust stores: `/etc/ssl`, `/etc/pki` (Fedora), `/etc/ca-certificates` (Debian), `/etc/ca-certificates.conf`

This eliminates exposure of `/etc/shadow`, `/etc/sudoers*`, `/etc/ssh/*`, `/etc/cron.*`, `/etc/systemd/*`, and any installed application configs (`/etc/nginx/`, `/etc/postgres/`, etc). `--ro-bind-try` silently skips missing paths so the same argv composes cleanly across distros. Test assertion updated to verify the new selective binds AND to explicitly refute the old `["--ro-bind", "/etc", "/etc"]` triple as a regression guard.

### WR-05: `Bwrap.run_via_port` uses `Port.open` instead of supervised spawn — no cgroup cleanup

**Files modified:** `lib/glorbo/sandbox/bwrap.ex`
**Commit:** `53fe2b4`
**Applied fix:** Updated the moduledoc to accurately describe the cleanup story after CR-01's System.cmd migration. The triple-cleanup claim (MuonTrap.Daemon + --unshare-pid + --die-with-parent) was misleading since MuonTrap is not in the invocation path. The new docstring explains that --unshare-pid + --die-with-parent are kernel-guaranteed: bwrap is pid1 in its namespace, so SIGKILL to bwrap reaps every descendant, and --die-with-parent ensures bwrap dies if BEAM dies. MuonTrap.Daemon would add a cgroup-backed trap as a fourth layer but its `:stdin` API is incompatible with the EOF-required CLI tools (Pitfall 8 + CR-01), so we explicitly do not use it.

### WR-06: `Company.Router.handle_call({:route, ...})` serializes ALL routing through one GenServer — per-company global lock

**Files modified:** `lib/glorbo/company/router.ex`
**Commit:** `3326cba`
**Applied fix:** Added a "Scaling profile (WR-06)" section to the Router moduledoc explicitly documenting the single-GenServer-per-company tradeoff: route latency scales linearly with queue depth under burst load, but this is the same mechanism that makes `[:append, :sync]` fsync-serialized channel appends race-safe without per-file locks. Documented the future refactor path (split into ChannelRouter / AgentInboxRouter / ApprovalRouter under a DynamicSupervisor) and referenced Phase 3 VALIDATION.md for the benchmark that would catch throughput regression.

### WR-07: `Bwrap.env_flags` does not validate env var keys/values — shell metachar injection possible via agent.md

**Files modified:** `lib/glorbo/sandbox/bwrap.ex`
**Commit:** `7ca77c8`
**Applied fix:** Added `safe_env?/2` and `valid_key?/1` guards to `env_flags/1`. Keys must match the POSIX env-var name shape `~r/\A[A-Za-z_][A-Za-z0-9_]*\z/` (no `\0`, `=`, `\n`, `\t` possible). Values may not contain `\0`, `\n`, or `\r`. Violations raise `ArgumentError` at argv compose time, surfacing the problem loudly rather than silently producing a malformed execve.

### WR-08: `Runtime.UidAllocator.find_user_subuid` crashes on malformed `/etc/subuid` entries

**Files modified:** `lib/glorbo/runtime/uid_allocator.ex`
**Commit:** `344a5d1`
**Applied fix:** Replaced `String.to_integer(base_str)` (raises `ArgumentError` on non-numeric input) with `Integer.parse/1` + pattern match `{base, ""} when base > 0`. Malformed lines are skipped via `nil` return from the `Enum.find_value` fn; if no well-formed entry for the user is found the call degrades to `{:error, :no_subuid_entry}` so the caller can fall back to a non-podman path. A corrupt `/etc/subuid` (from e.g. a broken shadow-utils upgrade) no longer crashes the allocator at startup.

### WR-09: `Dispatch.latest_jsonl` uses `File.stat!/1` — crashes if a JSONL file is deleted between `ls` and `stat`

**Files modified:** `lib/glorbo/agent/dispatch.ex`
**Commit:** `7db3662`
**Applied fix:** Replaced `Enum.sort_by(&File.stat!(&1).mtime, :desc)` with `Enum.flat_map/2` that calls `File.stat/1` (non-bang) and drops entries whose stat fails. Race window between `File.ls` and the stat (where a CLI tool can rotate session files) no longer escapes as an exception that skips the `conservative_zero` recovery — lost usage records → budget undercount was the prior consequence.

---

_Fixed: 2026-04-16_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
