---
phase: 02-filesystem-foundation-container-runtime-local-llm
fixed_at: 2026-04-16T00:00:00Z
review_path: .planning/phases/02-filesystem-foundation-container-runtime-local-llm/02-REVIEW.md
iteration: 1
findings_in_scope: 23
fixed: 22
skipped: 1
status: partial
---

# Phase 2: Code Review Fix Report

**Fixed at:** 2026-04-16T00:00:00Z
**Source review:** `.planning/phases/02-filesystem-foundation-container-runtime-local-llm/02-REVIEW.md`
**Iteration:** 1

**Summary:**
- Findings in scope (critical + warning): 23
- Fixed: 22
- Skipped: 1

All 158 existing unit tests continued to pass after every fix. `mix compile --warnings-as-errors` is clean. Integration tests (`:inotify`, `:integration`) remain excluded by tag and were not exercised.

## Fixed Issues

### CR-01: Reindex silently creates orphan Agent rows when `company.md` is missing

**Files modified:** `lib/glorbo/filesystem/reindex.ex`
**Commit:** `c3ef646`
**Applied fix:** Group files by company directory prefix and skip any sub-tree lacking a `company.md` with a warning; within-group ordering keeps `company.md` ahead of its agents.

### CR-02: AuditLog month-bucket uses local-date conversion, not UTC

**Files modified:** `lib/glorbo/company/audit_log.ex`
**Commit:** `ca313f5`
**Applied fix:** Normalise the entry timestamp in `entry_ts/1` — any non-UTC `%DateTime{}` is shifted to `Etc/UTC` up-front, so both the JSONL `ts` field and the monthly bucket filename derive from the same UTC view.

### CR-03: Container launch races stale container with same name

**Files modified:** `lib/glorbo/container_manager.ex`, `lib/glorbo/application.ex`
**Commit:** `aae0367`
**Applied fix:** Added `pre_clean_container/2` — a best-effort `podman rm -f glorbo-<company>-<agent>` invoked before each `start_container` launches, clearing residual metadata from a SIGKILLed prior run.

### CR-04: Persistent container Daemon unsupervised — violates crash isolation

**Files modified:** `lib/glorbo/container_manager.ex`, `lib/glorbo/application.ex`
**Commit:** `aae0367`
**Applied fix:** Added `Glorbo.Container.DaemonSupervisor` (DynamicSupervisor) to the app tree; `launch(:persistent, ...)` now starts each `MuonTrap.Daemon` under the supervisor with `restart: :transient` and monitors the pid. A crashed Daemon no longer kills ContainerManager; `stop_container/1` terminates the Daemon child cleanly via `DynamicSupervisor.terminate_child/2`.

### CR-05: Worker /run double-wraps task in create_task + wait_for

**Files modified:** `containers/glorbo-runtime/worker/routes.py`
**Commit:** `4c2d8d8`
**Applied fix:** Reject duplicate `request_id` at the top of `/run`; switched to `asyncio.ensure_future` + `asyncio.shield(task)` inside `wait_for`, explicit `task.cancel()` on `TimeoutError` so `/cancel` can distinguish timeout vs cancel.

### CR-06: ContainerManager public API ignores configurable :name

**Files modified:** `lib/glorbo/container_manager.ex`
**Commit:** `aae0367`
**Applied fix:** Added `server \\ __MODULE__` first argument to `ensure_image/2`, `start_container/3`, and `stop_container/2`, routing the GenServer call through the caller-supplied server reference.

### CR-07: Worker dispatch may echo api_key to Elixir via litellm error

**Files modified:** `containers/glorbo-runtime/worker/routes.py`, `containers/glorbo-runtime/worker/main.py`
**Commit:** `4c2d8d8`
**Applied fix:** Added `_scrub(text, api_key)` helper invoked in the generic `except Exception` branch of `/run`; set `litellm.suppress_debug_info = True` and `litellm.set_verbose = False` in `main.py` at startup. D-37 key-safety surface is now covered on the error path, not just the happy path.

### WR-01: Frontmatter split breaks on CRLF line endings (worker)

**Files modified:** `containers/glorbo-runtime/worker/context.py`
**Commit:** `0f43b5d`
**Applied fix:** `_split_frontmatter` normalises `\r\n` to `\n` before the `startswith("---\n")` check and returns the normalised body so downstream consumers see consistent line endings.

### WR-02: Frontmatter parser inconsistent fence check (Elixir vs Python)

**Files modified:** `lib/glorbo/filesystem/frontmatter.ex`
**Commit:** `0f43b5d`
**Applied fix:** `parse/1` normalises CRLF and requires the strict `"---\n"` prefix (matching the Python worker). Previously `String.starts_with?(content, "---")` was lenient about what followed the dashes.

### WR-03: Reindex cleanup is O(N*3) per vanished file

**Files modified:** `lib/glorbo/filesystem/reindex.ex`
**Commit:** `a3ccd5b`
**Applied fix:** `cleanup_vanished/1` now issues three batched `delete_all` queries with `where: r.file_path in ^vanished` instead of 3N queries in a loop.

### WR-04: Doctor probe files race under concurrent invocations

**Files modified:** `lib/glorbo/doctor.ex`
**Commit:** `a3ccd5b`
**Applied fix:** `.doctor_probe` filename now carries `System.unique_integer([:positive])` suffix in all three check sites (`check_glorbo_dir`, `check_audit_dir`, `check_sockets_dir`), eliminating the probe-name collision between concurrent doctors.

### WR-05: Orchestrator bootstrap failures bypass continue-on-error (D-20)

