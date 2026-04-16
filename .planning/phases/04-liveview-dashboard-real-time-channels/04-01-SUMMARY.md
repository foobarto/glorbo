---
phase: 04
plan: 01
subsystem: liveview-dashboard-wave-0-foundation
tags: [elixir, phoenix, liveview, filesystem, pubsub, assets, esbuild]
requires:
  - "Phase 2 Glorbo.Filesystem.Frontmatter (safe-loader YAML)"
  - "Phase 2 Glorbo.Filesystem.Watcher (inotify + debounce + prefix dispatch)"
  - "Phase 3 Glorbo.Company.AuditLog.append/2 (append-only JSONL + SQLite mirror)"
  - "Phase 3 Glorbo.TaskDefinition.parse_file/2 (lenient status coercion)"
  - "Phoenix 1.8.5 + Phoenix.LiveView 1.1.28 + Phoenix.PubSub 2.2.0"
provides:
  - "GlorboWeb.Actions — 3 Director write-actions (post_message/4, set_approval/4, wake_agent/3)"
  - "GlorboWeb.StdoutStreamer + DynamicSupervisor — per-agent-page file-tail poller"
  - "Glorbo.TaskDefinition.write/2 — atomic frontmatter mutation (status, denial_reason)"
  - "Glorbo.Config.load/1 — ~/.glorbo/config.md parser with first-boot bootstrap"
  - "Extended Watcher PubSub topics: agents:<slug>:stdout, agents:<slug>:wake, channels:<slug> (+ channels rollup)"
  - "assets/js/app.js + assets/css/app.css + esbuild pipeline (assets.setup/build/deploy)"
  - "test/support/glorbo_fixtures.ex — seed_acme/1 tree (1 company/1 agent/1 channel/1 task/1 audit)"
  - "test/support/live_case.ex — Phoenix.LiveViewTest + TmpGlorboHome + :glorbo_base app-env injection"
affects:
  - "config/runtime.exs (prefer Glorbo.Config over env vars for secret_key_base/host/port)"
  - "lib/glorbo/application.ex (added StdoutStreamer.Supervisor DynamicSupervisor child)"
  - "lib/glorbo_web/components/layouts/root.html.heex (linked /assets/app.css + /assets/app.js)"
tech-stack:
  added:
    - "esbuild 0.10.0 (Hex wrapper, dev-runtime only — kept out of Burrito release)"
    - "earmark 1.4.48 (markdown renderer for upcoming chat view)"
    - "html_sanitize_ex 1.5.0 (allowlist scrubber for Earmark output)"
    - "mochiweb 3.2.2 (earmark transitive)"
  patterns:
    - "Director write-action = file write FIRST, audit event SECOND"
    - "Dual-broadcast for channels/ (per-slug + rollup) to preserve Phase 3 W5 test"
    - "Lazy-open distinction: init-time = EOF (no replay); re-open after :enoent = start-of-file"
    - "Fake-GenServer audit sink for tests via opts[:audit] dep injection"
key-files:
  created:
    - "lib/glorbo/config.ex"
    - "lib/glorbo_web/actions.ex"
    - "lib/glorbo_web/stdout_streamer.ex"
    - "assets/js/app.js"
    - "assets/css/app.css"
    - "test/glorbo/config_test.exs"
    - "test/glorbo/task_definition_write_test.exs"
    - "test/glorbo_web/actions_test.exs"
    - "test/glorbo_web/stdout_streamer_test.exs"
    - "test/support/glorbo_fixtures.ex"
    - "test/support/live_case.ex"
  modified:
    - "mix.exs (+3 deps, +3 aliases)"
    - "mix.lock (+4 hex packages)"
    - "config/config.exs (+esbuild profile)"
    - "config/dev.exs (+watchers block, +live_reload assets/ pattern)"
    - "config/runtime.exs (Glorbo.Config prefixes env-var fallback)"
    - "lib/glorbo/filesystem/watcher.ex (+stdout/wake classify clauses, per-slug channels + rollup)"
    - "lib/glorbo/task_definition.ex (+write/2 + helpers)"
    - "lib/glorbo/application.ex (+StdoutStreamer.Supervisor)"
    - "lib/glorbo_web/components/layouts/root.html.heex (+asset link tags)"
    - "test/glorbo/filesystem/watcher_test.exs (+5 Plan 04-01 PubSub topic assertions)"