**Files modified:** `lib/glorbo/init/orchestrator.ex`
**Commit:** `c36d977`
**Applied fix:** Extracted pipeline steps into `run_pipeline/1`; `bootstrap/1` wraps the pre-pipeline `Hierarchy.ensure!/1` + `start_audit_log/1` in a try/rescue and returns a synthesised `{:error, summary}` with an `:hierarchy` failure record if either raises.

### WR-06: Application CLI halt uses unlinked Task

**Files modified:** `lib/glorbo/application.ex`
**Commit:** `c36d977`
**Applied fix:** Replaced `Task.start(fn -> System.halt(code) end)` with `:timer.apply_after(0, :erlang, :halt, [code])` — no extra process, more deterministic scheduling.

### WR-07: Watcher pending-timer map unbounded

**Files modified:** `lib/glorbo/filesystem/watcher.ex`
**Commit:** `2fe6316`
**Applied fix:** Added `@max_pending 10_000` cap; events for new paths above the cap are dropped with a warning rather than grown unboundedly. Re-registering timers for already-tracked paths stays permitted so burst-coalesce still works.

### WR-08: ImagePull default `image_cached?/1` hits real podman

**Files modified:** `lib/glorbo/init/image_pull.ex`
**Commit:** `98de1c6`
**Applied fix:** `run/1` now raises `ArgumentError` if one of `:ensure_image_fun` / `:image_cached_fun` is supplied without its partner — tests that want hermetic behaviour must pair the two stubs.

### WR-09: `combine/1` loses :downloaded info on mixed error+success

**Files modified:** `lib/glorbo/init/orchestrator.ex`
**Commit:** `00a59f4`
**Applied fix:** The error branch of `combine/1` now surfaces a `downloaded:` list alongside `errors:`, with the detail string reporting both. Operators no longer see a blanket "had errors" that hides partial installs.

### WR-10: AuditLog atom/string key collision is implementation-defined

**Files modified:** `lib/glorbo/company/audit_log.ex`
**Commit:** `698f7a6`
**Applied fix:** `handle_call/3` calls a new `normalize_entry/1` that stringifies every key up-front; the downstream helpers (`entry_ts`, `entry_company`, `drop_known_keys`) now read a single string-keyed taxonomy.

### WR-11: Dispatch model-string logic mis-routes slashed Ollama tags

**Files modified:** `containers/glorbo-runtime/worker/dispatch.py`
**Commit:** `80e1090`
**Applied fix:** Introduced `_KNOWN_PROVIDER_PREFIXES` allow-list. `model_str` is left as-is only when the model already starts with one of those prefixes; everything else (including `hf.co/user/model` for Ollama) still gets the `{provider}/` prefix so litellm routes correctly.

### WR-13: Formatter version captured at compile time

**Files modified:** `lib/glorbo/doctor/formatter.ex`
**Commit:** `5226768`
**Applied fix:** Replaced the `@version` module attribute with a `version/0` private function that reads `Application.spec(:glorbo, :vsn)` at runtime — a release upgrade now reports the new version.

### WR-14: Reindex MD5 computation lacks size cap

**Files modified:** `lib/glorbo/filesystem/reindex.ex`
**Commit:** `7686b43`
**Applied fix:** `process_file/1` stats first and skips files over `@max_file_bytes` (10 MB — matches Frontmatter's cap). Added `{:skip, :too_large}` and `{:skip, {:stat_failed, reason}}` returns.

### WR-15: Watcher does not monitor FileSystem subprocess

**Files modified:** `lib/glorbo/filesystem/watcher.ex`
**Commit:** `2fe6316`
**Applied fix:** `init/1` now `Process.monitor/1`s the FileSystem pid and stores the ref in state; a matching `handle_info({:DOWN, ref, :process, pid, reason}, ...)` logs the failure and stops the watcher so the operator sees "watcher died" rather than silent inotify-watch-limit idle.

### WR-16: Worker _live_tasks is process-global — incompatible with multi-worker uvicorn

**Files modified:** `containers/glorbo-runtime/worker/main.py`
**Commit:** `cf94379`
**Applied fix:** Startup assertion in `main.py`: `int(os.getenv("WEB_CONCURRENCY", "1")) == 1`. Catches any future refactor that would silently add `--workers N` and break `/cancel` routing.

### IN-11 + IN-14 (bonus): domain variable names + openapi_url=None

**Files modified:** `lib/glorbo/init/orchestrator.ex`, `containers/glorbo-runtime/worker/main.py`
**Commits:** `00a59f4`, `4c2d8d8`
**Applied fix:** Bundled into the nearest warning commits — renamed `or_` to `ollama_result` and disabled `/openapi.json` alongside the docs URLs.

## Skipped Issues

### WR-12: BinaryBootstrap tar extraction lacks explicit absolute-path + owner flags

**File:** `lib/glorbo/init/binary_bootstrap.ex:134, 157`
**Reason:** skipped: fix caused errors, rolled back. The suggested `--no-absolute-names` / `--no-same-owner` flags are GNU-tar-only; the project's system tar (BSD tar on this host, and likely on macOS / some CI runners) rejects them with exit 64 "unrecognised option", breaking `binary_bootstrap_test.exs` deterministically. A correct fix would feature-detect tar vendor + version and conditionally emit the flags, which is out of scope for a single finding and the default GNU behaviour is already zip-slip-safe (mitigated further by the staging-dir pattern noted in the moduledoc). Recommend revisiting as a dedicated hardening ticket with a proper feature-detect helper.
**Original issue:** The suggestion was to make GNU-tar-safety flags explicit so a `$TAR_OPTIONS=-P` env leak or unusual tar build couldn't change extraction semantics.

---

_Fixed: 2026-04-16T00:00:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