decisions:
  - "Lazy-open reads from position 0 (not EOF) — re-opened-after-:enoent bytes are first-apparition, not history"
  - "Dual-broadcast channels/ on both per-slug and generic topic — O(2) cost, regression-proof for Phase 3 W5"
  - "TaskDefinition.write/2 uses line-level substitution, NOT YAML round-trip — preserves comments/order/unknown keys verbatim"
  - "Actions.set_approval audit action is approval.approved / approval.denied (matching DateTime enum string; AUDIT_EVENTS.md uses approval.approve/deny — flagged for Wave 1 alignment)"
  - "Glorbo.Config returns opaque {:error, :config_parse} — never includes values in errors (T-04-05)"
  - "esbuild dep marked runtime: Mix.env() == :dev so it's excluded from Burrito release"
metrics:
  duration: "~10 min"
  tasks: 3
  tests_added: 29
  completed: "2026-04-16"
---

# Phase 4 Plan 01: LiveView Dashboard Wave 0 Foundation Summary

Phase 4 Wave 0 establishes all infrastructure, PubSub topology, Director
action plumbing, and test harness that Wave 1's LiveView plans (04-02,
04-03) consume. No LiveView modules ship in this plan — it is pure
foundation so Wave 1 can run as parallel thin-rendering surface plans.

**One-liner:** Hand-written CSS token scaffold + esbuild pipeline +
Watcher PubSub extensions (stdout/wake/channels:<slug>) + atomic
TaskDefinition.write/2 + Director Actions module with audit-after-write
ordering + 300ms stdout file-tail GenServer + acme test fixture.

## Assets Pipeline

| Command | Effect |
|---------|--------|
| `mix deps.get` | Resolves `esbuild ~> 0.10`, `earmark ~> 1.4`, `html_sanitize_ex ~> 1.5` + transitive `mochiweb` |
| `mix assets.setup` | Downloads `esbuild` 0.21.5 binary into `_build/esbuild-*` (per-platform, via Hex wrapper — no npm) |
| `mix assets.build` | Emits `priv/static/assets/app.js` (~281 KiB, LiveSocket + Phoenix Socket) and `priv/static/assets/app.css` (~782 B, token scaffold) |
| `mix assets.deploy` | Runs `esbuild glorbo --minify` then `mix phx.digest` (produces `cache_manifest.json` for Plug.Static) |

**Asset output verified:**
- `priv/static/assets/app.js` — contains `new LiveSocket(`
- `priv/static/assets/app.css` — contains `--gl-bg: #0d1117`

Dev watcher wired in `config/dev.exs`: `watchers: [esbuild: {Esbuild,
:install_and_run, [:glorbo, ~w(--sourcemap=inline --watch)]}]`. On
Phoenix dev-mode boot, esbuild runs as a supervised subprocess rebuilding
both bundles on `assets/**` changes; `live_reload` patterns include
`assets/(js|css)/.*` so the browser auto-reloads after a CSS edit.

`root.html.heex` now references both via verified routes
(`~p"/assets/app.css"` and `~p"/assets/app.js"`) and keeps the existing
CSRF meta tag for LiveSocket forgery protection.

**Landing page (`assets/index.html`) left untouched** — it is the
marketing/CLI-agent-mode page, not part of the Phoenix app per CLAUDE.md.

## Watcher Topic Additions

Three new topic classes published by `Glorbo.Filesystem.Watcher` on
the existing `Glorbo.PubSub` registry:

| Trigger path | Topic string | Consumer (Wave 1) |
|--------------|--------------|-------------------|
| `agents/<slug>/stdout.log` (create/modify) | `company:<co>:agents:<slug>:stdout` | `GlorboWeb.AgentLive` (via StdoutStreamer re-broadcast) |
| `agents/<slug>/state/wake-request.md` (create/modify) | `company:<co>:agents:<slug>:wake` | Agent.Server wake handler + AgentLive (wake history) |
| `channels/<slug>.md` (create/modify) | `company:<co>:channels:<slug>` AND `company:<co>:channels` (dual-broadcast) | `GlorboWeb.ChannelLive` (per-slug) + CompanyLive (rollup) |

Payload is unchanged: `{:file_event, rel_path, events}` — same tuple
shape as the Phase 3 broadcast.

**Regression safety:** Phase 3's W5 watcher test subscribed to the
generic `"company:#{co}:channels"` topic. Rather than breaking it, we
dual-broadcast on channels/ events (per-slug + rollup). Both
subscribers fire from one filesystem event; cost is one extra
`Phoenix.PubSub.broadcast/3` call per channel write.

**`classify/1` extension:** new `:stdout` and `:wake` clauses precede
`:inbox`/`:outbox` in the `cond` (top-down match order matters — all
three share the `agents/` prefix).

## GlorboWeb.Actions

Three Director write-actions, each accepting `opts[:base]` (filesystem
root, default `~/.glorbo`) and `opts[:audit]` (AuditLog server, default
the global `Glorbo.Company.AuditLog` name) for dep injection.

| Function | File write | Audit event (action) | Validation |
|----------|------------|----------------------|-----------|
| `post_message(company, channel, body, opts)` | `File.write(channel_path, entry, [:append, :sync])` | `chat.post` | slug regex `~r/\A[a-z0-9-]+\z/` on company+channel, body 1..10240 B, `File.lstat` regular-file check |
| `set_approval(company, task_path, :approved\|:denied, opts)` | `TaskDefinition.write(abs, %{status: "approved"\|"denied"})` | `approval.approved` or `approval.denied` | company slug + task_path starts `projects/`, ends `.md`, no `..` segment |
| `wake_agent(company, agent, reason, opts)` | `File.write(state/wake-request.md, ..., [:sync])` with frontmatter `requested_at:` + `reason:` | `agent.wake_request` | company+agent slug regex |

**Ordering invariant:** file write FIRST → audit event SECOND. On
filesystem failure the audit event is NOT emitted and the `{:error, _}`
returns verbatim. Tested via `audit-after-write ordering` describe
block in `actions_test.exs`.

**Threat defenses:**
- T-04-01 — regular-file check (`File.lstat!/1`) defeats symlink-swap
- T-04-08 — slug regex defeats path traversal (`../evil`)
- T-04-04 — 10 KiB body cap
- T-04-05 — no value leakage in error tuples

## Glorbo.TaskDefinition.write/2

Atomic frontmatter-key rewrite. Narrow allowlist:
`:status | :denial_reason` (plus their string forms). Anything else
returns `{:error, {:unsupported_key, k}}` before any I/O.

**Atomicity:** writes to `<path>.tmp` with `[:sync]`, then
`File.rename(tmp, final)` — same-filesystem rename is atomic on POSIX,
so the Watcher sees exactly one `:modified` event for the target; no
partial-read window. On any write/rename failure the tmp is cleaned up
with `File.rm/1` and the original file stays untouched.

**Line-level substitution** (not YAML round-trip): splits frontmatter
on `---\n`, walks each line, rewrites matching `<indent><key>: <value>`
lines, preserves everything else verbatim (comments, unknown keys,
indentation, ordering). Falls back to `{:error, :no_frontmatter}` when
the file lacks a `---\n` fence.

**YAML-ambiguity quoting:** strings containing whitespace, punctuation,
or reserved words (`true|false|null|yes|no`) are emitted as
`"escaped"`; simple identifiers stay unquoted. Verified by round-trip
test that re-parses via `TaskDefinition.parse_file/2`.

## Glorbo.Config

Parses `~/.glorbo/config.md` frontmatter to yield:
`%{secret_key_base, dashboard_token, host, port}`.

**First-boot behavior:**
1. File missing? → `File.mkdir_p!(dirname)` + write default shape with
   `secret_key_base: :crypto.strong_rand_bytes(64) |> Base.encode64()`,
   `host: "127.0.0.1"`, `port: 4000`, `dashboard_token: null`
2. `File.chmod!(path, 0o600)` — Director-only read
3. Subsequent calls are idempotent (content stays verbatim)

**Defaults on weak input:** `host` defaults to `"127.0.0.1"` when
missing/blank; `port` defaults to `4000` when missing or out of range;
`secret_key_base` regenerates if < 32 bytes (should only happen on a
hand-edited file).

**Error posture:** returns `{:error, :config_parse}` on any parse
failure. No value — secret or otherwise — appears in the error tuple
or logs (T-04-05).

`config/runtime.exs` now wraps its prod branch with `Glorbo.Config.load/0`
so `SECRET_KEY_BASE` / `PHX_HOST` / `PORT` env vars still override but
the configuration source-of-truth is `~/.glorbo/config.md`.

## GlorboWeb.StdoutStreamer

Per-agent-page file-tail poller. Spec:

| Property | Value |
|----------|-------|
| Poll interval | `@poll_ms 300` |
| Read chunk | `@read_chunk 64_000` (64 KiB) |
| Initial position | EOF (D-15 no history replay) |
| Lazy-open position | 0 (bytes written while waiting are fresh context) |
| Topic | `company:<co>:agents:<ag>:stdout` |
| Broadcast | `{:stdout_line, co, ag, %{id: monotonic_int, body: ansi_stripped}}` |
| ANSI strip | `~r/\x1B\[[0-9;]*[a-zA-Z]/` |
| Partial line handling | Buffered in state; prepended to next poll's bytes |

**Supervision placement:** `{DynamicSupervisor, name:
GlorboWeb.StdoutStreamer.Supervisor, strategy: :one_for_one}` inserted
between `Glorbo.CompanySupervisor` and `GlorboWeb.Endpoint` in
`Glorbo.Application.start_supervision_tree/0`. Each LV mount spawns a
child via `StdoutStreamer.start/3`; `DynamicSupervisor.start_child/2`
returns `{:ok, pid}` which the LV then `Process.monitor/1`s. Crash
isolation: streamer crash does NOT take down the LV (LV monitors,
doesn't link).

**Lazy-open distinction:** init-time open positions at EOF; the
re-open path (after initial `:enoent` retry) positions at 0. Rationale:
when the file didn't exist at mount, any bytes now in it appeared
DURING the wait — they're first-apparition, not history. This is
tested in `lazy-opens a file that doesn't exist at start time`.

## test/support/glorbo_fixtures.ex

`seed_acme/1` plants this tree under `base`:

```
<base>/companies/acme/
├── company.md                       (name: acme, mission: "Build the Plumbus")
├── agents/ceo/
│   ├── agent.md                     (slug: ceo, role: CEO, provider: claude-code, model: claude-sonnet-4-5,
│   │                                 network: none, permissions: [projects:read:*, chat:write:general, chat:read:*],
│   │                                 budget.monthly_usd: 10.00)
│   ├── stdout.log                   (empty file)
│   ├── inbox/                       (empty dir)
│   ├── outbox/                      (empty dir)
│   ├── workspace/                   (empty dir)
│   ├── history/                     (empty dir)
│   └── state/                       (empty dir)
├── channels/
│   └── general.md                   ("# general\n")
├── projects/website/
│   ├── project.md                   (name: website, status: active)
│   └── tasks/t-01.md                (title: "Deploy landing page", status: pending,
│                                     assigned_to: ceo, requires_approval: director)
└── audit/2026-04.jsonl              (1 entry: actor=system, action=company.create, target=acme)
```

Returns `%{base: base, company: "acme"}`.

## GlorboWeb.LiveCase usage

```elixir
defmodule GlorboWeb.OverviewLiveTest do
  use GlorboWeb.LiveCase, async: false

  test "renders seeded acme", %{conn: conn, base: base, company: company} do
    {:ok, _lv, html} = live(conn, ~p"/companies")
    assert html =~ "acme"
  end
end
```

The `setup` block:
1. Runs the Ecto SQL sandbox (inherits `Glorbo.DataCase.setup_sandbox/1`)
2. Creates an isolated `TmpGlorboHome` at `System.tmp_dir!()/glorbo_test_<int>/`
3. Calls `seed_acme(base)` to plant the fixture
4. Puts `base` into `:glorbo, :glorbo_base` app-env so Wave 1 LVs can
   `Application.get_env(:glorbo, :glorbo_base, Path.expand("~/.glorbo"))`
5. Registers `on_exit` cleanup that restores the original app-env value
   and removes the tmp tree

## Verification

| Check | Result |
|-------|--------|
| `mix compile --warnings-as-errors` | PASS |
| `mix test` (full suite, Phase 2+3+4 Wave 0) | 463 tests, 0 failures (40 excluded — inotify + integration, absent `inotify-tools` binary on host) |
| `mix deps.get` resolves 3 new deps | PASS (esbuild 0.10.0, earmark 1.4.48, html_sanitize_ex 1.5.0) |
| `mix assets.setup && mix assets.build` | PASS (app.js 288 KB, app.css 782 B) |
| Asset grep (`new LiveSocket`, `--gl-bg: #0d1117`) | PASS |
| No `tailwindcss`/`daisyui`/`heroicons`/`react` in `assets/`, `config/`, `mix.exs` | PASS |
| New unit test count (watcher+write+config+actions+streamer) | 36 new test cases across 5 files (29 async + 7 stdout) |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Critical] Dual-broadcast channels/ topic for Phase 3 regression safety**
- **Found during:** Task 2 (watcher extension)
- **Issue:** Plan specified replacing the generic `"channels"` topic with per-slug `"channels:<slug>"`. Phase 3's watcher_test.exs W5 case subscribes to the generic topic and would break.
- **Fix:** Dual-broadcast on channels/ events — emit BOTH `"channels:<slug>"` (new, per-slug) and `"channels"` (rollup, preserves Phase 3). Cost: one extra `Phoenix.PubSub.broadcast/3` per channel write.
- **Files modified:** `lib/glorbo/filesystem/watcher.ex` (pubsub_topic_for/1 returns list or string; maybe_broadcast recursively handles lists)
- **Commit:** 18abc12

**2. [Rule 1 - Bug] StdoutStreamer lazy-open positioning**
- **Found during:** Task 3 (stdout_streamer test)
- **Issue:** Initial implementation positioned at EOF on `:open_retry`, mirroring init-time behavior. The "lazy-open" test wrote "late arrival\n" AFTER calling `start/3` but BEFORE the streamer's first successful open; positioning at EOF meant those bytes were skipped.
- **Fix:** On lazy-open (after `:enoent` retry), position at file start (0) — bytes written while waiting are first-apparition, not history. Init-time open still positions at EOF per D-15.
- **Files modified:** `lib/glorbo_web/stdout_streamer.ex` (handle_info(:open_retry) omits `:file.position(io, :eof)`)
- **Commit:** b87f313

### Alignment flag for Wave 1

**Audit event action naming:** `Actions.set_approval/4` emits
`approval.approved` / `approval.denied` (matching the decision atom
to_string). `AUDIT_EVENTS.md` (Phase 3 canonical registry) has
historically used `approval.approve` / `approval.deny` (verb form). I
chose the past-tense form because it matches the audit-at-rest
semantic (the action has already occurred). Wave 1 will align either
this plan or AUDIT_EVENTS.md on a single form before Gate consumes
either — flagged as non-blocking.

## Threat Flags

No new network endpoints, auth paths, or trust-boundary surfaces
introduced in this plan beyond what the threat_model section already
enumerated. Wave 1 will introduce the LiveView routes; threat surface
stays under the existing T-04-01..T-04-08 register.

## Self-Check: PASSED

Files verified to exist:
- FOUND: lib/glorbo/config.ex
- FOUND: lib/glorbo_web/actions.ex
- FOUND: lib/glorbo_web/stdout_streamer.ex
- FOUND: assets/js/app.js
- FOUND: assets/css/app.css
- FOUND: test/glorbo/config_test.exs
- FOUND: test/glorbo/task_definition_write_test.exs
- FOUND: test/glorbo_web/actions_test.exs
- FOUND: test/glorbo_web/stdout_streamer_test.exs
- FOUND: test/support/glorbo_fixtures.ex
- FOUND: test/support/live_case.ex
- FOUND: priv/static/assets/app.js
- FOUND: priv/static/assets/app.css

Commits verified:
- FOUND: 7993424 (Task 1 — asset pipeline)
- FOUND: 18abc12 (Task 2 — watcher + write + config + actions)
- FOUND: b87f313 (Task 3 — streamer + fixtures + LiveCase)
