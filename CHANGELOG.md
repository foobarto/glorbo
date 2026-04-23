# Changelog

All notable changes to Glorbo will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0 caveat: APIs, CLI flags, on-disk layout, and SQLite schema may
change between minor versions. Pin exact versions in downstream usage.

## [Unreleased]

### Security — round-3 hardening (host-write symlink defense)

Round-3 triage from the codex round-2 review. Symmetric to the
previous sweep's host-read symlink defense — every host write into
an agent-writable tree now `lstat`s before the write so a pre-planted
symlink can't turn a Director-initiated write into a confused-deputy
attack.

- **[HIGH fix]** `GlorboWeb.Actions.wake_agent/4` now guards
  `agents/<slug>/state/wake-request.md` with an lstat check before
  writing. Previously a malicious agent could plant a symlink at
  `wake-request.md` pointing at any host file the user could reach;
  the Director's next wake would write through it.
- **[HIGH fix]** `Glorbo.Approvals.Gate.write_sentinel/4` lstat-guards
  `agents/<slug>/state/awaiting-approval-<task>.md`. Same class —
  sentinel path sits in agent-writable `state/`.
- **[HIGH fix]** `Glorbo.Company.Router.handle_outbox_task/5`
  lstat-guards the **destination** task file
  (`projects/<p>/tasks/<id>.md`). A sender with `projects:write:*`
  RW-mounts the tree; without a dest-side guard the Router's
  `File.write` would follow a pre-planted symlink.
- **[MED fix]** `Glorbo.Filesystem.Reindex.cleanup_vanished/1` chunks
  its `WHERE file_path IN ^vanished` deletes at 500 per batch so a
  reindex that vanishes >999 paths no longer hits SQLite's default
  bind-parameter ceiling.

Two regression tests added (`wake_agent` refuse-symlink and
`R-outbox-dest-symlink`) to lock in the threat-model-M03 guarantees.

### Security — round-2 hardening (post-review-2 sweep)

- **[CRITICAL fix]** `AgentSupervisor` crash no longer permanently
  loses the company's agent fleet. Previously a bare `:one_for_one`
  `Company.Supervisor` + one-shot `:transient` `AgentBoot` meant the
  DynamicSupervisor would restart empty after a crash and `AgentBoot`
  never reran. Wrapped `[AgentSupervisor, AgentBoot]` in a new
  `agent_fleet` `:rest_for_one` sub-supervisor so an inner crash
  terminates both children and restarts them in order, repopulating
  the fleet. Regression test `S4: AgentSupervisor crash triggers
  AgentBoot rerun` covers the scenario; existing `S3` kept on the
  sibling-isolation path.
- **[HIGH fix]** `MCP.Tools.CreateProposal` and
  `MCP.Tools.DecideProposal` switched from bare `File.write/2` to
  `FrontmatterWriter.atomic_write/2`. A process crash mid-write no
  longer leaves a truncated proposal-outbox file that the Router
  would silently reject on parse.
- **[HIGH fix]** `GlorboWeb.MCP.Tools.CaptureBrainDump` now emits
  the `braindump.capture` audit event the moduledoc promised (actor
  `mcp:<client>`, matching `BrainDumpLive`'s audit path).
  Previously MCP-driven captures were invisible in the audit trail.
- **[HIGH fix]** `Plug.Parsers` baseline gained a 1 MiB
  `length:` cap. An unbounded MCP POST body could previously buffer
  a multi-gigabyte payload into the BEAM before any tool-layer
  size check fired. The new cap rejects oversize requests with
  `413 Request Entity Too Large` before the router runs.

### Security — post-review hardening sweep (codex + claude review)

- **[CRITICAL fix]** Router outbox readers now `lstat` every
  agent-writable file before `File.read`. Without this an agent
  could plant a symlink at `outbox/comments/<task>.md` pointing at
  arbitrary host files (e.g. `~/.ssh/id_rsa`) and the Router would
  ingest the target content into task comments, proposals, or
  memory. Fix: new `read_agent_writable_file/1` helper guards the
  task/comment/message/proposal/path-request/classification sites;
  regression test `R-outbox-symlink` added.
- **[HIGH fix]** bwrap baseline gains `--clearenv` + an explicit
  `--setenv` whitelist (`PATH`, `LANG`, `LC_ALL`, `TERM`, `TMPDIR`).
  Previously the sandboxed CLI inherited the BEAM's environment,
  including any `*_PROXY` / provider tokens in the director's
  shell. New test B11 asserts `--clearenv` precedes every
  `--setenv`.
- **[HIGH fix]** Dropped `--unshare-user-try` / `--unshare-cgroup-try`
  silent fallbacks in favour of the bare `--unshare-user` /
  `--unshare-cgroup`. Every supported kernel implements both
  namespaces; the `-try` suffix converted a kernel boundary into a
  best-effort one.
- **[HIGH fix]** `GlorboWeb.AgentLive` + `GlorboWeb.CompanyLive`
  now pin Registry lookups to `{:agent_server, company, slug}`
  instead of the cross-company `{:agent_server, :_, slug}`
  wildcard. Two companies with an agent of the same slug (e.g.
  both have `ceo`) previously surfaced whichever registered
  first.
- **[HIGH fix]** `Glorbo.Benchmarks.Orchestrator.validate_providers/1`
  now enforces the shared slug regex
  (`~r/\A[a-z][a-z0-9_-]{0,63}\z/`), rejects duplicates, and caps
  fan-out at 32. Previously any provider string — including
  newline-injected YAML, path traversal, or shell metacharacters —
  flowed unescaped into shadow-company slugs, manifest YAML, and
  AGENT.md placeholder substitution.
- **[HIGH fix]** Agent-filed task comments now land in the
  sibling `.comments.md` thread (GEP-30 D8), not appended inline
  to `task.md`. TaskLive/KanbanLive only read the thread file, so
  comments previously filed by agents were silently invisible in
  the UI.
- **[MED fix]** `GlorboWeb.MCP.Tools.CreateChannel` uses
  `Glorbo.Filesystem.FrontmatterWriter.atomic_write/2` instead of
  `File.write/2`. A crash mid-write no longer leaves a truncated
  `channels/<channel>.md` that the watcher would ingest.

### Added — GEP-26 Phase B dispatch orchestrator

- `glorbo bench run <template> <task-id> --providers a,b,c
  [--keep-shadow]` now actually fires the named task against
  one shadow company per provider and collects outputs under
  `~/.glorbo/benchmarks/runs/<run-id>/`. Shadow companies are
  forked from the template, the per-agent `provider:` (and
  `{{ provider }}` / `{{ model }}` placeholders) are pinned
  per fork, and a `manifest.json` is written with
  `status: in-progress → completed|failed`. The
  `/benchmarks/<run-id>` scoring UI (GEP-26 Phase C) picks the
  run up automatically.
- `Glorbo.Benchmarks.Orchestrator.run/4` is the underlying
  API; `Glorbo.CLI.Bench` is a thin wrapper with ✓/✗ summary
  rendering. Shadow companies are deleted on success unless
  `--keep-shadow` is passed; failures leave `dispatch-error.txt`
  under `providers/<p>/` for triage.

### Fixed

- `Glorbo.Network.Proxy.stop/1` now tolerates a dead pid
  (`{:noproc, _}` / `:noproc`) instead of propagating the
  exit — removed a TOCTOU race in test teardowns where
  `Process.alive?/1` returned `true` but the proxy
  terminated before `GenServer.stop` sent its message.

### Changed — GEP-23 D1 network enum rename (BREAKING)

- `network:` frontmatter values now `loopback | proxy | full`
  (was `none | proxy | open`). Parser rejects the old values
  with `{:invalid_network, _}`; no back-compat reader — pre-1.0
  atomic cut per GEP-23 D1. Bwrap typespec + `network_flag/1`,
  AgentLive config-editor dropdown, sandbox-view rendering,
  CompanyLive default, and every test fixture were migrated in
  the same commit.
- GEP-23 frontmatter flipped Draft → Implemented. `kbps_cap`
  per-dispatch throttle is deferred to a dedicated follow-up
  (needs the per-dispatch `Proxy-Authorization` token
  machinery that GEP-23 §Proxy daemon §5 describes).
- **Migration:** every AGENT.md on disk needs a one-line edit:
  `network: none → network: loopback`, `network: open →
  network: full`. Director-run `glorbo fmt --write` does NOT
  migrate the values (formatter is syntactic only); use
  `sed -i 's/^network: none$/network: loopback/; s/^network: open$/network: full/' ~/.glorbo/companies/*/agents/*/AGENT.md`
  or equivalent.

## [0.6.0] — 2026-04-23

Sixth pre-1.0 minor. Five shipping flags beyond v0.5.0: macOS
binaries via Linux-hosted Zig cross-compile (no more GHA macOS
runners); GEP-28 ProposalsLive + auto-approve-hire-within-
headcount-budget (GEP-28 → Implemented); GEP-26 Phase B
Director-facing scoring slice (`/benchmarks` + blind A/B
BenchLive); GEP-25 R26.2b parser enforcement (kind: agent/v1 +
task/v1 now required; 31 fixture files migrated; GEP-25 →
Implemented); GEP-23 Egress.History per-company decision cache
(GEP-23 still Draft pending the `network:` enum rename +
`kbps_cap` throttle).

### Added — GEP-23 per-company egress decision cache

- `Glorbo.Network.History` — per-company ETS-backed cache of
  classifier verdicts keyed by `{host, port}`, with per-entry TTL
  (6-hour default) and lazy eviction on `fetch/4`.
- `Glorbo.Network.Proxy.classify_unlisted/5` now consults the cache
  via injected `history_fun` / `history_put_fun` handles before
  invoking the classifier; a hit (`:allow` or `:deny`) short-
  circuits without re-running the classifier. `:unknown` verdicts
  are deliberately NOT cached — they need Director approval as the
  resolution path.
- 11 new tests: 7 in `Glorbo.Network.History` covering round-trip
  semantics + TTL expiry + flush, 4 in `Glorbo.Network.Proxy`
  verifying cache-hit short-circuits and unknown-verdict skip.

### Changed — GEP-25 R26.2b parser enforcement sweep

- `Glorbo.Agent.Parser.validate/4` now requires `kind: agent/v1`
  in AGENT.md frontmatter; `Glorbo.TaskDefinition.parse_frontmatter/2`
  now requires `kind: task/v1` in task files. Missing or wrong
  `kind:` returns `{:error, {:missing_kind, expected}}` /
  `{:wrong_kind, expected, got}` before any other validation
  runs. Closes GEP-25's parser-boundary enforcement — the
  matching Router-outbox enforcement landed in R26.2a, and the
  FileSpec validator already reported drift; now the agent/task
  runtime refuses to boot on non-canonical frontmatter.
- Bulk-patched 29 test fixture files + 2 support modules to
  carry the required `kind:` line via an Elixir one-shot
  script; the 6 edge cases (memory entries matched incorrectly,
  validator's own missing-kind fixture, a task fixture with a
  `provider:` override) were hand-corrected. GEP-25 frontmatter
  flipped from Draft to Implemented.

### Added — GEP-26 Phase B (Director-facing slice) — blind A/B scoring

- `/benchmarks` lists every `~/.glorbo/benchmarks/runs/<run-id>/`
  on disk via `Glorbo.Benchmarks.list/1`. Filterable by status,
  click-through to per-run detail.
- `/benchmarks/:run_id` (`BenchLive`) renders the frozen task plus
  N output panels labelled `Panel A`, `Panel B`, … in a
  stable-random order seeded by the `run_id` (same Director,
  same refresh, same layout — but different runs produce
  different orderings so the "leftmost slot = claude" bias can't
  form). Clicking panels in best-to-worst order records a
  ranking; submitting unmasks the labels and appends a scoring
  section to `benchmarks/runs/<run-id>/scores.md` (markdown per
  D6), flipping manifest `status:` to `scored`.
- `Glorbo.FileSpec.BenchmarkRunMd` validates the manifest
  (`kind: benchmark-run/v1` + `run_id`/`template`/`task`/
  `providers`/`started_at`); `glorbo validate` surfaces manifest
  drift at build time.
- Sidebar gets a Benchmarks nav entry between Providers and
  Costs.
- **Still queued:** the CLI dispatch orchestrator
  (`glorbo bench run <template> <task-id> --providers a,b,c`)
  that forks shadow companies and fans a task out to N
  providers. Until that lands, run directories are hand-
  assembled or produced by external tooling; the UI picks them
  up automatically once the manifest is on disk.

### Added — GEP-28 ProposalsLive + auto-approve-hire

- New Director-facing `/companies/:co/proposals` LiveView groups
  `proposals/*.md` by `status:` (pending / approved / denied),
  renders subtype + proposed_by + body preview per row, and wires
  Approve / Deny buttons that flip the proposal frontmatter in
  place via `Glorbo.Company.Proposals.flip/4`. Deny opens a
  modal for an optional `denial_reason` persisted to frontmatter
  + audit log. Sidebar gets a new `Proposals` entry between
  Inbox and Audit log.
- `Glorbo.Company.Router` now auto-approves `subtype: hire`
  proposals when the company has room under `headcount_budget:`
  in `company.md` (current agent count `<` budget). The writer
  stamps `approved_by: system/auto-approve-hire` + `approved_at`
  and emits a `proposal.auto_approved` audit event. Any other
  subtype, absent/zero budget, or over-budget headcount falls
  through to Director approval (existing behaviour).
- Read/flip API: `Glorbo.Company.Proposals.{list,fetch,flip}/4`
  — the LiveView's dependency, also callable from `iex --remsh`.

### Added — macOS binaries via Linux-hosted Zig cross-compile

- New `build-macos-cross` CI job on `ubuntu-24.04` produces both
  `glorbo-darwin-x86_64` and `glorbo-darwin-arm64` using Burrito's
  built-in cross-compile path: a universal macOS ERTS tarball from
  `beam-machine-universal.b-cdn.net`, `zig cc -target <arch>-macos`
  for the `exqlite` elixir_make NIF, and a Zig-compiled launcher
  wrap. The `build-macos` host-macOS job is gone — the GHA free-
  tier macOS queue backed up twice this cycle, and staying on
  ubuntu-24.04 for darwin keeps release cadence predictable.
- Darwin artifacts are back in the signed-release bundle
  (SHA256SUMS, cosign `.sig` blobs, GH Release file list). The
  `publish-homebrew-tap` job picks them up automatically via the
  formula generator's darwin-present branch, so the tap formula
  goes dual-platform again on the next release.
- `file` is the post-build smoke check — confirms each artifact
  is Mach-O and the arch matches the matrix cell before upload.

## [0.5.0] — 2026-04-23

Fifth pre-1.0 minor. Three major user-visible surface additions
(`glorbo detect-providers`, the Enable flow, the agent-wizard model
combobox), GEP-32 phase 3+4 complete, the GEP-15 atomic cut,
GEP-25 R26.2b golden-fixture coverage doubled, CI release path
repaired end-to-end (setup-beam bump, pasta probe tightening,
tap auto-publish, skip-pattern fix), and a honest README/macOS
story.

### Added — GEP-25 R26.2b golden fixtures

- Per-kind minimal-valid fixture tree under
  `test/fixtures/file-formats/` now covers 12 kinds: `agent/v1`,
  `task/v1`, `company/v1`, `project/v1`, `agent-memory/v1`,
  `sentinel-approval/v1`, `braindump/v1`, `agent-heartbeat/v1`,
  `agent-soul/v1`, `channel-log/v1`, `goal/v1`, and `skill/v1`.
- `Glorbo.FileSpec.GoldenFixturesTest` auto-discovers every fixture
  and asserts three properties: `classify_by_path/1` routes to the
  right spec, `Validator.findings/1` returns zero `:error` findings,
  and `Formatter.format_content/2` is idempotent (`:unchanged` + stable
  round-trip).

### Added — CI auto-publishes the Homebrew tap on release

- New `publish-homebrew-tap` job on `.github/workflows/ci.yml`
  runs after the signed `release` job finishes. It clones
  `foobarto/homebrew-tap` using the `HOMEBREW_TAP_TOKEN` repo
  secret, regenerates `Formula/glorbo.rb` from the just-published
  release's `SHA256SUMS`, and pushes the formula bump if the
  rendered output changed. The tap stays in lock-step with
  `main` with zero hand-off.

### Known gap — macOS builds still disabled

- The `build-macos` CI matrix was re-enabled briefly on
  2026-04-23 and the first run (24852774115) queued indefinitely
  without scheduling a single job in 25+ minutes — GHA macOS
  capacity has not recovered. Matrix re-disabled for now (second
  time); macOS artifacts excluded from the release bundle again.
  The formula generator still renders a Linux-only formula
  cleanly via `depends_on :linux`. Flip the `if: false` gate AND
  restore `build-macos` to `release`'s `needs:` list when runners
  are consistently available.

### Changed — `mix glorbo.release_formula` tolerates Linux-only releases

- The Homebrew formula generator now emits a Linux-only formula
  (with `depends_on :linux`) when `SHA256SUMS` lacks the darwin
  assets — which matches the current shipped state while
  `build-macos` is disabled in CI. When darwin SHAs reappear, the
  generator auto-detects them and rebuilds the old dual-platform
  formula. Partial darwin sets (one arch present, the other
  missing) still fail loudly. Added `--version X.Y.Z` flag so the
  generator can target a specific published release for smoke
  testing.
- New runbook at `docs/releasing.md` walks the full tag → CI
  release → `foobarto/homebrew-tap` refresh flow end-to-end,
  including the sanity checks and the current `build-macos` gap.

### Fixed — pasta-availability probe requires --splice-only support

- `Glorbo.Sandbox.Bwrap.pasta_availability/0` and the test-helper
  `BwrapHelpers.pasta_available?/0` both now scan `pasta --help` for
  the `--splice-only` token before declaring pasta usable. Older
  passt packages (including the one shipped on GitHub-hosted
  ubuntu-24.04 runners) don't know that flag, which GEP-31 relies
  on. The old probes returned `:ok` regardless, so integration
  tests that shell out to the real sandbox failed with pasta's
  help text in the assertion diff. `glorbo doctor` now surfaces
  the upgrade requirement directly ("pasta on PATH lacks
  --splice-only").

### Fixed — AgentLive config editor network dropdown

- Config form's `<select name="network">` was offering `none` and
  `outgoing` (not a real parser value); agents with the canonical
  `network: proxy` rendered as `none`, and any save silently clobbered
  the policy. Dropdown now lists `none | proxy | open` per
  `Glorbo.Agent.Parser.@network_map`, with the agent's current value
  pre-selected. Found via the 2026-04-23 UAT sweep.

### Docs

- README rewritten from 868 lines to 314: pitch + install + native
  provider + hire + start focus; per-version release detail moved to
  this file; the local-development walkthrough to `CONTRIBUTING.md`.
  Canonical links preserved so no content disappears.
- README macOS install story corrected: binaries are currently
  Linux-only because CI `build-macos` is disabled pending GHA runner
  capacity. macOS users build from source via `MIX_ENV=prod mix
  release` until the matrix is re-enabled.
- GEP-12 (no-user-input atoms), GEP-15 (ALLCAPS), GEP-21 (file-based
  agent memory), GEP-31 (proxy netns), and GEP-32 (native harness)
  all flipped to `Implemented`; the partial GEPs (17, 23, 25, 26,
  28) got history entries documenting what's shipped vs what's still
  queued.

### Changed — GEP-15 ALLCAPS convention — soft fallback dropped

- `Glorbo.Agent.FileLayout.agent_md/1` now unconditionally returns
  `AGENT.md`. The lowercase `agent.md` fallback that the module
  carried as a soft-migration path is gone, aligning with the
  pre-1.0 "no kid gloves" posture and the GEP-25 R28 `agent/v1`
  path guard that already rejects lowercase `agent.md` at the
  FileSpec boundary. The `agent_md_candidates/0` public getter is
  removed (it had no callers outside the module itself).

### Added — GEP-32 native agent harness (phase 4)

- `glorbo detect-providers` CLI verb probes localhost for native
  providers (ollama, llama.cpp, LocalAI, vLLM, LM Studio) using the
  shape-appropriate model-list endpoint plus response-header/body
  fingerprints for the shared-port tie-break. `--json` emits NDJSON
  per alias, otherwise a short human-readable report.
- ProvidersLive grows a "scan localhost" button that surfaces the
  same probe results as an advisory block. Each `:ready` row now
  offers an "+ enable" button that appends a matching `[[providers]]`
  entry to `~/.glorbo/providers.toml` (kind=native, auth=none,
  `usage_parser = "native-v1"`, correct `model_list` shape per alias)
  via `Glorbo.Providers.Enable`. The action is idempotent — a second
  Enable on the same alias is a no-op and flashes a notice.
- AgentLive config panel now populates the `model` field with a
  datalist of the cached model catalog for the currently-selected
  provider (queried from `provider_models`). Free-text entry still
  works; the combobox is pure autocomplete polish.

### Added — GEP-32 native agent harness (phase 3)

- Host-side `Glorbo.Providers.ModelCatalog` GenServer lands the first
  tranche of automatic model discovery for native providers. Native
  aliases get `/v1/models`-style probes (OpenAI shape) or
  `/api/tags` (Ollama shape) on explicit `refresh`, with raw responses
  persisted under `~/.glorbo/cache/providers/<alias>.json` and a
  derived SQLite projection in the new `provider_models` table.
  Dispatch never waits on a probe, and `glorbo reindex` rebuilds the
  projection from the cache without any network calls (GEP-32 D23).
- Failure classification covers the spec's matrix: `:auth` for
  401/403/missing-credentials, `:unreachable` for connection refused
  and friends, `:stale` for timeouts / 5xx, and `:shape` for
  malformed JSON or unknown response shapes.
- `Glorbo.Company.AgentBoot` now soft-warns when an agent names a
  model absent from the cached catalog; dispatch is not blocked
  (GEP-32 D24).
- `ProvidersLive` grows a "refresh models" action plus per-provider
  catalog chip (status / model count / refreshed timestamp).
- Shared native-provider config helpers (auth parsing, TOML
  credentials loading, endpoint resolution, auth-header construction)
  split out of `Glorbo.CLI.Harness` into a new
  `Glorbo.Providers.NativeConfig` so the harness and the catalog agree
  bit-for-bit on auth semantics.

## [0.4.1] — 2026-04-23

### Fixed

- MCP sessions now defend their own lifecycle instead of relying on
  client-behaved DELETEs: detached sessions reap after an idle timeout,
  per-session resource subscriptions are capped, and `initialize` now
  returns a structured JSON-RPC `503` when the session supervisor is at
  capacity.
- `Agent.Dispatch` no longer ro-binds provider binary directories into
  the sandbox at their host paths. Dispatch now resolves the final
  regular executable file, binds only that file into a fixed sandbox
  path under `/tmp`, and keeps the real host path only for the
  macOS/bwrap-unavailable fallback.
- CI and Pages workflows now pin every third-party GitHub Action to an
  exact upstream commit SHA, closing the mutable-tag supply-chain gap on
  the release path.
- Budget ledger rows are now scoped by `{company, agent, year_month}`
  instead of raw agent slug alone. Same-slug agents in different
  companies no longer share per-agent budget state, inflate company
  caps, or bleed spend into the budget UI.

## [0.4.0] — 2026-04-23

### Added — GEP-32 native agent harness (phase 2b)

- Native providers now ship the next native tool tranche: `bash` and
  `web_fetch` join `read_file`, `write_file`, `edit_file`, `glob`, and
  `grep` inside the first-party harness.
- `bash` runs in the existing sandbox/runtime contract, inherits the
  workspace cwd plus sandbox network policy, and records `tool.bash`
  audit events through the same sanitized `usage.json` replay path as
  the phase 2a filesystem tools.
- `web_fetch` now performs audited HTTP GET requests with structured
  response payloads and `egress.web_fetch` audit events, so native
  agents have a first-party egress tool instead of relying only on
  shell escapes.
- Native runtime knobs are now real end-to-end: `http_timeout_s`,
  `http_max_retries`, `web_fetch_timeout_s`, and
  `max_tool_calls_per_turn` parse from `agent.md`, cross the
  Dispatch→Dispatcher→harness boundary via env, and control both
  provider calls and `web_fetch`.
- Provider chat requests and `web_fetch` now share the same transient
  HTTP retry policy from GEP-32: retry on network errors, timeouts,
  HTTP 429, and HTTP 5xx; honor integer `Retry-After`; fail fast on
  other 4xx.

### Fixed

- `Network.Proxy` no longer spawns per-connection tunnel handlers with
  `Task.Supervisor.async_nolink/2`, which leaked task bookkeeping
  messages into the acceptor mailbox under repeated CONNECT traffic.
  Fire-and-forget handlers now use `start_child/2`, and the regression
  suite asserts the acceptor queue stays drained.
- `glorbo console` no longer passes the Erlang distribution cookie via
  `iex --cookie ...` argv. The launcher now injects `-setcookie ...`
  through `ERL_AFLAGS`, which removes the cookie from cross-user
  process listings while keeping the remote-shell flow unchanged.
- `GlorboWeb.StdoutStreamer` now caps both its unterminated partial-line
  buffer and final per-line payload size. A sandboxed agent can no
  longer grow the streamer's heap indefinitely by writing one huge
  newline-free stdout line.
- `Glorbo.Search` now truncates cached task titles and stops inserting
  new ETS entries once the title cache reaches its hard ceiling, so
  agent-authored task metadata can no longer grow the named cache table
  without bound.
- The archive browser in `ChannelLive` now renders metadata-only
  segment summaries from filename + `File.stat/1` and stops reading
  every archive body on each refresh. Full archive content is only
  loaded when the director explicitly opens a segment.
- `InboxLive` now rejects malformed or spoofed stuck-sentinel files
  while building the inbox list. Agent-written `state/stuck-on-*.md`
  files must carry a matching agent slug, a valid in-company task path,
  and a real regular task target before they render as actionable rows.

## [0.3.0] — 2026-04-23

Third pre-1.0 minor on the same day: GEP-31 lands and makes Linux
`network: proxy` honest. Proxy agents no longer share the host netns;
they run under a `pasta`-created private netns where only the Glorbo
proxy port is reachable.

### Added — GEP-31 network-namespace isolation for `network: proxy`

- Linux `network: proxy` dispatches now wrap the existing `bwrap`
  launch in `pasta --splice-only ... -T <proxy_port>`, so only the
  per-company proxy listener is reachable on loopback inside the agent
  namespace.
- `Agent.Dispatch` now resolves the per-company proxy listener and
  passes it through to the sandbox launcher. The sandbox normalizes the
  proxy URL to `http://127.0.0.1:<port>` so CLI-backed and native
  providers share the same loopback-only contract inside the netns.
- If `pasta` is missing on Linux, `network: proxy` dispatches are now
  refused instead of silently degrading to the old advisory host-netns
  behavior. Dispatch emits a once-per-company `agent.netns_unavailable`
  audit event so operators see the prerequisite failure.
- `glorbo doctor` now probes `pasta` and `glorbo doctor --fix` can
  explain the install step (`passt` package) even though it cannot
  install distro packages itself.
- The proxy integration suite now asserts the real load-bearing
  property: unrelated host loopback ports are blocked while the proxy
  port remains reachable.

## [0.2.0] — 2026-04-23

Second pre-1.0 minor on the same day: GEP-32's native harness moves
past the "single read tool" stage and now ships a real first filesystem
tool batch with audit replay, while keeping `bash` / `web_fetch` as the
next explicit tranche.

### Added — GEP-32 native agent harness (phase 2a)

- Native `glorbo harness` now ships four more filesystem tools:
  `write_file`, `edit_file`, `glob`, and `grep`, alongside the
  previously shipped `read_file`.
- The new filesystem-tool batch is intentionally narrow and sandbox-
  scoped: file reads/writes still rely on the existing bwrap mount view
  for isolation, and `bash` / `web_fetch` remain explicitly deferred to
  the next native-tools tranche instead of quietly sneaking in here.
- Tool execution is now factored through `Glorbo.CLI.Harness.Tools`,
  giving the harness one owned tool catalog instead of ad hoc inline
  logic in the runtime loop.
- Native `usage.json` now supports a sanitized `audit_events` list in
  addition to token counts and `tool_calls`.
- `Agent.Dispatch` replays those parsed tool events into the company
  audit log, so native-tool activity is director-visible instead of
  existing only inside provider transcripts.
- The `native_v1` parser now treats `usage.json` as untrusted sandbox
  output: both tool-count names and replayable audit actions are
  allowlisted before anything reaches Director-visible audit state.

## [0.1.0] — 2026-04-23

First pre-1.0 minor after v0.0.4. Headline work: GEP-32 phase 1 lands a
first-party native-provider runtime inside the existing bwrap dispatch
path; the threat-model campaign closes waves 1–7 worth of high/medium
findings; GEP-33 is drafted as the next major filesystem-history layer.

### Added — GEP-32 native agent harness (phase 1)

- Provider registry entries now support `kind = "native"` alongside the
  existing CLI kind. Built-in `openai` and `openrouter` providers ship
  out of the box.
- New internal `glorbo harness` subcommand runs as a first-party wrapped
  runtime inside the same bwrap sandbox existing CLI agents use. No
  in-process SDK client was added.
- Native dispatch writes a Glorbo-owned `usage.json` contract parsed by
  the new `native_v1` parser. If a provider omits usage telemetry at
  runtime, dispatch now hard-refuses unless the agent opted into
  `allow_untracked_budget: true`.
- Phase 1 ships a conservative tool loop with `read_file` only and a
  hard `@max_tool_calls = 50` cap. The implementation is already wired
  so future phases can add the broader tool catalog without a second
  runtime split.
- User-defined native providers from `~/.glorbo/providers.toml` now work
  correctly inside the sandbox by treating the env-driven runtime
  contract as authoritative; the harness does not rely on built-ins
  being the only visible registry population.
- Providers UI and tests are now kind-aware (`cli` vs `native`), and
  native providers surface endpoint/auth metadata instead of fake binary
  fields.

### Security — Threat-model waves 6 and 7 (2026-04-23)

- **Wave 6** — closed 4 medium findings across ACL permission-scope
  validation, Skills resolver lstat-before-copy, watcher/reindex
  regular-file discipline, and `config.md` / `logs/glorbo.log` private
  permissions; also dropped 3 stale open rows that were already fixed at
  HEAD.
- **Wave 7** — closed 4 more medium findings across Kanban `open_task`
  strict path + lstat guards, Homebrew formula SHA256 validation,
  canonical `budget.monthly_usd` parsing/enforcement, and backup archive
  creation via private temp path + atomic rename.

### Docs — GEP-33 draft

- Added `docs/geps/0033-git-history-layer-for-glorbo-home.md`, a long-
  form proposal for an opt-in git-backed history layer under
  `~/.glorbo/.git/`, with the kernel owning commits and audit JSONL
  remaining authoritative.

### Security — Threat-model wave 3 (2026-04-22, mediums)

Closed 16 medium-severity Codex findings. Path-traversal /
isolation-break items (Tier 1) and secure-by-default regressions
+ input hardening (Tier 2). Resolved rows pruned from
`docs/testing/threatmodel.md`; 51 lower-severity findings remain
queued. 1656 tests green.

Tier 1 — isolation breaks exploitable by a malicious agent:

- **M02 + M11** — `Glorbo.Agent.LoopDetector.resolve/5` built
  `companies/<co>/<task_path>` from sentinel frontmatter without
  checking shape. Agents can write their own `state/` so a crafted
  `task_path: ../../otherco/projects/...` had the director-initiated
  resolution mutate cross-company task files. New
  `validate_sentinel_task_path/1` confines to
  `projects/<slug>/tasks/<id>.md`.
- **M04** — `TaskLive` + `InboxLive` `stuck_resolve` accepted any
  client-supplied `sentinel_path` and joined into an absolute path.
  New `validate_relative_sentinel_path/1` rejects absolute paths,
  `..`, NUL, or anything not matching `agents/<slug>/state/stuck-on-<id>.md`.
- **M14** — `Glorbo.Company.Router.handle_outbox_comment/4` blindly
  appended any agent's outbox comment to any task across all
  projects — an agent with zero `tasks:*`/`projects:*` permissions
  could mutate any task by dropping a comment file. New
  `check_comment_permission/2` requires
  `tasks:update:<project>` or `projects:write:<project>`
  (project-scoped or `*`).
- **M03** — `handle_outbox_memory_write/4` followed symlinks on
  both source (agent outbox) and dest (memory dir). Agents could
  redirect a memory write into another agent's memory directory.
  Added `ensure_regular_file_lstat/1` on both paths.
- **M18** — `KanbanLive.delete_task_file/3` `mkdir_p`/`rename`'d
  through `projects/<p>/history/` without lstat. Agent-planted
  symlinked history dirs would redirect task moves to another
  company. New `ensure_no_symlink_directory/1` walks each path
  component; `ensure_regular_file_or_absent/1` guards the rename
  target.
- **M19** — `ProjectLive.ensure_and_load_meta/1` +
  `write_project_md/2` used `File.read`/`File.write!`/`File.rename`
  on `project.md` with no lstat. Symlink swap → arbitrary host
  read/write. New `ensure_project_md_writable/1`.
- **M17** — `KanbanLive.list_task_attachments/2` enumerated
  attachments via `companies/*/projects/<p>/attachments/<id>/`,
  leaking filenames + sizes from sibling tenants sharing project +
  task slugs. Now scoped to caller's company; `File.ls` instead of
  `Path.wildcard`.
- **M10** — `Glorbo.Agent.Dispatch.resolve_provider/3` honoured
  the task's `provider:` over the agent's spec. An agent with
  `tasks:write` could swap to a more-privileged provider whose
  `auth_binds` mount host secrets. New `reconcile_task_provider/2`
  pins to `spec.provider`; mismatched task overrides are logged
  and ignored.

Tier 2 — secure-by-default + input hardening:

- **M16** — `Glorbo.Agent.Parser.validate_network/1` defaulted
  missing `network:` to `:proxy`, which inherits the host netns
  (advisory enforcement until GEP-31 lands). Default flipped to
  `:none` (kernel-enforced); templates that need egress set
  `network: proxy` explicitly.
- **M13** — Editor template (`priv/templates/agents/editor.md`)
  was the only template carrying `network: open` (full host net).
  Flipped to `network: proxy`.
- **M21** — `glorbo new agent` scaffold default permissions
  changed from `[projects:read:*, chat:read:*]` to `[]`. Fresh
  agents no longer have automatic read access to every project
  + chat log; directors grant narrowly scoped access in AGENT.md.
- **M15** — `priv/providers/opencode.toml` ro-bound
  `~/.config/opencode/` into every opencode-backed agent's
  sandbox. The dir typically holds third-party API credentials —
  any compromised agent could read + exfiltrate. `auth_binds`
  removed; operators who need host provider configs override per
  agent.
- **M12** — `GlorboWeb.Actions.hire_argv/2` only validated the
  agent slug; `role`/`provider` flowed into AGENT.md frontmatter
  unchecked, letting an HR agent inject extra keys (permissions,
  network, heartbeat) into the new agent's spec. Added
  `@hire_role_re` (printable ASCII, ≤64 chars) and
  `@hire_provider_allowlist`. Defense-in-depth: scaffold itself
  now sanitises role/provider/model via `sanitize_yaml_scalar/2`
  (rejects newlines, quotes, `---`, control chars).
- **M06** — Already covered by wave-2 M25's `escapeHtml` in the
  command palette — palette renders both task hits and audit hits
  via the same row template, so the wave-2 escape covers both.
  Verified during this wave.
- **M05** — `AuditExportController.csv_cell/1` now prefixes any
  cell starting with `= + - @ \\t \\r` with a single tick to
  neutralise spreadsheet formula injection.

### Security — Threat-model wave 2 (2026-04-22, Codex scan)

Codex Cloud posted 87 findings against commit `cc99146`; the prior
security pass (T1-T15) already resolved 6 of them (1/2/3 → T1/T3/T4,
13 → T5, 14 → T2, 15 → T7). This wave addresses **all 9 remaining
high-severity** findings plus 5 impactful mediums. Every fix lands
with the existing unit/regression suite green (1655 tests); new
specific tests will ship in a follow-up wave. Remaining 67 findings
(lower-severity mediums + lows + informational) queued for triage.

Handling the HIGH items (paths point to `lib/glorbo/...`):

- **H4** — `Dispatch.default_run_fun/4` silently fell through to
  `Glorbo.Sandbox.Unsandboxed` when bwrap was missing. On Linux
  that's a sandbox bypass; now refuses with `{:error, :sandbox_unavailable}`
  and emits `agent.sandbox_refused`. macOS keeps the fallback
  (GEP-5 D6 invariant).
- **H5** — `TaskScheduler.maybe_fire/5` read `assigned_to` straight
  from frontmatter and built the inbox path unchecked. A crafted
  task with `assigned_to: ../foo` wrote outside `agents/<slug>/inbox`.
  Now `GlorboWeb.Slug.valid?/1`-gated with
  `scheduler.invalid_assignee` audit.
- **H6** — `AuditLive.scaffold_audit_task/2` used `File.write!/2`
  on `.tmp` + `File.rename/2` — both follow pre-planted symlinks.
  Added `refuse_if_symlink/1` lstat gate on both paths.
- **H7** — `Glorbo.BrainDump.capture/4` + `convert_to_task/3`
  used raw `File.write!/File.rename` with no symlink defense.
  Added `ensure_regular_file/1` + `ensure_safe_dir/1` guarding
  capture, convert, and section-removal paths.
- **H8** — Reply-block `ACTIONS:` DSL let an agent emit
  `status: approved` / `reassign_to: anyone` with zero ACL checks,
  enabling self-approval and unauthorized reassignment. Status
  now whitelists `todo/in_progress/in-progress/blocked/done` only;
  reassign_to requires `GlorboWeb.Slug.valid?/1`.
- **H9** — `AgentLive` generic file editor could write `AGENT.md`
  via `open_file`/`save_file`/`create_file`. That's the agent's
  permission + network contract; self-escalation trivial. New
  `refuse_contract_write/1` blocks `AGENT.md` and `stdout.log`;
  typed config editor remains the sanctioned path. SOUL.md /
  HEARTBEAT.md stay editable (no escalation surface).
- **H10** — Same LiveView's `read_workspace_file/2`,
  `write_workspace_file/3`, `soft_delete/2`, and `walk_workspace_dir/3`
  used `File.read/File.write/File.dir?/File.regular?` — all follow
  symlinks. New `ensure_no_symlink_on_path/2` walks path components
  with `File.lstat`; tree walker switched to `File.lstat` too so
  symlinks don't get rendered as directories or recursed into.
- **H11** — `Agent.Server.write_outbox_reply/3` wrote the
  agent-envelope via `File.write!` in a dir the agent controls.
  Pre-seeded symlinks would redirect writes to arbitrary host
  files. Added `File.lstat`-refuse for non-regular targets.
- **H12** — `Dispatcher.maybe_stdout_to_reply/4` fallback wrote
  `reply.md` via `File.write!` with only `fs.exists?` guarding
  (broken symlinks read as non-existent). Same lstat-refuse.

Medium-severity fixes (highest-impact):

- **M25** — Command palette rendered server-supplied search result
  `label`/`hint`/`href` into `innerHTML` — task titles authored
  by agents could smuggle `<script>`. Added `escapeHtml/1` in
  `assets/js/app.js`, applied to every interpolation in
  `paletteHtml` + `renderList`.
- **M35/M36** — `KanbanLive.maybe_notify_assignee/6` built the
  inbox path from the LiveView form's `assigned_to` without
  validation. Slug-gated via `GlorboWeb.Slug.valid?/1`.
- **M40** — `TaskDefinition.canonicalize_ref/2`'s `projects/…md`
  pass-through branch accepted `..` segments. New `traversal?/1`
  rejects absolute paths, NUL, or any `..` segment.
- **M41** — `GlorboWeb.Actions.wake_task_assignee/7` pulled
  `assigned_to` from a task file (agent-authored) and forwarded
  to `write_mention/8` unchecked. Slug-gated.

Threatmodel CSV statuses flipped for the 20 resolved rows
(`resolved (prior wave T…, commit …, 2026-04-22)` or
`resolved (H…/M…, pending commit, 2026-04-22)`).

### Security — Threat-model pass (2026-04-22)

Fifteen findings from `docs/testing/threatmodel.md` triaged and
addressed in a single security pass. Every fix lands with a unit
or regression test; threatmodel.md statuses updated in-place.

High-severity:
- **T1** — `Glorbo.TaskComments.append/4` wrote to the comments
  file via `File.exists?` + `File.write`, following symlinks. An
  agent with `tasks:update` could pre-create `<task-id>.comments.md`
  as a symlink to `~/.glorbo/config.md` and have the host append to
  it. Added `ensure_regular_file/1` lstat check.
- **T2** — MCP `glorbo.create_agent` forwarded
  role/provider/model/reports_to/template verbatim into AGENT.md
  YAML. Newlines / `---` / `"` let a caller inject extra frontmatter
  keys (permissions, network, heartbeat) to scaffold a privileged
  agent. New `Args.require_safe_yaml_scalar/3` + `require_safe_identifier/2`.
- **T3** — `Dispatch.write_prompt/3` did `mkdir_p! + write!` on a
  path derived from the constant task_id `"heartbeat"`. An agent
  could pre-create `.glorbo-run/heartbeat/` (or the inner
  `task-prompt.md`) as a symlink. Added `ensure_safe_run_dir!/1`
  + `ensure_safe_prompt_path!/1`.
- **T4** — `PathRequestGate.write_grant/4` stored director-supplied
  `:write` verbatim; cross-company paths became `--bind` (RW) under
  bwrap. New `resolve_cross_company_mode/4` downgrades anything
  under `companies/<other>/` to `:read` (per GEP-27 §151-161).

Medium-severity:
- **T5** — Unbounded MCP sessions + subscriptions. Added
  `max_children: 256` to `SessionSupervisor` and
  `max_subscriptions_per_session: 64` guard in `Session.handle_call/2`.
- **T6** — Mention fanout hardcoded `from: "director"`; an MCP
  caller could spoof director provenance. Threaded the caller's
  actor through `write_mention/8`; sanitized via `safe_actor_tag/1`.
- **T7** — `Router.serialize_proposal/2` wrote extra keys verbatim.
  A crafted key with `\n` produced a second `status:`/`approved_by:`
  line that overrode Router-stamped fields on re-parse. Extras now
  filtered to `[a-z][a-z0-9_]{0,63}`.
- **T8** — `SmartClassifier.classify/2` checked allowlist before
  private-IP, so an allowlisted `127.0.0.1` bypassed the invariant.
  Reorder: private-IP now outranks allowlist.

Low-severity / crash-hardening:
- **T9** — `OverviewLive.company_goals/1` crashed /companies on
  non-string `goal.slug`. New `safe_goal_slug/1`.
- **T10** — `handle_initialize/1` raised `BadMapError` on `params:
  []` (valid JSON-RPC). Coerce non-map params to `%{}`.
- **T11** — `/mcp` now sits behind the `:dashboard` pipeline;
  `DashboardToken` plug extended to accept `Authorization: Bearer
  <token>` (MCP-friendly) alongside `?token=<value>`.
- **T12** — `ProposalsSink` lifted frontmatter `approved_by` into
  the audit `actor` field — an agent with `proposals:write:*` could
  forge a director-signed `proposal.approved`. Renamed actions to
  `proposal.file_*`; actor always `"proposal-file"`; claimed
  proposer/approver preserved in `detail.claimed_*`.
- **T13** — `InboxLive` `approve_path` raised on malformed payload.
  `Enum.flat_map` + whitelist of `read`/`write` atoms.
- **T14** — `Network.Proxy.safe_classify/3` returned the classifier's
  raw value; non-matching tuples raised `CaseClauseError`. New
  `normalise_classifier_result/1` coerces malformed returns to
  `{:unknown, :classifier_malformed}`.
- **T15** — Invalid (false positive). `Regex.scan :all_names`
  returns captures alphabetically; existing destructure is correct.

### Fixed — UAT bugs surfaced during the bench-tech-blog walkthrough

- **B1** — `AuditLog.append/1` calls from `BrainDumpLive.emit_audit/4`
  + `CompanyLive.do_wake_all/1` silently dropped every audit event
  in production because the bare `Glorbo.Company.AuditLog` is only
  registered per-company. Verified against live acme
  (`grep -c braindump` → 0 since #230 shipped). New
  `AuditLog.append_for/2` resolves the per-company via-tuple in
  prod and falls back to the bare module in the unit-LV test harness.
- **B2** — Sidebar "Chat" link 404'd on every freshly-scaffolded
  company. Both scaffolders (plain + template-based) now write a
  minimal `channels/general.md` stub.
- **B3** — `g v` shortcut + palette "Approvals" entry pointed at
  the since-deleted `/approvals` route (folded into `/inbox`).
  Rewired to `/inbox?tab=mine`; added `g i` for Inbox root.
- **U1** — Brain-dump `ctrl+enter to submit` hint wasn't wired to
  any keybinding. New `SubmitOnCtrlEnter` JS hook.

### Changed — `:api_only` renamed to `:proxy` (breaking)

Pre-1.0 atomic cut, no deprecation alias. The old name suggested
"only allows API traffic" but the runtime behavior is "inherits
host netns, env-var hint that a proxy exists". `:proxy` names what
it does. 45 files touched: atoms, frontmatter strings, function
names, config key `api_only_base_allowlist` → `proxy_base_allowlist`,
integration test filename, every GEP and design doc. Motivates
**GEP-31 (Draft)** which will make `:proxy` mean *"only the proxy
is reachable"* at the kernel level via per-agent network namespaces
+ `pasta`.

### Added — GEP-31 (Draft): netns isolation for `:proxy` agents

Draft GEP landed in `docs/geps/0031-netns-isolation-for-proxy-agents.md`.
Identifies the loopback-escape gap surfaced during the threatmodel
pass — an agent on `:proxy` can still reach `127.0.0.1:4000`
(Glorbo web/MCP) or any RFC1918 host because it shares the host
netns. Proposes per-dispatch netns + `pasta` userspace forwarding
that only exposes the proxy port. No implementation yet; phased
rollout documented in the GEP (Phase A plumbing → Phase D default).

### Added — New-task drawer + sidebar quick-action + palette shortcut

The "+ new task" button on Kanban now opens a right-side shelf
drawer (matches `.design/` mock 20) instead of the center modal.
Three new entry points for the same drawer:

- sticky `+ new task` button at the bottom of every company
  sidebar (navigates to `kanban?new_task=1`),
- command-palette entry `+ new task (<co>)`,
- global `g n` keyboard shortcut.

The drawer reuses the existing `new_task_create` LV pipeline —
upload handling, frontmatter splicing, and assignee notification
are unchanged. A `?new_task=1` query param on `/kanban` opens the
drawer empty; `?assignee=<slug>` still opens it pre-filled.

### Added — In-UI goal creation + collapsible sidebar

- `GoalsLive` gets a `+ new goal` modal (slug + title + optional
  description) backed by `Glorbo.Company.Goals`. Frontmatter
  splice preserves existing `goals:` list and unknown keys.
- Topbar gains a `‖` sidebar-toggle (Ctrl+B); new
  `SidebarCollapse` JS hook mirrors the chat drawer's
  localStorage pattern so the preference persists across pages.
- Company picker renders inline with the `~/.glorbo/companies/`
  breadcrumb — no box, no raised bg, just a ▾ chevron.

### Changed — Inbox redesign + audit-row grid fix

Inbox grows dedicated `gl-inbox__*` surfaces: tabs, per-type
rails (amber for path-requests, danger for stuck), and an
audit-row grid with ellipsis on ISO timestamps so the avatar
column stops colliding with long `YYYY-MM-DDTHH:MM:SS.SSSZ`
strings.

### Changed — Agent detail + RUNS restyle

- Identity box shows the live runtime PID (or `(not running)`).
- RUNS list rows gain status-coloured left rails (green complete
  / cyan running / grey unknown), tighter 6-col grid header,
  inline reply snippet.

### Fixed — Agent-created approval tasks now reach the inbox

Two bugs combined to silently drop agent-created approval tasks:

1. The outbox router rejected bare task files (`outbox/<id>.md`)
   because the classifier required a project prefix.
2. `Glorbo.Approvals.Gate.request_approval/2` existed but was
   only called from tests; production never invoked it.

Router now recognises task-kind frontmatter on bare filenames
and explicitly calls `Approvals.Gate.request_approval` after a
successful file-to-project move when the task carries
`requires_approval: director` (or the newer
`status: pending_approval`). The CEO agent's system prompt
scaffold was updated so agents learn the real outbox channels
rather than inventing filenames like `<task-id>-shaped.md`.

### Fixed — Brain-dump task IDs + delete-on-convert

- `BrainDump.convert_to_task/3` now emits canonical `inbox-NN`
  task IDs instead of `t-bd-YYYY-MM-DD-<slug>` so `TaskLive`'s
  validator (`\A[a-z][a-z0-9_-]*-\d+\z`) can open them.
  Provenance stays in frontmatter (`source: braindump`,
  `braindump_ts: …`).
- Converting a brain-dump entry now deletes the source section
  from its day file atomically — no more duplicate-conversion
  risk. Day file is `File.rm`'d if the last visible entry was
  just converted.

### Fixed — Live status wiring across cross-company LVs

`agents:status` PubSub is now subscribed by every director LV
that renders the sidebar (Costs, Providers, Goals, Skills,
BrainDump, Overview, Task, Agent). Previously only the company-
pinned pages ticked, so the sidebar agent-status pill and the
footer `<active>/<total> agents` counter went stale on Costs /
Providers / Overview until a manual refresh. The helper uses
`File.ls("companies")` + `Phoenix.PubSub.subscribe` per slug
for cross-company pages.

### Changed — Director Dashboard TUI Redesign (GEP-30)

The Director-facing LiveView dashboard now reads as a true TUI
terminal panel rather than a hybrid of soft-UI and phosphor
effects. Restyle, not a rewrite — same routes, same state, same
LiveView modules. Shipped in eight phases on `main`:

- **Tokens** — the TUI handoff palette is merged into `app.css`
  under `--glorbo-*` alongside the existing OKLCH `--gl-*` tokens.
- **Chrome** — the chat drawer becomes a Quake-console (minimized
  by default on every page, toggle with **Ctrl+`** matched on
  `e.code === "Backquote"` so non-US layouts still hit it); the
  composer renders an IRC-style prompt
  `director@<co>:#general$` with colour-coded segments. Topbar
  gains `otp-<release>` in the version strip + the `▟` brand
  glyph; statusbar gains the `mcp: :4000/mcp` segment (GEP-29).
- **Overview, channels, audit, kanban, goals, skills, providers,
  modal overlays** — stat cards, panels, agent-roster table,
  banner, input, modal, and task-drawer surfaces drop their
  2–8px radii and drop shadows to read as hairline-bordered
  terminal containers. Audit rows + agent-roster rows gain
  dashed separators matching the prototype.
- **ChannelLive composer** — full
  `director@<co>:#<channel>$` IRC prompt + a keybind hint row
  (`@ · / · ⏎ · ⇧⏎`).
- **task-comments/v1 FileSpec** — atomic cut per GEP-30 D8:
  task comments now live in a sibling `<task-id>.comments.md`
  file via the new `Glorbo.TaskComments` reader/writer. The
  task file stays diff-clean; Kanban drawer + TaskLive render
  the thread from the sibling. `Actions.post_task_comment/4`,
  `Agent.Server.write_task_comment_reply/3`, KanbanLive, and
  TaskLive all routed to the new path.

Existing keyboard overlays (`?` cheatsheet, `⌘K` command
palette) were already wired; this pass sharpened their chrome.

### Added — Goals-progress row on OverviewLive company cards (backlog #13)

Each company card on `/companies` now surfaces an aggregate
goals-progress indicator: goal count, completion percentage, and
a thin progress bar colored by tier (cold → warm → good → done).
Companies with no `goals:` on their `company.md` omit the row
entirely — zero visual noise for companies that don't use the
feature.

Data source reuses the same `goal:` task-frontmatter rollup
`CompanyLive` already uses: walks `projects/*/tasks/*.md`,
buckets by goal slug, counts `status: done` against the total.
No new on-disk shape, no new supervisor dependency, no
`company.md` schema change.

- `OverviewLive.goals_summary/3` returns
  `%{count, total_tasks, done_tasks, pct}` or nil.
- `CompanyCard` renders a footer row + bar with 4 tier
  classes (cold / warm / good / done) — CSS added under
  `gl-company-card__goals*` in `assets/css/app.css`.
- 2 new tests: no-goals company hides the row; seeded goals +
  tagged tasks produce a bar with the right percentage.

1561 tests green.

### Changed — Channels → Chat label + DM list cleanup (backlog #15)

UI-only. Three cosmetic nudges:

- Sidebar nav: "Channels" → "Chat". The underlying file tree
  (`channels/*.md`), routes (`/companies/:co/channels/:ch`), and
  module names (`ChannelLive`) stay; only the human-facing label
  changes.
- Channel-rail header: `/channels` → `/chat`.
- DM list entries: drop the "director ↔" prefix, show the agent
  slug only (`ceo` instead of `director ↔ ceo`).
- DM channel heading: `DM · director ↔ <agent>` → `DM · <agent>`.
  The compose placeholder still includes "as Director" for the
  actor context.
- DM list already auto-populates every agent in the company —
  confirmed via `list_dm_threads/2`; faded entries become live on
  first click thanks to `ensure_dm_channel/3`. No code change.

Tests updated: `company_live_test.exs` nav-label array,
`channel_live_test.exs` for the new rail + heading shape.

1559 tests green.

### Changed — Collapse Approvals page into Inbox (backlog #14)

The standalone `/companies/:company/approvals` route + LiveView +
sidebar entry are retired. Their function was fully duplicated by
`InboxLive`'s Mine tab, which already renders the same
awaiting-approval sentinel data with approve / deny / archive
buttons.

- Deleted `GlorboWeb.ApprovalQueueLive`,
  `GlorboWeb.Components.ApprovalCard`, the two test files
  (`approval_queue_live_test.exs`,
  `approval_queue_integration_test.exs`), and the router mount.
- Removed `:approvals` from the sidebar nav. The pending-approvals
  badge now renders on the `:inbox` item instead of a duplicate
  nav row.
- Updated doc comments and one test assertion in
  `company_live_test.exs` + rephrased `sidebar_test.exs` moduledoc.

ApprovalQueueLive's list-select + prompt-diff-panel + keyboard-
shortcut features are not preserved — Inbox's Mine tab stays a
flat feed. If power-user approval workflow emerges as a real
need, `docs/todo.md` can track "add keyboard shortcuts + inline
prompt preview to Inbox Mine tab" as a separate follow-up.

1559 tests green; mix credo --strict clean.

### Added — GEP-29 wave (f): end-to-end smoke test + client setup doc

Closes out GEP-29. Status flipped to **Implemented**.

**`scripts/mcp-smoke.sh`** exercises the entire MCP protocol against
a running `phx.server`: initialize → tools/list → tools/call →
resources/list → resources/templates/list → resources/subscribe
→ GET /mcp (SSE in background) → trigger a channel broadcast →
assert `notifications/resources/updated` frame arrived → DELETE
→ assert stale session is rejected with -32002. Prints a per-step
✓ / ✗ line; exits non-zero on any protocol failure. Runs against
localhost:4000 by default; override with `MCP_URL=...`.

**`docs/mcp-client-setup.md`** documents how to plug external MCP
clients — Claude Code (via `claude mcp add --transport http`),
Cursor, and hand-crafted HTTP clients — into a running Glorbo.
Covers security posture, the `Mcp-Client-Name` actor-tagging
header, troubleshooting, and the smoke test's prerequisites.

**Regression fix surfaced by the smoke:** `use GenServer,
restart: :temporary` on `GlorboWeb.MCP.Session`. The
`DynamicSupervisor` default is `:permanent`, which restarted
sessions on every exit — including the `:normal` exit sent from
`terminate_session/1`. Result: DELETE /mcp appeared to succeed,
but a zombie session kept running under the same `Mcp-Session-Id`,
allowing subsequent POSTs to bypass the stale-session check. Added
a regression test that recreates the DELETE → exists? flow.

Codex review caught and we fixed: subscription and trigger
targeting different companies in multi-company installs (smoke now
derives the company from the chosen URI), missing
`MCP-Protocol-Version` header on non-initialize POSTs (smoke now
sends it on every request), obsolete Claude Code config paths
(doc now points at `claude mcp add` and `.mcp.json` / `~/.claude.json`),
wrong GEP filename in the doc, and undocumented smoke prerequisites.

- `scripts/mcp-smoke.sh` — new (~180 lines shell)
- `docs/mcp-client-setup.md` — new (~120 lines)
- `lib/glorbo_web/mcp/session.ex` — `restart: :temporary` +
  regression test
- `docs/geps/0029-mcp-server-for-glorbo.md` — status flipped to
  Implemented
- `docs/geps/README.md` — index updated to match

151 MCP tests; 1604 total green.

### Added — GEP-29 wave (d.2): MCP resources/subscribe + SSE streaming

Closes out the MCP resources surface with server-initiated
notifications. Clients can now subscribe to any resource URI
surfaced in wave (d.1) and receive `notifications/resources/updated`
messages pushed over an SSE stream whenever the underlying
filesystem or audit log changes.

New runtime components:

- `GlorboWeb.MCP.Session` — per-session GenServer holding the
  subscription set, Phoenix.PubSub subscriptions, and the attached
  SSE pid. Auto-detaches on SSE process exit via `Process.monitor/1`.
- `GlorboWeb.MCP.SessionSupervisor` — `DynamicSupervisor` parent.
- `GlorboWeb.MCP.SessionRegistry` — `:unique` Registry keyed by the
  `Mcp-Session-Id` issued in `initialize`.

Wire contract additions:

- `initialize` starts a Session and stamps its id on the response
  header. Subsequent requests must echo `Mcp-Session-Id`.
- `resources/subscribe` + `resources/unsubscribe` JSON-RPC methods.
  Subscribe maps the URI to its PubSub topic (`company:<co>:audit`
  for audit, `company:<co>:projects` for approvals, `…:proposals`
  for proposals, `…:channels:<ch>` for chat) and records it on the
  Session. Unsubscribe drops it; the last URI referencing a topic
  triggers `Phoenix.PubSub.unsubscribe/2`.
- `GET /mcp` opens an SSE stream (`Content-Type: text/event-stream`)
  and attaches the plug process to the session. Emits a
  `: stream open` comment frame immediately, then a `: keep-alive`
  comment every 15s so intermediaries don't cull the idle connection.
  Each `notifications/resources/updated` arrives as a `data: {…}\n\n`
  frame.
- `DELETE /mcp` with a session header terminates the session;
  without one, still returns 204 for client-shutdown idempotency.

Initialize capability now advertises
`"resources": {"listChanged": false, "subscribe": true}`.

Notification routing is narrowed by URI family so an audit event
doesn't fire `updated` for an unrelated chat subscription.
Channel-level events further narrow by channel slug. Cross-company
over-notification in the audit case is a known limitation — clients
always re-read the snapshot anyway, so it's at most a spurious wakeup.

Codex review caught and we fixed: TOCTOU races between
`Registry.lookup/2` and `GenServer.call/stop/3` (now caught as
`:noproc`/`:shutdown` exits and surfaced as `:unknown_session`),
PubSub refcount leaks when re-subscribing the same URI (now
idempotent), over-broad notifications firing on every URI regardless
of family (now filtered), and the GET-without-session case
conflating "missing header" with "expired session" (now 400 vs 404
respectively).

Notes for wave (d.3) or later: per-company URI routing on audit
events would require either embedding the company in
`{:audit_append, record}` broadcasts or switching to topic-aware
subscriptions. Neither is urgent — clients re-read on any signal.

- `lib/glorbo_web/mcp/session.ex` — new (~380 lines)
- `lib/glorbo_web/mcp/plug.ex` — SSE stream handler + session
  lifecycle wiring
- `lib/glorbo_web/mcp/server.ex` — subscribe/unsubscribe dispatch
- `lib/glorbo/application.ex` — SessionSupervisor + SessionRegistry
  children
- `test/glorbo_web/mcp/session_test.exs` — 19 new tests

150 MCP tests pass; 1603 tests total green.

### Added — GEP-29 wave (d.1): MCP resources (list + read snapshots)

First half of the MCP resources surface per 2025-06-18 spec. The
server now exposes a read-only resource catalog alongside its tool
catalog, letting MCP clients enumerate and read Glorbo's main data
surfaces by URI rather than by named tool call.

Four URI families, all under the custom `glorbo://` scheme:

- `glorbo://audit/<company>` — bounded audit snapshot (~100 rows)
- `glorbo://chat/<company>/<channel>` — recent channel messages
- `glorbo://approvals/<company>` — tasks awaiting Director approval
- `glorbo://proposals/<company>` — GEP-28 proposals for a company

New JSON-RPC methods wired into `GlorboWeb.MCP.Server.dispatch/3`:

- `resources/list` — enumerates concrete URIs by walking the company
  tree; slug-gates every segment (company dir + channel filename)
  so only spec-legal URIs are advertised.
- `resources/templates/list` — returns the 4 URI templates for
  clients that prefer construction over enumeration.
- `resources/read` — parses URI, verifies the company directory
  exists (missing → `-32002`), then dispatches to the matching read
  tool (`QueryAudit`, `GetChannel`, `ListPendingApprovals`,
  `ListProposals`). Returns MCP-spec `{contents: [{uri, mimeType,
  text}]}` with JSON-encoded payloads.

Subscriptions (`resources/subscribe` + SSE push) are deferred to
wave (d.2) — snapshots land first so clients can exercise the URI
model before we wire streaming state.

Initialize response now advertises `"resources": {"listChanged":
false, "subscribe": false}` alongside the existing tools capability.

Security posture matches the tool path: every URI segment passes
through `GlorboWeb.Slug.valid?/1`, trailing slashes and extra path
segments are rejected at parse time, and unknown-company reads
return `-32002 Resource not found` rather than empty JSON.

- `lib/glorbo_web/mcp/resources.ex` — new module (catalog + reader)
- `lib/glorbo_web/mcp/server.ex` — dispatch wiring + capability
- `test/glorbo_web/mcp/resources_test.exs` — 18 tests (list
  enumeration, templates shape, read happy paths, unknown company,
  unknown channel, traversal attempts, malformed URIs)

Codex review caught and we fixed: unknown-company reads collapsing
to empty JSON (→ now `-32002`), catalog entries trusting raw
filesystem names (→ now slug-gated), and trailing-slash aliasing
on single-segment URIs (→ now rejected for URI identity stability
ahead of wave (d.2)).

1574 tests green; mix credo --strict clean.

### Changed — GEP-29 wave (e): MCP-Protocol-Version header validation

Spec-compliance fix for the Streamable HTTP transport. Previously
the `MCP-Protocol-Version` header was ignored and `initialize`
always returned our internal protocol version regardless of what
the client requested. Two issues fixed in one pass:

- **Header validation** (`GlorboWeb.MCP.Plug.validate_protocol_version/2`):
  every POST except `initialize` now checks the
  `MCP-Protocol-Version` header against
  `Server.supported_protocol_versions/0` (currently
  `["2025-06-18", "2025-03-26"]`). Missing header defaults to
  `2025-03-26` per the spec's backwards-compat clause; unsupported
  version returns 400 + JSON-RPC -32600 with a structured `data`
  payload naming the sent and supported versions.
- **Lifecycle version negotiation** (`Server.handle_initialize/1`):
  reads `params.protocolVersion`; echoes it back if supported,
  otherwise replies with `@protocol_version`. Previously hardcoded
  to `@protocol_version` regardless of what the client asked for,
  which silently broke clients on older supported specs.

Codex-reviewed; the version-negotiation bug was flagged as
must-fix and addressed inline with two regression tests
(`initialize echoes a supported older protocolVersion from the
client` + `initialize replies with our latest when client requests
unsupported version`). Also added a regression test pinning
`notifications/initialized` through the exempt path.

8 new tests (5 header + 3 negotiation). 1565 tests green; mix
credo --strict clean.

### Added — GEP-29 wave (c.2): creation + dispatch tools (19 tools total)

Wave (c.2) completes the core MCP write surface. External clients
can now scaffold companies + agents, create channels, submit
proposals through the GEP-28 outbox pipeline, and force agent
heartbeats — all the Director-side mutations the dashboard offers.

- `glorbo.force_agent_heartbeat(company, agent, reason?)` — wraps
  Actions.wake_agent. Writes the wake-request sentinel; audit
  actor is mcp:<client>.
- `glorbo.create_company(slug)` — wraps
  Scaffold.Company.scaffold/2 (new public API accepting base:
  opt). Idempotent (returns status=existed on re-scaffold).
- `glorbo.create_agent(company, slug, role?, provider?, model?,
  reports_to?, template?)` — wraps Scaffold.Agent.scaffold/3
  (promoted to public API). Default scaffold now honors
  `--model`; pre-existing CLI bug fixed in passing.
- `glorbo.create_channel(company, channel)` — initializes
  channels/<channel>.md with canonical channel-log/v1
  frontmatter.
- `glorbo.create_proposal(company, id, subtype, body)` — writes
  agents/mcp/outbox/proposals/<id>.md; the Router's GEP-28 D7
  outbox pipeline picks it up and validates. Synthetic `mcp`
  sender is stamped as `proposed_by` by the Router.
- `glorbo.decide_proposal(company, id, decision,
  denial_reason?, superseded_by?)` — same outbox pipeline for
  status flips (approved / denied / superseded). Router's
  self-approval guard blocks flips where sender == proposed_by.

Actions.wake_agent/4 gained an `actor:` opt (default "director")
to match the pattern established for post_message/set_approval
in wave (c.1). Scaffold.Company and Scaffold.Agent exposed
public `scaffold/2,3` entries with a `base:` opt so non-CLI
callers can target a non-default GLORBO_HOME.

Note: `dispatch_task` is intentionally not in the catalog — no
dedicated Actions entry exists; use `force_agent_heartbeat` to
wake the assignee after posting a task. Documented in GEP-29.

18 new tests (happy + traversal + idempotent + empty-body +
invalid-decision + missing-proposal). 1557 tests green; mix
credo --strict clean.

### Added — GEP-29 wave (c.1): first write tools (approvals + chat)

The MCP catalog grows its first mutation verbs. External clients can
now drive approvals and chat with the same side effects (audit, agent
wake on mentions, scaffold-on-approve) as the Director dashboard.

- `glorbo.approve_task(company, project, task_id)` — flips task
  status to approved, restores assigned_to from the sentinel,
  emits approval.approved. Same code path as the LiveView Approve
  button (`Actions.set_approval/4`).
- `glorbo.deny_task(company, project, task_id, denial_reason)` —
  same via set_approval with :denied. denial_reason required and
  must be non-empty.
- `glorbo.post_message(company, channel, body)` — appends with a
  `## <ts> | mcp:<client>` header, routes @mentions, triggers
  channel rotation. Uses `Actions.post_message/4`.
- `glorbo.capture_brain_dump(company, body)` — writes today's
  braindump file via `BrainDump.capture/4`.

**`Actions.post_message/4` and `Actions.set_approval/4` gained an
`actor:` opt.** Default stays `"director"` so every LiveView
callsite is unaffected. MCP tools pass `mcp:<client>` (GEP-29 D4)
so audit entries preserve provenance — a director clicking
Approve in the browser and an MCP client calling approve_task
both flow through the same code, but the audit log distinguishes
them.

Codex-reviewed; no must-fix. Two nice-to-haves applied inline:
- capture_brain_dump test asserts the `day` field shape so a
  later regression can't silently return nil on the wire.
- deny_task test clarifies the pre-serialization vs on-disk
  denial_reason shape (fake sink reads flat keys; JSONL folds
  non-core keys into `detail:`).

11 new tests (happy + traversal + empty-reason + channel auto-create
+ regression assertions). 1539 tests green; mix credo --strict clean.

### Added — GEP-29 wave (b.2): read-catalog completed (13 tools total)

Six more read-only MCP tools land, finishing the read side of the
catalog. External MCP clients now have full browse parity with the
Director dashboard.

- `glorbo.get_proposal(company, id)` — one proposal's frontmatter
  + markdown body.
- `glorbo.list_channels(company, include_dms?)` — enumerate chat
  channels. DMs excluded by default.
- `glorbo.get_channel(company, channel, since?, limit?)` — message
  stream, newest-first. `since` uses proper DateTime comparison.
- `glorbo.list_pending_approvals(company)` — walks
  `agents/*/state/awaiting-approval-*.md` sentinels; pairs each
  with its task title. Filesystem-first, no Ecto / supervisor
  dependency.
- `glorbo.query_audit(company, actor?, action?, since?, until?,
  q?, limit?)` — general audit log reader across multiple
  `audit/YYYY-MM.jsonl` months. Correctly walks year boundaries.
- `glorbo.get_company_health(company)` — aggregate counts
  (agents, projects, channels, proposals, tasks-by-status),
  pending-approval count, latest audit timestamp.

Codex-reviewed; two must-fix items applied inline:

1. Audit rows canonicalize on `"ts"` (per GEP-7 /
   `FileSpec.AuditMonthJsonl`), not `"timestamp"`. Prior revision
   would have silently returned empty time-filtered queries
   against real audit files.
2. ISO8601 timestamp comparison now goes through `DateTime.compare/2`
   for both `query_audit` and `get_channel`. Naive string `>=`
   was dropping fractional-second entries at boundaries because
   `"10:00:00.123Z" < "10:00:00Z"` lexicographically. Regression
   tests added for both tools.

21 new tests (happy + traversal + regression + malformed).
1528 tests green; `mix credo --strict` clean.

### Added — GEP-29 wave (b.1): six read-only MCP tools

Expand the MCP tool catalog from 1 to 7. External MCP clients can
now browse the filesystem-as-source-of-truth data structure without
scraping LiveView HTML.

- `glorbo.get_company(company)` — company.md frontmatter + counts
  (agents, projects, proposals).
- `glorbo.list_agents(company)` — every agent in the company with
  parsed AGENT.md summary (slug, role, provider, model, network,
  permissions). Unparseable AGENT.md entries are surfaced as
  `{slug, error}` rather than silently dropped.
- `glorbo.get_agent(company, agent)` — full AGENT.md spec incl.
  heartbeat, budget, autonomy, and canonical wire-format network
  value (`api-only` rather than the internal `:api_only` atom).
- `glorbo.list_tasks(company, project?, status?, assigned_to?)` —
  every task under `projects/*/tasks/*.md` with optional filters.
- `glorbo.get_task(company, project, task_id)` — full task
  frontmatter + body (agent prompt).
- `glorbo.list_proposals(company, status?)` — GEP-28 proposals
  with optional status filter.
- **`GlorboWeb.MCP.Args`** — shared slug-gate helper. Every tool
  argument that lands in a filesystem path runs through
  `require_slug/2` (alnum + hyphens only, same regex as the
  LiveView WR-02 defense). Rejects `"acme/../other"`, `"*"`,
  uppercase slugs, whitespace, and other traversal vectors with a
  `CallToolResult isError=true` response.
- 21 new tests (happy + filter + traversal-defense + malformed-
  entry branches).

Codex-reviewed; one must-fix applied: path-traversal /
wildcard-expansion defense via the shared slug gate. Nice-to-haves
(wire-format cleanup of `inspect/1` error payloads) deferred to a
follow-up.

1504 tests green; `mix credo --strict` clean.

### Added — GEP-29 wave (a): MCP server scaffolding (localhost HTTP-SSE)

Glorbo now exposes an MCP server at `POST /mcp` via the existing
Phoenix endpoint. Wave (a) ships the JSON-RPC 2.0 dispatcher, the
Streamable HTTP transport adapter, and the first tool — the rest of
the catalog lands in follow-up waves.

- **`GlorboWeb.MCP.Server`** — tool registry + JSON-RPC dispatcher.
  Handles `initialize`, `ping`, `tools/list`, `tools/call`.
  Protocol version `2025-06-18`. Unknown methods → `-32601`;
  malformed payloads → `-32600`; unknown tool → `-32000`. Tool-
  execution failures surface as spec-compliant `CallToolResult`
  frames with `isError: true`, not JSON-RPC errors.
- **`GlorboWeb.MCP.Plug`** — Streamable HTTP transport. Single
  endpoint handling POST (client JSON-RPC), GET → 405 (SSE streams
  land in a later wave), DELETE → 204. Notifications (no `id`)
  always return 202 regardless of method. Exact-host Origin check
  (`localhost`, `127.0.0.1`, `::1`) as DNS-rebind protection.
  `Mcp-Session-Id` stamped on the `initialize` response.
- **`GlorboWeb.MCP.Tool`** — behaviour the tool registry consumes.
  Per-request context carries `:client` (normalized MCP client name
  used as the `mcp:<client>` audit actor) and `:base` (injectable
  GLORBO_HOME).
- **`GlorboWeb.MCP.Tools.ListCompanies`** — first tool
  (`glorbo.list_companies`). Enumerates `<base>/companies/*` and
  returns `slug`, `name`, `headcount_budget` per entry.
- Router: `forward "/mcp", GlorboWeb.MCP.Plug`. Not behind the
  dashboard bearer-token gate — the plug's own Origin check +
  localhost endpoint bind are the outer boundary, matching GEP-6
  D5's trust model.
- 26 new tests: dispatcher unit (protocol methods, tools/list,
  tools/call happy + errors, CallToolResult round-trip) + Plug
  integration (JSON-RPC framing, notification semantics, Origin
  rejection including prefix-spoofing guards, method routing).

Codex-reviewed; three must-fix items applied inline before commit
(exact-host Origin match, generic notification handling, CallToolResult
wrapping for tool-execution errors).

1483 tests green; `mix credo --strict` clean.

### Changed — GEP-28 runtime wave 2b: outbox indirection for proposals (BREAKING pre-1.0)

Agents no longer have direct write access to `proposals/`. All agent-sourced
proposal creation and status flips flow through the Router via the per-agent
outbox, mirroring the existing tasks / comments / memory / path-request
patterns. This closes the wave 2a loophole where any agent with
`proposals:write:*` could flip its own `status: approved`.

- **`proposals:write:*` is removed.** Replaced by two narrower verbs:
  - `proposals:propose:*` — create a new proposal (outbox only).
  - `proposals:decide:*` — flip an existing proposal to
    `approved` / `denied` / `superseded` (outbox only).
- **CEO template** — carries `proposals:read:*` + `proposals:propose:*`.
  Guidance updated to drop files in `outbox/proposals/<id>.md`.
- **bwrap** — `proposals/` is RO-mounted for `proposals:read:*`, never
  RW for any template.
- **`Glorbo.Company.Router`** — new `{:proposal, id}` classification in
  `classify_outbox_file/3` + `handle_outbox_proposal/4` that validates
  (kind, subtype, id-matches-stem, permissions, create-vs-flip
  frontmatter rules) and writes `proposals/<id>.md` atomically. Stamps
  `proposed_by: <sender>` on create and `approved_by: <sender>` +
  `approved_at: <now>` on flip — both forge-proof. Rejects
  self-approval (`approved_by == proposed_by`) and clears stale
  terminal-state fields on re-transitions.
- **GEP-28** — D7 added (outbox-indirection decision). Permissions,
  Router-integration, and Failure-modes sections rewritten. `history:`
  frontmatter bumped.
- **Tests** — 15 new P-series tests covering create + flip (approve /
  deny / supersede) happy paths, permission rejections, content-rule
  rejections, stale-field cleanup on terminal-to-terminal flips, and
  YAML quoting round-trip for strings with reserved characters.

1457 tests green; `mix credo --strict` clean. Codex-reviewed with
two must-fix items applied inline before commit.

### Added — GEP-28 runtime wave 2a: ProposalsSink audit observer

Per-company GenServer subscribing to `company:<co>:proposals` PubSub and
emitting canonical `proposal.requested|.approved|.denied|.superseded`
audit entries whenever a `proposals/<id>.md` file transitions into a
known status. Best-effort — malformed or unknown-status files are
logged and skipped; never crashes the supervisor. Wired into
`Glorbo.Company.Supervisor` as child #10.

### Added — GEP-28 runtime wave 1: Watcher classifies proposals/*.md

- **`Glorbo.Filesystem.Watcher`** — classifies `proposals/*.md` writes
  as `:proposals`, reindexes them (via the existing `reindex_fun`),
  and broadcasts `{:file_event, rel, events}` on a new
  `company:<co>:proposals` PubSub topic. InboxLive and other
  downstream subscribers can now observe proposal activity without
  scanning the audit log. Pairs with GEP-28's spec scaffolding from
  the prior commit.
- 1 new regression test (`W6`) under
  `test/glorbo/filesystem/watcher_test.exs`.

1438 tests green; `mix credo --strict` clean.

### Added — GEP-28 scaffolding: agent-created proposals (spec + permissions)

**Scope of this commit: spec, permissions, docs, CEO template.** Runtime
wiring (Router classification of `proposals/*.md`, InboxLive surface,
Reindex table, headcount-budget auto-approval enforcement) is
**deferred to a follow-up** — see `user.md` for the split rationale.

- **GEP-28 Draft** — design record for agent-initiated hiring, firing,
  budget, and project proposals (`docs/geps/0028-agent-created-proposals.md`).
  The filesystem contract, frontmatter schema, and permission namespace
  land in this commit; Director-inbox flow and auto-approval land next.
- **`Glorbo.FileSpec.ProposalMd`** — new `proposal/v1` FileSpec
  implementation. Classifies `proposals/*.md` paths, validates
  frontmatter (`kind: proposal/v1`, `id`, `subtype`, `status`,
  `proposed_by`, `requires_approval`, `proposed_at`).
- **`Glorbo.Security.ACLMapper`** — added `proposals` resource to
  whitelist (`projects chat agents tasks proposals`). `proposals:write:*`
  maps to `rwx` on `proposals/`; `proposals:read:*` maps to `rx`.
  (Router-level enforcement that agents cannot flip their own
  `status: approved` is a known gap — see GEP-28 Failure Modes.)
- **`Glorbo.Sandbox.PermissionMapper`** — bwrap mount rules for
  `proposals:{read,write}:*` → `/proposals` in the sandbox.
- **`Glorbo.Agent.Server.permission_mount_summary/1`** — CEO runtime
  prompt now lists `/proposals` in its mounted-paths bullets so the
  agent discovers where to write.
- **CEO template updates** (`priv/templates/agents/ceo.md`) — added
  `proposals:write:*`, `allow_untracked_budget: true`, delegation
  discipline, proactive planning discipline, and `chat:` routing hint.
- **Company scaffold** (`lib/glorbo/cli/scaffold/company.ex`) — creates
  `proposals/` directory and sets default `headcount_budget: 3`.

### Fixed — Scheduler audit_fun arity + boot-time reindex

- **`Glorbo.Company.Scheduler`** — fixed `default_audit_fun` arity
  mismatch (was passing 2 args to a 1-arg closure). Added `catch :exit`
  to prevent scheduler crash when AuditLog is down.
- **`Glorbo.DB.Bootstrap`** — auto-migration child that runs on startup
  when `schema_migrations` table is missing. Fixes `glorbo reindex`
  chicken-and-egg on fresh workspaces.

### Fixed — Heartbeat dispatch on empty inbox (GEP-14)

- **`Glorbo.Agent.Server.resolve_task/3`** — when inbox scan returns
  `nil` and trigger is `:heartbeat`, synthesise a minimal task so the
  agent still dispatches. Previously, empty inbox → stay idle, which
  meant heartbeat-only agents (like the CEO) never ran their checklist.
- **`Glorbo.Agent.Server.read_system_prompt/2`** — concatenates
  `AGENT.md` + `SOUL.md` + `HEARTBEAT.md` into the system prompt.
  Previously, only `AGENT.md` was included; agents had no access to
  their voice or tick-by-tick checklist unless they manually read files.
- **`Glorbo.Sandbox.PermissionMapper`** — added `proposals:write:*` →
  `--bind <co>/proposals /proposals` and `proposals:read:*` →
  `--ro-bind <co>/proposals /proposals`. Previously, agents with
  `proposals:write:*` could not see `/proposals` in the sandbox.
- **CEO HEARTBEAT.md template** (`lib/glorbo/cli/scaffold/agent.ex`) —
  added kanban board scanning instruction: "Scan `projects/*/tasks/*.md`
  for tasks assigned to you that are not `done|closed|cancelled`".

1437 tests green; `mix credo --strict` clean; `mix gep.validate` clean.

### Added — GEP-27: Agent sandbox path requests via director approval

- **GEP-27 Draft** — design record for task-scoped external path access
  (`docs/geps/0027-agent-sandbox-path-requests.md`). Agents can request
  access to host paths outside their company sandbox; the director
  approves/denies each request and can downgrade write→read or trim
  individual paths. Access is ephemeral (task-scoped, revoked after
  dispatch).
- **`Glorbo.FileSpec.PathRequestMd`** — new `path-request/v1` sentinel
  spec. Agent writes `agents/<slug>/outbox/path-request-<task_id>.md`
  with a `paths:` list (`path` + `mode: read|write`) and a `reason:`.
- **`Glorbo.PathGrantStore`** — ETS-backed ephemeral grant registry.
  Keys are `{company, agent, task_id}`. Grants auto-clear on BEAM
  restart (correct for task-scoped semantics). Provides
  `grant/5`, `lookup/3`, `revoke/3`, `revoke_all/1`.
- **`Glorbo.PathRequestGate`** — per-company GenServer managing the
  request lifecycle: validate → pending sentinel → approve/deny →
  ETS grant → revoke. Validates paths (absolute, no traversal, no
  `/proc`/`/sys`/`/dev`), limits to 5 paths per request, requires
  reason ≥ 10 chars. Cross-company paths are forced read-only.
  Archives processed sentinels under `state/path-request-archive/`.
- **Router integration** — `classify_outbox_file/3` now recognises
  `path-request-<task_id>.md` outbox files and routes them through
  `handle_outbox_path_request/4`. Validates `kind: path-request/v1`,
  `paths` list, and `reason` before forwarding to the Gate.
- **Dispatch integration** — `build_ctx/6` queries `PathGrantStore`
  for active grants at dispatch time and injects them into
  `bwrap_opts.approved_paths`. `do_execute/4` revokes the grant
  after dispatch completes (success or failure).
- **Bwrap mount flags** — `Glorbo.Sandbox.Bwrap` now accepts
  `approved_paths` in invocation opts. Each path is mounted under
  `/external/<basename>` with `--ro-bind` (read) or `--bind`
  (write), spliced after permission-derived mounts.
- **Company Supervisor** — starts `PathRequestGate` as a child
  (10 children base, 11 with api-only + Proxy). ETS table
  initialised at supervisor boot.
- **Tests** — `FileSpecTest` updated for 21 specs (was 20).
  `Company.SupervisorTest`, `ApplicationTest`, `WatcherTest` updated
  for new child counts. `DispatchTest` and `EmergencyStopTest`
  initialise `PathGrantStore` ETS in setup.
- **UI surfaces** — InboxLive renders pending path requests with
  approve/deny/archive actions; AgentLive gains a "path requests"
  tab listing pending requests; TaskLive shows active external path
  grants in the usage strip.
- **Bug fixes (discovered during UAT)** —
  - Router `forward_to_path_request_gate/4` used atom-key access
    (`meta.paths`) on a string-key Map from `Frontmatter.parse`;
    fixed to `Map.get(meta, "paths")` / `Map.get(meta, "reason")`.
  - `PathRequestGate.build_pending_sentinel_path/3` generated
    `path-pending-<seq>.md` which did not match `@pending_regex`
    (`path-pending-<task_id>-<seq>.md`); fixed filename format.
  - `PathGrantStore.revoke/3` crashed with `ArgumentError` when the
    ETS table was missing (e.g. in isolated test contexts); added
    `:ets.info/1` guard. Same guard added to `lookup_by_task_id/2`.
- **Docs** — `docs/file-formats/path-request_v1.md` generated;
  `docs/file-formats/README.md` index updated. GEP-27 status
  updated to `Implemented`.

1436 tests green; `mix credo --strict` clean; `mix gep.validate` clean.

### Added — GEP-23 smart-mode Phase 3: supervisor composes classifier_fun (#321)

- **`Glorbo.Company.Supervisor` now composes a per-company
  `classifier_fun`** at proxy-boot time by scanning each agent's
  `egress:` frontmatter block. The first agent with `mode:
  :strict` or `:smart` drives classifier behaviour for the
  whole company (coarse-grained — the proxy can't yet
  distinguish which agent opened the connection; per-dispatch
  token plumbing is the Phase 4 step).
- **Legacy mode unchanged.** Agents with no `egress:` block or
  `mode: :allow|:deny` don't trigger a classifier. Existing
  `network: api-only` companies without any smart-mode opt-in
  keep the allowlist-only path bit-for-bit.
- **Wires directly to Phase 1's `SmartClassifier.smart_classify/
  3`.** Mode `:smart` → rule layer first, then the current stub
  LLM (`default_llm_classify/3`); mode `:strict` → rule layer
  only, unknown returns `:unknown`.
- 3 new regression tests: no-opt-in → nil classifier; smart
  agent's allow list + deny list honoured in the composed fn;
  strict agent returns `:unknown` on no-rule-match.

1436 tests green; credo clean. Phase 4 (real LLM wiring +
director-approval sentinel for `:unknown` verdicts +
per-dispatch ephemeral tokens) is the remaining GEP-23 work.

### Added — GEP-23 smart-mode Phase 2: classifier hook in Network.Proxy (#320)

- **`Glorbo.Network.Proxy` gains an optional `classifier_fun:`
  start-option.** Unlisted hosts — previously an unconditional
  403 — now flow through the classifier when one is set. Allow
  verdicts open the tunnel to upstream; deny and unknown both
  respond 403 (Phase 3 will make `:unknown` surface a director-
  approval sentinel instead).
- **Fail-safe.** A classifier function that raises, exits, or
  returns anything unexpected is treated as `:unknown` — a
  broken classifier never silently allows unknown hosts.
- **Backwards-compatible.** Existing callers that don't pass
  `classifier_fun:` keep the legacy allowlist-only behaviour
  bit-for-bit. `Glorbo.Company.Supervisor`'s proxy composition
  untouched for now; wiring per-agent `egress:` blocks (from
  Phase 1) into the supervisor's `classifier_fun` factory is the
  Phase 3 step.
- Proxy state map refactored: the `allowlist` MapSet is now
  under `state.policy.allowlist` alongside
  `state.policy.classifier_fun`; `Glorbo.Company.SupervisorTest`
  updated accordingly (4 assertions renamed from
  `state.allowlist` to `state.policy.allowlist`).
- 5 new regression tests in `test/glorbo/network/proxy_test.exs`
  covering: allow-verdict tunnel attempt, deny-verdict 403,
  unknown-verdict 403, classifier-raise fail-safe, and that the
  classifier is NOT consulted when the host is already in the
  allowlist.

### Added — GEP-23 smart-mode Phase 1 (#287)

First slice of GEP-23 smart mode: the pure classifier module and
AGENT.md parser support. Proxy wiring, per-company decision cache,
budget accounting, and UI follow in later phases so each step has
a small, auditable blast radius.

- **`Glorbo.Network.SmartClassifier`** — rule-based classifier
  (`classify/2`) + LLM-fallback orchestration (`smart_classify/3`)
  with dep-injected `classify_fun:` so the real provider
  integration lands later without churning this surface. Rules
  cover: allow/deny exact + `*.suffix` wildcards, RFC1918 /
  loopback / link-local private-IP rejection, ad-TLD rejection,
  mode-aware fallthrough semantics. Never returns `:unknown` from
  the rule layer unless `mode: :strict | :smart` with no rule
  match.
- **Prompt builder** (`build_prompt/3`) renders the classifier
  prompt with director-declared `smart_allow:` / `smart_deny:`
  category strings. Sanitises the host to alphanumeric + dot +
  hyphen before substitution (prompt-injection defence per
  GEP-23 §Smart mode). Caps to DNS max 253 chars.
- **Response parser** (`parse_response/1`) requires the exact
  `verdict|category|rationale` single-line format. Multi-line
  responses, bad verdict tokens, and empty fields all reject to
  `{:error, reason}` — fail-safe defence against a prompt-
  injected classifier trying to tack on "SYSTEM: ignore
  previous" lines.
- **`default_llm_classify/3`** stub ships returning `:unknown` so
  Phase 1 can land without a live LLM dep. Phase 2 swaps it for
  a dispatch through `Glorbo.Agent.Dispatch` with per-request
  budget accounting.
- **AGENT.md `egress:` frontmatter** — new `Parser.validate_egress/1`
  accepts `mode: allow|deny|strict|smart`, `allow:` list,
  `deny:` list, `smart_allow:` string, `smart_deny:` string,
  `smart_model:` override. Missing block defaults to
  `mode: :allow` + empty lists (matches the legacy allowlist
  behaviour the existing `Network.Proxy` enforces today — zero
  behaviour change for agents that don't opt in).
- `Glorbo.Agent.Spec` carries the parsed block as the new
  `egress:` field.
- 26 unit tests covering rule layer, LLM dispatch, prompt
  rendering, response parsing, and the fail-safe paths.

1428 tests green; credo clean; `mix glorbo.docs.file_formats
--check` clean.

### Added — mix glorbo.docs.file_formats + precommit wiring (R26.2b)

- **New mix task** `glorbo.docs.file_formats` generates one
  `docs/file-formats/<kind>.md` page per registered
  `Glorbo.FileSpec` module. Content is synthesised from each
  spec's `docs/0` (title, summary, examples),
  `frontmatter_schema/0` (required/optional keys, enums,
  patterns, caps), and `canonical_key_order/0`. Plus an index
  `docs/file-formats/README.md`.
- **`--check` mode** lists any drift between the generator's
  output and the committed tree, and raises `Mix.Error` when
  drift is detected — wired into `mix precommit` so spec
  changes must include regenerated docs in the same commit.
- **21 generated pages** shipped (20 file-spec kinds + README).
  Every page carries a machine-generated banner and links back
  to its source `lib/glorbo/file_spec/<name>.ex`.
- 3 new regression tests: every-kind coverage, generator
  idempotence, `--check` drift detection.
- Closes the GEP-25 R26.2 umbrella.

### Added — bench-softdev Python + Go fixtures (#309 partial)

- `priv/templates/companies/bench-softdev/` now ships three
  language analogs of the same three-bug shape:
  - **Elixir** (existing) — `projects/bugs/` + `fixtures/repo/`.
  - **Python** (new) — `projects/bugs-py/` + `fixtures/repo-py/`.
  - **Go** (new) — `projects/bugs-go/` + `fixtures/repo-go/`.
- Each language exposes the same bug triad: session-timeout
  constant (`bugs-*-1`), state-toggle extension with error path
  (`bugs-*-2`), HTML XSS sanitiser (`bugs-*-3`). Nine tasks total;
  all start `status: todo`.
- Engineer + reviewer `AGENT.md` permissions widened to
  `projects:write:bugs`, `bugs-py`, `bugs-go`; `AGENT.md` prose
  updated to name the three fixture dirs and explain routing
  (task id prefix → codebase).
- **CompanyTemplate scaffolder routing fix.** Filename → project
  resolution now uses a longest-prefix match against the
  template's `projects/<name>/` dirs (was: blind split on first
  `-`). Required for `bugs-py-1.md` → `projects/bugs-py/`, not
  `projects/bugs/`.
- js/ts, c++, java variants remain queued as follow-up subtasks.

### Changed — README tagline

Added "Like Obsidian, but for your agents." inline with the
existing "Everything is markdown. Everything is a file..." mantra
paragraph. Opening positioning is now the Obsidian analogy for
readers who click through from HN/GitHub; the filesystem-as-truth
line anchors the rest.

### Added — descriptive-filename task resolver (#314)

- `GlorboWeb.TaskLive` now resolves `<project>-<NN>` URL shapes
  against both canonical `<project>-<NN>.md` and descriptive
  `<project>-<NN>-<slug>.md` filenames on disk. Exactly one
  match serves; zero → flash + redirect to kanban; two or more
  → flash with the list of ambiguous filenames. Directors can
  keep descriptive suffixes in hand-authored tasks while links
  use the canonical id shape everywhere else.
- 2 regression tests cover the one-match and ambiguous-match
  paths.

### Added — "Wake all" director-origin heartbeat broadcast (#315)

- **CompanyLive header "♻ wake all" button** — dispatches
  `:director` wake to every `{:agent_server, <co>, <slug>}` pid
  registered for the company. Emits
  `director.heartbeat_broadcast` audit with `agents_woken` and
  `errors` detail. Disabled when emergency stop engaged (with
  a tooltip explaining why) since wakes would be no-ops. Flash
  surfaces "Woke N agents.", "No running agents to wake.", or
  partial-failure counts.
- 3 regression tests: button renders, zero-agent click surfaces
  the correct flash, emergency-stop state disables the button.
- Uses `Registry.select/2` with an `{{{:agent_server, co, :"$1"}
  :"$2", :_}, [], [{{:"$1", :"$2"}}]}` match spec; mirrors the
  pattern already used for audit-log lookups in the same module.

### Changed — HEARTBEAT + bench SOUL self-improvement and anti-AI-tells

- **Every HEARTBEAT.md template now includes a "Self-improvement"
  section** (priv/templates/heartbeats/*, bench-template
  heartbeats, the default scaffold fallback, and the acme CEO
  heartbeat in Init.ExampleCompany). The block tells the agent
  their instructions, soul, and memory are editable; defines
  triggers (own work, director correction, peer insight, research);
  points at the GEP-21 memory-write protocol.
- **Bench-template writer + editor SOUL.md gain "red flags I cut"
  sections** listing common LLM-output tells: Rule-of-Three robot
  cadence, signposted structure, empty intensifiers, hedge stacks,
  "it's not X, it's Y", symmetric parallel structures, circular
  conclusions. Applies to bench-scifi-publisher/writer and
  bench-tech-blog/editor — the two roles actually producing
  reader-facing prose.

### Added — GEP-26 Draft + benchmark templates Phase A

- **GEP-26** — benchmark company templates + provider A/B comparison
  (`docs/geps/0026-benchmark-templates-and-ab-comparison.md`). Draft
  status. Scope: cross-provider blind A/B scoring; two-phase
  implementation shipped back-to-back (Phase A templates now, Phase
  B scoring UI immediately after). 10 decision-log entries.
- **`company-template/v1` kind** — new FileSpec module registered.
  Total spec count now 20+ (goal/v1, config/v1, emergency-stop/v1,
  inbox-message/v1 shipped in preceding UAT-finding commits;
  bench-template follow-on spec shipped in Phase B).
- **3 bench templates under `priv/templates/companies/`**:
  - `bench-softdev` — engineer + reviewer agents working on a
    frozen Elixir codebase (`fixtures/repo/`). 3 tasks (1
    in-progress: dark-mode toggle): timeout constant fix, dark
    mode, XSS sanitizer.
  - `bench-tech-blog` — researcher + editor drafting posts from a
    frozen news archive (`fixtures/news/`). 2 tasks, 1
    in-progress.
  - `bench-scifi-publisher` — worldbuilder + writer against a
    static canon bible (`fixtures/canon/`). 2 tasks.
- **`Glorbo.CLI.Scaffold.CompanyTemplate`** — scaffolder that
  renders template frontmatter placeholders (`{{ slug }}`,
  `{{ provider }}`, `{{ model }}`), routes tasks by filename
  prefix to the right project, and symlinks `fixtures/` read-only
  (RO copy fallback if symlinks fail).
- **CLI**: `glorbo new company <slug> --template <name>` and
  `glorbo bench list`. Template version is checked against
  installed Glorbo via `min_glorbo_version:`.
- **Task priority schema changed** — `p0..p3` → `low | medium |
  high | critical`. (Zero users pre-1.0; atomic cut per the
  "no kid gloves" rule.)
- **ProjectMd gains `status: active|paused|done|archived`** — was
  previously in writer output but not in schema.
- **CompanyMd schema gains** `template`, `template_version`,
  `provider_pin`, `model_pin`, `icon`, `budget` keys — covers
  both bench-scaffolded companies and the CompanyLive editor's
  existing emissions.
- **Validator excludes `fixtures/`** — bench-template fixture
  trees are agent inputs, not Glorbo-owned data.

1394/1394 tests green. `glorbo validate` yields 0 errors / 0
warnings / 0 info on a scaffolded bench company. `mix gep.validate`
green with GEP-26 registered.

### Changed — GEP-25 atomic `kind:` cut, writers (R26.2a)

Per GEP-25 D9 + the pre-1.0 "no kid gloves" rule, every file Glorbo
writes now carries a `kind: <name>/v1` discriminator in its frontmatter
(or top-level JSON/JSONL object). No soft-migration fallback — readers
that care about kind (router's memory-write path, task outbox route)
reject files without it.

Writers updated:

- Scaffolders: `glorbo new {company,project,agent,skill}` emit the
  correct `kind:` line before anything else; templates that back agent
  scaffolds (HEARTBEAT.md, SOUL.md default bodies) include `kind:` too.
- `Glorbo.Init.ExampleCompany` — `glorbo init` acme seed now stamps
  `kind:` on company.md / AGENT.md / HEARTBEAT.md / general channel.
- `Glorbo.Company.AuditLog` — every JSONL line carries
  `"kind": "audit-event/v1"` as its first key.
- `Glorbo.Inbox.Archive` — `_inbox_archive.json` is now an object
  `{ "kind": "inbox-archive/v1", "keys": [...], "updated_at": "..." }`
  instead of a bare array.
- `Glorbo.Approvals.Gate` — awaiting-approval sentinel gains
  `kind: sentinel-approval/v1`.
- `Glorbo.Agent.LoopDetector` — stuck sentinel now uses the canonical
  `kind: sentinel-stuck/v1` (was `kind: loop_detected`).
- `Glorbo.Company.TaskScheduler` — scheduled inbox messages get
  `kind: inbox-message/v1`.
- `Glorbo.Company.Router` — memory-index upserts emit a kind-bearing
  frontmatter block; memory writes now REJECT incoming files missing
  `kind: agent-memory/v1`; outbox-filed tasks now REJECT files missing
  `kind: task/v1`.
- `Glorbo.BrainDump` — first write of the day wraps the section in a
  `kind: braindump/v1` frontmatter; brain-dump → task conversion
  stamps `kind: task/v1`.
- `Glorbo.EmergencyStop` — company stop sentinel carries
  `kind: emergency-stop/v1`.
- `Glorbo.TaskDefinition.write_frontmatter/2` — the editor-allowlist
  rewriter now preserves the file's original `kind:` line (or falls
  back to `task/v1`) instead of dropping it.
- `Glorbo.Chat.Rotation` — archive segments include
  `kind: channel-log/v1` + `archive_of:` / `rotated_from:`.
- `GlorboWeb.ChannelLive` / `PageController` — new channel creation +
  director/agent DM channels stamp `kind: channel-log/v1`.
- `GlorboWeb.CompanyLive` — company editor rebuilds frontmatter with
  `kind` + `slug` at the top.
- `GlorboWeb.KanbanLive` — task creation injects `kind: task/v1`;
  assignment inbox notify now uses canonical
  `kind: inbox-message/v1`.
- `GlorboWeb.ProjectLive` — bootstrap `project.md` seed now
  contains `kind: project/v1` + slug.

Router parser enforcement (load-bearing per D9):

- `task/v1` required on outbox-filed task.md — missing kind rejects
  the route + audits.
- `agent-memory/v1` required on memory-outbox file — missing kind
  rejects the write + audits `memory.rejected`.

Fixtures + tests: 6 router-test fixtures and 4 stuck-sentinel tests
updated to the new `kind:` shape; full suite green (1394 tests,
0 failures, 1 skipped). R26.2b (templates + per-kind golden fixtures
+ parser enforcement beyond router) follows.

### Added — GEP-25 formatter + `glorbo fmt` (R33)

- **`Glorbo.FileSpec.Formatter`** — canonical-form rewriter for
  Glorbo-owned markdown files. Reorders YAML frontmatter keys
  per each spec's `canonical_key_order/0`, normalises `---`
  fences, ensures trailing newline, preserves body byte-for-byte.
  Unknown frontmatter keys land alphabetically after the known
  block. JSON/JSONL files skipped; unknown paths skipped.
  Idempotence is load-bearing — `format(format(x)) == format(x)`
  asserted by fixture round-trip.
- **`glorbo fmt [PATH] [--check|--write]`** — default `--check`
  reports drift and exits 1 if any file would change; `--write`
  applies via atomic tmp+rename (same pattern as
  FrontmatterWriter / Router / Memory.Writer). No other cleanup
  on disk — `.tmp.*` files never leak.
- `Glorbo.FileSpec.Formatter` is the file-rewriter; the R27 CLI
  findings formatter was renamed to
  `Glorbo.FileSpec.FindingsFormatter` to avoid ambiguity.

14 formatter unit tests + 2 CLI smoke tests. 1394/1394 green.

### Added — R30.2: dispatch fallback + Doctor OS split

- **`Glorbo.Sandbox.Unsandboxed.start/2`** — sibling runner to
  `Glorbo.Sandbox.Bwrap.start/2` that skips every isolation flag
  and invokes the CLI directly via the same sh-wrapper + prompt-
  tempfile pattern. Tees stdout into `agents/<slug>/stdout.log`
  so the dashboard still sees output.
- **`Agent.Dispatch.default_run_fun/4`** now probes
  `Glorbo.Sandbox.Bwrap.availability/0` per invocation. On
  `{:error, :unavailable}` (macOS, bwrap-less Linux hosts) it
  emits `agent.sandbox_unavailable` audit ONCE per company per
  BEAM boot and runs via `Unsandboxed.start/2`.
- **`Glorbo.Doctor.run_checks/1` OS-aware reclassification.**
  On darwin, the four Linux-only probes (`linux_kernel`,
  `uidmap`, `bwrap`, `user_namespaces`) return synthetic
  `pass: true` with severity `:info` and detail
  "skipped on <os> (linux-only prerequisite; agent runtime runs
  unsandboxed here)". Check-list length stays 10 so existing
  tests don't churn; exit code math unaffected since `:info`
  entries aren't blockers.

macOS binaries now start + run `glorbo doctor` honestly + dispatch
agents without raising. Directors see exactly one
`agent.sandbox_unavailable` row per company boot making the
degraded-mode explicit.

### Added — R30.1: macOS build plumbing

- **Burrito targets gain `macos_x86_64` + `macos_arm64`** in
  `mix.exs`. `mix release` on macOS runners emits the darwin
  binaries the release workflow packages.
- **CI workflow adds a parallel `build-macos` matrix job** running
  on `macos-13` (Intel) and `macos-latest` (Apple Silicon).
  Compiles, builds the Burrito release, runs the smoke suite
  (`glorbo doctor --json` version check, help exit code, unknown-
  verb exit 1), and uploads the binary as an artifact alongside
  the Linux builds. `release` job now also signs and publishes
  the two darwin binaries + their `.sig` cosign bundles.
- **`Glorbo.Sandbox.Bwrap.availability/0`** returns
  `{:error, :unavailable}` on hosts without bwrap instead of
  raising. Callers that want to degrade gracefully (macOS) use
  this probe; callers that require sandboxing (Linux) keep
  calling `default_binary/0` which still raises on absence.
- **Homebrew formula generator** now expects 4 release assets
  (both linux + both darwin) and renders an `on_macos do` block
  alongside `on_linux do`. `depends_on "bubblewrap"` scoped to
  `on_linux do`; caveats explain macOS runs unsandboxed.

The Elixir runtime fallback (dispatch honours the availability
probe + emits a one-time `agent.sandbox_unavailable` warning
audit) and Doctor OS reclassification are R30.2. Until those
land, a macOS binary starts and `glorbo doctor` runs, but agent
dispatches will raise on bwrap absence.

### Added — Homebrew tap (R29)

- **`brew install foobarto/tap/glorbo` works end-to-end (#300).**
  The tap repo at <https://github.com/foobarto/homebrew-tap> now
  ships `Formula/glorbo.rb` pinning v0.0.4 Linux x86_64 + aarch64
  binaries + SHA256s. `depends_on :linux` guards macOS for now;
  `depends_on "bubblewrap"` wires the kernel-sandbox prerequisite.
  `brew audit --new` clean; `brew test` runs `glorbo doctor --json`.
- **`mix glorbo.release_formula [--tap-path PATH] [--write]`** —
  new Mix task that regenerates the tap formula from the current
  `mix.exs` version by fetching `SHA256SUMS` from the corresponding
  GitHub release and rendering the formula template. Run after
  each `gh release create`. Prints to stdout by default; pass
  `--write` to overwrite `<tap>/Formula/glorbo.rb` in place.

### Changed — GEP-25 TaskMd widen + skill/v1 (R28)

- **TaskMd regex widened (#299).** UAT ran the R27 validator
  against a real workspace and found that descriptive-slug tasks
  (`cut-release.md`, `drop-s3.md`) were reported as `unknown_file`
  — TaskMd's regex required the GEP-13 canonical
  `<project>-NN.md` form, but `Glorbo.TaskDefinition.parse_file`
  accepts any `*.md` under `projects/<p>/tasks/`. Spec now
  matches reality; a new info-level finding
  `:non_canonical_task_filename` surfaces non-canonical names
  without blocking CI.
- **`skill/v1` FileSpec module added.** Covers
  `priv/templates/skills/*.md` (builtin) and
  `~/.glorbo/skills/*.md` (user override); registry grows to
  16 kinds.

### Added — GEP-25 validator + `glorbo validate` (R27)

- **`Glorbo.FileSpec.Validator` + `glorbo validate` CLI (#298).**
  Read-only workspace health check driven by the R26.1 FileSpec
  registry. Walks a path, classifies every file, parses frontmatter
  (via `Glorbo.Filesystem.Frontmatter` for markdown, `Jason` for
  JSON/JSONL), and emits structured findings against each spec's
  declared schema. Ten check codes covering missing `kind:`,
  kind/path mismatch, YAML parse errors, missing-required-key,
  enum-out-of-range, pattern-mismatch, cap-exceeded, unknown-key,
  unknown-file, IO errors.

  Output modes: `:human` (one line per finding), `:json` (NDJSON
  per GEP-25 D6 — one finding per line + trailing `type:summary`),
  `:summary` (count-line only). Flags: `--json`, `--summary`,
  `--severity lvl`, `--kind kind`. Exit code 1 on any error-level
  finding, else 0.

  Verified end-to-end against a pre-cut workspace — reports 27
  `missing_kind` errors on the R22 UAT tree, exactly the diagnostic
  the atomic cut needs.

  Tests: 14 validator unit cases covering every check code + 2
  CLI smoke tests + a help-text regression.

### Added — GEP-25 scaffolding (R26.1)

- **`Glorbo.FileSpec` registry + 15 per-kind spec modules.** Pure
  catalogue of every markdown-with-frontmatter or JSONL/JSON file
  Glorbo reads or writes (`company/v1`, `agent/v1`, `project/v1`,
  `task/v1`, `agent-heartbeat/v1`, `agent-soul/v1`,
  `agent-memory-index/v1`, `agent-memory/v1`,
  `sentinel-approval/v1`, `sentinel-stuck/v1`,
  `sentinel-resolution/v1`, `braindump/v1`, `channel-log/v1`,
  `audit-event/v1`, `inbox-archive/v1`). Each module declares
  its `kind:` discriminator, frontmatter schema
  (required/optional/enums/patterns/caps), canonical key order,
  and docs. `classify_by_path/1` + `classify_by_kind/1` for
  lookup. No writer/CLI changes yet — the atomic `kind:` sweep
  across every writer + fixture + the validator/formatter land
  as R26.2.

### Fixed — post-release polish (R25, browser UAT)

- **Goal `name:` accepted as title fallback (#294).** GoalsLive
  and CompanyLive's goals panel expected `title:` on every goal
  entry under `goals:`. Directors reaching for the convention used
  on every other `company.md` field (`name:` on company, agent,
  project) got back `slug · slug` rendered with a muted separator
  — the same slug twice. Now both keys work; `title:` still
  preferred, `name:` falls back. Two new test cases cover the
  fallback on both views.

## [0.0.4] — 2026-04-21

Large release spanning browser-UAT rounds R14–R24 plus the GEP-20
director-dashboard UX sweep. Headline additions: file-based agent
memory (GEP-21) end-to-end, natural-language scheduler parser, per-
agent proxy allowlist extensions (GEP-23), loop-detector sentinel
resolution contract unification, and the unified Inbox.

### Added — director dashboard UX sweep (rounds 2+3, GEP-20)

- **Unified director inbox (`/companies/<co>/inbox`)** with Mine /
  Recent / All / Archive tabs. Aggregates pending approvals + the
  recent audit stream; inline approve / deny / archive actions on
  each row. Archive state persists at
  `audit/_inbox_archive.json` and survives reloads; Archive tab
  lists handled rows with an Unarchive escape hatch.
- **Dedicated goals view (`/companies/<co>/goals`)**. Reads
  `company.md` frontmatter `goals:` list, buckets every task by
  `goal:` reference, shows per-goal totals + status breakdown bar
  + deep link into a Kanban filtered by goal slug. Unassigned
  tasks roll up under a `(no goal)` card.
- **Skills marketplace (`/companies/<co>/skills`)**. Enumerates
  builtin skills under `priv/templates/skills/` alongside user
  overrides; classifies each as `builtin | custom | shadowed`;
  used-by counts per agent.
- **Per-goal Kanban filter** (`?goal=<slug>`) from GoalsLive,
  CompanyLive goals panel, or URL.
- **Agent config edit form.** AgentLive's right-column `config`
  panel gains an `edit` button that flips to a structured form
  for provider / model / reports_to / heartbeat / network. Writes
  allow-listed AGENT.md frontmatter keys via the new
  `Glorbo.Filesystem.FrontmatterWriter.update_keys/3` (preserves
  order, comments, indentation; atomic `.tmp` + rename).
- **14-day rollup strip on CompanyLive** — runs per day, success
  rate, tasks by status, tasks by priority. Data from
  `Glorbo.Activity.Rollup` (scans current + previous monthly
  audit JSONL; reads task frontmatter for status/priority
  buckets). Reuses `Components.Spark` + new
  `Components.StatBreakdown` (stacked segments + colour-coded
  legend with curated palette for known statuses).
- **Create-company wizard** chains the three existing modals
  (new-company → new-agent → new-project) via URL params
  (`?wizard=new_agent` → `?wizard=new_project`). 3-step
  breadcrumb renders inside each modal while a chain is active.
- **Two-letter actor avatars** on audit rows, channel messages,
  and inbox activity feed. `AuditEntry.actor_initials/1` +
  `actor_kind/1` public helpers; colour by kind (system /
  director / agent).
- **Inline slug-availability probe** on the new-company modal.
  150 ms debounced `phx-change` checks `File.dir?`; inline hint
  + green/red border + disabled submit when taken.
- **Command palette additions.** `⌘K / Ctrl-K` overlay now
  surfaces Inbox, Skills, projects from the sidebar, and
  `+ new agent` / `+ new project` action shortcuts.
- **Tool-call counts on agent.complete audit entries** (§2).
  `ClaudeJsonl` parser counts `tool_use` blocks per assistant
  message; Dispatch forwards `%{"Bash" => 1, "Read" => 2}` onto
  the complete-audit detail; AgentLive Runs tab shows `N tools`
  (collapsed) and `Bash×1, Read×2` (expanded). Opencode + Codex
  + Gemini parsers keep `tool_calls: nil` for now.
- **Activity sentences on audit rows** — `<actor> <verb> <object>`
  framing with delta rendering for status changes.
- **GEP-20** — Informational GEP retrofitting the scope, design,
  and decision log for this sweep. See `docs/geps/0020-round-2-
  3-ux-sweep.md`.

### Added — loop-session ship list (#230, #232 – #242, T1-E / T1-F / T2-B / T2-C / T2-D / T3-A)

- **Brain dump (`/companies/<co>/braindump`, `g b`)** — daily
  append-only capture log at `companies/<co>/braindump/YYYY-MM-DD.md`.
  Topbar "+ dump" button, convert-to-task action scaffolds into
  `projects/inbox/tasks/` with `source: braindump` frontmatter.
- **Per-task `model:` / `provider:` override (#235)** — task
  frontmatter pins a specific LLM for that dispatch; blank / nil
  falls back to the agent spec.
- **Agent model aliases (#236)** — optional `models:` map in
  AGENT.md (alias → concrete); tasks select by alias.
- **Natural-language heartbeat (#233)** — `heartbeat: "every
  morning at 9am"` compiles to cron at parse time. Literal cron
  passes through.
- **Ctrl+K content search (#232)** — `/api/search?co=&q=` JSON
  endpoint backing the command palette with task-title matches;
  ETS mtime cache skips re-parse on hot path.
- **Recurring tasks (#237)** — task frontmatter `schedule:` + auto-
  reset to `todo` when written `done`. Kanban card renders a `↻`
  pill with the schedule string.
- **Rolling-log rotation for channels (#238)** — oversized
  channel files (512 KB / 1500 lines default) rotate into
  `channels/archive/<channel>/<ts>.md` atomically.
- **Archive browser in ChannelLive (#239)** — collapsible list of
  rotated segments with inline viewer.
- **Named autonomy tiers (#231)** — `autonomy: manual | supervised
  | auto` on AGENT.md; metadata-only for now, runtime gate wiring
  is a follow-up.
- **Emergency stop (#241, T2-C)** — director-visible kill switch.
  Writes `companies/<co>/state/emergency-stop.md`, stops every
  running dispatch, refuses new ones until cleared. Pulsing red
  topbar chip when engaged.
- **Cost ledger page (`/costs`, #242, T2-D)** — per-agent monthly
  spend matrix for the last 12 months, top-spender card, drill-in
  link to AgentLive.
- **Per-company budget cap (#245)** — `company.md` frontmatter
  `budget_usd_cents_month:`. Dispatch refuses new work when the
  sum of every agent's month-to-date spend reaches the cap; an
  alert state fires between 80% and 100%. Complements the
  existing per-agent `budget_usd_cents_month:` on AGENT.md; both
  caps are independent — whichever hits first stops dispatch.
- **Per-task budget cap (#243)** — task frontmatter
  `budget_usd_cents:` caps what a single dispatch may cost.
  Post-dispatch check emits a `task.budget_exceeded` audit event
  when usage exceeded the cap; hard-stop enforcement
  (refuse the next re-dispatch if the prior one crossed the cap)
  is a follow-up.
- **Tokens + cost on Runs tab (#246)** — `agent.complete` audit
  events now carry `prompt_tokens`, `completion_tokens`, and
  (when pricing is known) `cost_usd_cents`. AgentLive Runs tab
  always shows `N in / M out` tokens; cost shows `$X.YY` when
  pricing for the provider/model is available, `—` when not.
- **Session resilience (#248, T1-A)** — dispatch now auto-retries
  on `:timeout` and `:reply_file_missing` with the prior attempt's
  summary appended to the prompt. Retry count caps at
  `AGENT.md` `max_retries:` (default 2, max 5). Non-recoverable
  errors (prompt size, unknown provider, budget stop, emergency
  stop) never retry — config problems don't self-resolve.
  Emits `agent.retry` audit per attempt for the history tab.
- **Ctrl+K finds audit rows (#249)** — palette search now
  matches on actor / action / target across the current month's
  audit JSONL, capped at the most recent 500 entries. Audit
  results carry `kind: audit` and navigate to the company's
  audit page; task-title and audit-row hits rank together so
  the single best match wins the top slot.
- **TaskLive usage strip (#252)** — dedicated task pages now
  show aggregated tokens + cost + dispatch count across all
  this task's `agent.complete` audits for the current month.
  Follows the #246 rule: tokens always, cost `—` when zero.
- **Goal progress bar (#253)** — `/companies/<co>/goals` each
  goal card now renders a coloured progress bar showing
  `done / total tasks · N%`. Colour state: muted (<50%),
  amber (50-99%), green (100%).
- **Audit → task conversion (#254)** — one-click "convert to
  task" on expanded audit rows. Scaffolds
  `projects/inbox/tasks/t-audit-<date>-<slug>.md` with a
  ```Context``` block containing the audit actor / action /
  target + the raw JSON payload for reference.
- **Audit CSV export (#259)** — `/companies/<co>/audit.csv`
  downloads the current month's audit log as CSV with columns
  `ts, actor, action, target, detail`. RFC 4180-compliant
  quoting. "⇩ export CSV" button on AuditLive header.
- **Audit date-range filter (#263)** — `since` and `until` date
  inputs on the filter bar narrow the visible rows by timestamp.
  Both bounds inclusive (00:00:00Z → 23:59:59Z). Composes with
  the actor / action / free-text filters.
- **Task history panel (#264)** — TaskLive renders a
  task-scoped slice of the audit log under the Sugar grid:
  every `agent.dispatch` / `agent.complete` / `agent.retry` /
  `task.update` row that targets this task. Expandable via
  the shared `AuditEntry` component, live-refreshing via the
  `company:<co>:audit` PubSub topic, capped at 25 entries.
  Deep-link "view full audit →" navigates to AuditLive with
  the task id pre-filled (`?q=<task-id>`). AuditLive now
  honours `?q=&actor=&action=&since=&until=` URL params so
  deep-links survive copy-paste.
- **`Glorbo.Audit.Query.for_task/4`** — tiny pure reader over
  the current-month JSONL; matches `target == task_path`,
  bare `task_id`, `detail.task_path`, or `detail.target`
  containing the id. Graceful on missing file / malformed
  JSON.
- **Scheduled-task "next fire" indicator (GEP-24).** TaskLive's
  usage strip now renders a `schedule · ↻ <cron> · next fire in
  2h 15m` row for tasks with a `schedule:`. New
  `Glorbo.Company.TaskScheduler.next_fire_at/2` soft API returns
  the armed `DateTime` or `nil` (tolerates a stopped scheduler
  via `catch :exit`). Relative formatter falls back to ISO
  timestamp for fires more than 7 days out so monthly crons
  don't render "in 720h". Docs retrofit in `GEP-0024`.
- **Task scheduler (#268)** — `Glorbo.Company.TaskScheduler`
  now actually fires dispatches from `schedule:` cron fields.
  On boot + on each `projects/**/*.md` write event the
  scheduler scans `projects/*/tasks/*.md`, parses each
  task's schedule (5-field cron or keyword alias —
  `hourly`/`daily`/`weekly`/`monthly` plus `@hourly` etc.),
  and arms a one-shot `Process.send_after/3` timer. Firing
  writes a synthetic `sched-<ts>-<task_id>.md` into the
  assignee's inbox with the task body as the prompt;
  Agent.Server's inotify watcher picks it up as a regular
  `:inbox` wake. Every fire emits
  `task.scheduled_dispatch` (appears in TaskLive history
  panel #264). Malformed schedules log
  `scheduler.invalid_task_cron` and are skipped — the
  scheduler never crashes on a bad cron. Zero state file;
  filesystem-is-truth invariant preserved. Until this
  landed the `schedule:` frontmatter field was rendered
  but never actually fired anything.

### Fixed — round 24 (browser UAT polish)

- **Truthful Inbox header (#292).** `/companies/<co>/inbox` used
  to say `Inbox (0 pending)` while a non-empty "Stuck agents"
  list rendered below — the count referenced only approval
  sentinels. Header now composes both counts:
  `(N approval[s] · M stuck)` when both present, `(N approvals)`
  or `(M stuck)` when only one, `(empty)` when neither. +1 test
  case asserting the header text for a seed with 1 approval + 1
  stuck.
- **Relative last-failure timestamp on stuck rows (#292).**
  Stuck-agent rows in InboxLive rendered raw ISO timestamps for
  `last_failure_ts`. Switched to `GlorboWeb.TimeFormat.relative/1`
  (same formatter audit rows use) so the row reads "3 min ago"
  / "2 hr ago" at a glance; ISO string kept in the title tooltip
  for precise auditing. Matches the TaskLive stuck-banner
  treatment.
- **UAT.md additions.** G6 (truthful inbox header), G7 (relative
  stuck timestamp), G8 (file-drop resolution path — R23
  regression) added under section G.

### Fixed — round 23 (browser UAT regression)

- **`agent.loop_resolved` audit row was missing in production
  (#291).** Browser UAT of the R21 file-drop resolution flow
  found that resolution files were being cleaned up, but no
  `agent.loop_resolved` audit row ever landed on disk. Three
  bugs compounded:

  1. `apply_one_resolution` always forwards
     `audit_fun: Keyword.get(opts, :audit_fun)` — nil when the
     caller (InboxLive/TaskLive load_stuck) didn't pass one.
     `resolve/5` used `Keyword.get_lazy`, which only fires when
     the key is *absent*, not when the value is nil — so
     `audit_fun` was `nil` and `nil.(company, entry)` raised.
  2. `emit_resolved_audit`'s rescue clause caught exceptions but
     not `:exit` signals; the compounding `GenServer.call` to a
     non-registered process raised exit, not a rescuable error.
  3. The default audit_fun called `AuditLog.append/1` (singleton),
     but AuditLog is started *per-company* under
     `Glorbo.Agent.Registry` — there is no singleton. The audit
     sink was therefore pointed at a non-existent process.

  Fixes: (a) coerce nil → default in `resolve/5`, (b) add
  `catch :exit, _ -> :ok` to `emit_resolved_audit`, (c) rewrite
  `default_audit_fun` to resolve the per-company audit server
  via Registry (same pattern as
  `Glorbo.Agent.Dispatch.default_audit_fun/2`). R23 verified
  end-to-end: file-drop → resolve → audit row written to
  `companies/acme/audit/2026-04.jsonl` with actor
  `agent:engineer` + decision `retry`.

  Test: +1 regression case asserting `resolve/5` with
  `audit_fun: nil` returns `:ok` and removes the sentinel,
  without propagating a crash.

### Fixed — round 22 (browser UAT)

- **Sidebar memory badge glyph (#290).** R20 used `✎` (U+270E) as
  the memory-count icon; it didn't render in the sidebar's
  monospace font (JetBrains Mono / Fira Code don't carry that
  codepoint) and fell back to a tofu box. Swapped to
  `<i class="fa-solid fa-brain">` — FontAwesome 6.5.2 is already
  loaded in the root layout, renders crisply, and is semantically
  closer to "memory" than the pen glyph. Badge layout switched to
  `inline-flex` + 3px gap so the icon and count sit cleanly
  together.
- **Sidebar memory badge aria-label plural fix.** Badge title +
  aria-label both said "memory files" regardless of count;
  singular-count rows now read "1 memory file". Extracted
  `pluralise_files/1` helper. +3 test cases on
  `GlorboWeb.Components.SidebarTest` cover the filename filter
  (valid types, wrong case, wrong extension, `MEMORY.md` index
  excluded) via a new `count_memory_files_for_test/2` helper.

### Added / Changed — round 21

- **Unified loop-detector resolution contract (#289).** The
  stuck-on sentinel body documented three resolution paths via
  `resolved-<decision>-<task-id>.md` file drops, but
  InboxLive/TaskLive buttons bypassed that contract entirely —
  they mutated the task frontmatter in-process and deleted the
  sentinel directly, so agents who followed the documented
  protocol were ignored.

  Both views now call a single `Glorbo.Agent.LoopDetector.resolve/5`
  entry point. The module also exposes `apply_resolution_files/3`,
  which scans `agents/*/state/resolved-{retry,skip,stop}-<task>.md`
  on every InboxLive/TaskLive render, applies any matching
  resolution, and deletes both the resolution file and the
  sentinel. Orphan resolution files (no matching sentinel) are
  cleaned up silently.

  Consequences:
  - **One code path**, not two. Retry/skip/stop semantics match
    whether the decision came from the UI button or a CLI agent
    dropping a file.
  - **Truthful sentinel body.** The documented file-drop protocol
    now actually works end-to-end.
  - **Single audit row per resolution** (`agent.loop_resolved`)
    with `actor` set to `"director"` (button) or `"agent:<slug>"`
    (file-drop). Replaces the previous implicit behaviour where
    only task mutations + sentinel deletion were recorded.
  - Director and agent can no longer race: each resolution file
    is keyed by `task_id`, and InboxLive applies them on render.

  Tests: 8 new cases on `Glorbo.Agent.LoopDetectorTest` cover
  retry/skip/stop mutation + sentinel cleanup + audit emission +
  custom actor propagation + file-drop application + orphan
  cleanup + malformed-filename tolerance + multi-agent batching.

### Added — round 20

- **Memory count badge on sidebar agent rows (GEP-21, #288).** Each
  agent row in the company sidebar now shows a subtle `✎ N` badge
  next to the slug when the agent has one or more memory files on
  disk. Directors can scan memory activity across the whole roster
  without clicking into each AgentLive Memory tab. Badge is hidden
  for agents with no memory directory or zero matching files; count
  uses the same filename regex as `Glorbo.Agent.Memory`
  (`^(user|feedback|project|reference)_...\.md$`) so invalid files
  never inflate the count. `File.ls` errors rescue to 0 — a
  permission glitch on one agent's dir never blanks the sidebar.

### Added — round 19a

- **Per-agent `network_allow:` proxy extensions (GEP-23, #283).**
  Agents whose AGENT.md carries `network: api-only` can now
  declare additional hosts in a `network_allow:` frontmatter
  list. Company.Supervisor unions those into the proxy's
  allowlist at boot, so directors can grant access to an
  internal dashboard or vendor API without touching the
  global `config :glorbo, :network_policy` base.

  ```yaml
  # agents/scout/AGENT.md
  ---
  slug: scout
  provider: claude-code
  network: api-only
  network_allow:
    - grafana.internal
    - ops.example.com
  ---
  ```

  Validation: hostnames must match `[a-z0-9]([a-z0-9-]*[a-z0-9])
  ?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+` — no schemes, no
  wildcards, no whitespace, no empty strings. Invalid entries
  are silently filtered so one typo doesn't poison the
  allowlist. Failures in `File.read` / `Frontmatter.parse`
  fall through to the base allowlist.

  Scope: coarse-grained per-company. Any api-only agent in the
  company can reach any host any sibling declared. Per-
  requester gating (distinct allowlists per agent identity)
  is tracked as R19b along with smart-mode LLM filtering.

  Tests: 4 new cases on `Glorbo.Company.SupervisorTest` cover
  frontmatter unions into proxy state; invalid hosts filtered;
  no-frontmatter agent inherits base only; multiple agents
  union. `Glorbo.Network.Proxy.default_allowlist/0` is now
  public so callers can compose the base.

### Added — round 18a (E2E backfill)

Per new feedback rule "ship E2E tests alongside features" — back-
filling integration coverage for recently shipped features that had
unit tests only.

- **NL schedule E2E (#286).** Two new cases in
  `test/integration/scheduled_task_e2e_test.exs` verify NL phrases
  (`every minute`, `every morning at 9am`) actually fire scheduled
  dispatches end-to-end — scheduler parses → arms timer →
  `send({:fire, task_id})` → inbox file on disk + audit. Unit
  tests on `Glorbo.ScheduleNL` proved the parse; these prove
  the fire path doesn't silently swallow the parsed cron.

- **Kanban filter chip E2E (#275 extension).** Two new cases
  exercise the full `navigate → mount → handle_params` pipeline
  after a chip click: dropping the assignee chip keeps the
  project filter applied, clear-all removes the entire chip bar.
  Unit tests checked chip rendering; these check the re-mount
  behaviour callers rely on.

- **Task-ID autolink E2E (#276 extension).** Two new cases mount
  TaskLive with a comment referencing `foo-2`, verify the rendered
  anchor URL is correct, and then mount kanban at that deep-link
  URL and confirm the referenced task's overlay renders. Unit
  tests checked the HTML anchor; these check the anchor actually
  navigates to something useful.

### Added — round 17b/17c

- **Agent memory writing — outbox → Router → disk (GEP-21, #284).**
  `Glorbo.Company.Router` now classifies two new outbox paths:
  - `agents/<slug>/outbox/memory/<type>_<topic>.md` → atomic
    write to `memory/<type>_<topic>.md` + upsert MEMORY.md index
    line + `memory.write` audit.
  - `agents/<slug>/outbox/memory/delete/<type>_<topic>.md` →
    delete the memory file + remove index line +
    `memory.delete` audit.

  Validation: filename matches `<type>_<topic>.md` (type ∈
  user|feedback|project|reference); body ≤ 8 KB; frontmatter
  `type:` matches filename prefix. On any failure, a
  `memory.rejected` audit lands and the outbox file is dropped
  so the agent doesn't retry forever on bad input.

  Atomic: tmp+rename on each write. Index uses match-by-
  filename dedup so repeat writes to the same memory replace
  a single line, not append duplicates. When the last memory
  goes, MEMORY.md is removed entirely.

  6 new unit tests on Router (write, replace, type-mismatch,
  oversize, invalid-filename fall-through, delete). Full suite
  1309/1309 green.

- **Memory tab on AgentLive (#284 UI).** New tab next to
  `history` surfaces MEMORY.md + each memory file's frontmatter
  name/description + body, sorted newest-first with relative
  mtime (`3 h ago`, `yesterday`). Type pill colours the row.
  Directors read agent memory without shell access. 3 new unit
  tests cover empty state, populated list, filename filter.

- **E2E memory with real CLI agent (#285).** Two new
  `:live_model` tests in `test/integration/opencode_lmstudio_
  live_test.exs` — skipped when LM Studio isn't serving qwen.
  (1) Seeds a unique token in memory, asks the model to
  recall, asserts the reply contains it (memory read path
  proven end-to-end with a real model). (2) Asks the model to
  write a memory via the outbox routing contract, pokes the
  Router with a simulated inotify event, asserts the file
  landed in `memory/` with correct content + index upserted +
  `memory.write` audit emitted. Both pass against live qwen
  3.6-35b on LM Studio.

### Added — round 17

- **Agent memory reading (GEP-21 / #281 MVP).** New
  `Glorbo.Agent.Memory.compose/3` reads `agents/<slug>/memory/` —
  `MEMORY.md` index + `<type>_<topic>.md` body files with
  `type` ∈ `user|feedback|project|reference` — and returns a
  single string capped at 20 KB suitable for prompt
  composition. `Agent.Server.compose_prompt/4` splices the
  result into the system prompt as a `## Memory` section
  between the permission-mount summary and the reply-hint.
  Bodies are sorted newest-first by mtime; overflow appends a
  `[N older memories not shown]` notice.

  This is the **reading half** of GEP-21. The writing path
  (agent outbox → Router classify → atomic write → MEMORY.md
  upsert + `memory.write` audit) ships next iteration as #17b.
  Validates the prompt-composition contract in production
  before the write contract is sealed — partials-first
  discipline per memory feedback.

  9 unit tests on the Memory module cover: missing dir → empty,
  empty dir → empty, index verbatim, newest-first ordering,
  filename filter (invalid types + slugs rejected), all 4
  valid type prefixes, 20 KB cap with truncation notice,
  malformed binary index graceful handling, empty index
  skipped.

### Added — round 16

- **NL schedule parser (#280).** Tasks can now use English
  phrases like `every morning at 9am` / `every weekday` /
  `every 5 minutes` / `every Monday at 6pm` in their `schedule:`
  frontmatter and the scheduler will actually fire them. The
  display layer has shown these since v0.0.3 but they used to
  fall through the 5-field cron parser into
  `scheduler.invalid_task_cron` oblivion. New
  `Glorbo.ScheduleNL.parse/1` converts NL → cron; TaskScheduler
  calls it before the Crontab.Parser fallback so 5-field crons
  still work unchanged. Grammar covers time-of-day
  (morning/evening/night/noon/midnight with default hours +
  optional `at <time>`), weekdays (Monday-Sunday + weekday /
  weekend buckets), and intervals (every minute / N minutes /
  N hours / hour / day / week). Closes the gap between #237
  display and #268 firing. 30 unit tests on the parser + 2
  scheduler-integration tests.

### Added — round 15

- **E2E LoopDetector sentinel emission test (#279).**
  `LoopDetectorTest` covered the pure detection logic +
  filesystem writes via stubbed fs_fun; this new integration
  test closes the loop by exercising `LoopDetector.check/3`
  against real disk I/O, seeding 3 prior failure audit rows
  and asserting the sentinel file lands at
  `agents/<slug>/state/stuck-on-<task>.md` with correct
  frontmatter + director-resolution instructions. Idempotency
  case confirms a second check doesn't overwrite. Second test
  case proves a clean audit leaves no sentinel. Was partial —
  unit tests mocked the fs, so nobody had confirmed production
  wiring writes a real file. Now proven.

### Added — round 14

- **E2E scheduled-task dispatch test (#278).** New integration
  test at `test/integration/scheduled_task_e2e_test.exs`
  exercises the TaskScheduler fire path against the real
  `default_write_inbox` (no test stub for the write): drives
  `:fire` directly so it's fast, but verifies inbox file lands
  on disk + audit event emitted. Second case confirms the
  fire-time re-read works — arming with body A then rewriting
  the task to body B before firing produces inbox body B. The
  `inotify → Agent.Server wake` half of the chain is already
  covered by `AgentWakeInboxTest`; between the two, scheduled
  dispatch is end-to-end proven.

### Added — round 13

- **Heartbeat cron validation on AgentLive config save (#277).**
  The AGENT.md edit form used to accept any string for the
  `heartbeat:` field — malformed crons saved silently and the
  scheduler would log `scheduler.invalid_cron` and skip forever,
  leaving directors puzzled about why the agent never woke.
  Save now validates via the same Crontab parser the scheduler
  uses, failing inline with a concrete error (`"Invalid
  heartbeat cron: <reason>. Expected a 5-field cron (e.g. \"0
  * * * *\") or blank for no heartbeat."`). Blank = no-heartbeat
  agent, still valid. Form stays in edit mode on failure so the
  fix doesn't lose the director's typed state. 2 new regression
  tests cover the invalid and blank paths.

### Added — round 12

- **Task-ID autolinking in comments (#276).** Task-ID tokens
  like `abc-02` / `glorbo-7` in TaskLive / Kanban-shelf comment
  bodies now render as clickable anchors to the kanban
  deep-link (`?task=projects/<proj>/tasks/<id>.md`), consistent
  with how channel messages handle the same tokens via
  `GlorboWeb.Markdown.Linkify`. XSS-safe: comment body is
  HTML-escaped before the linkifier runs. Directors cross-
  referencing tasks in review comments get one-click
  navigation instead of having to type the URL. 4 new unit
  tests on the shared TaskDetailForm component cover plain
  text, single / multiple task-IDs, and HTML-escape behaviour.

### Added — round 11

- **Kanban filter chip bar (#275).** When any of the kanban
  filters (`?project=` / `?goal=` / `?who=`) is active, a row of
  pill-shaped chips now renders below the page header listing
  the active filters with an `×` that drops just that filter
  while preserving the others. A "clear all" link on the right
  nukes every filter. Previously only `?project=` had any
  visible-clear affordance (the "× all projects" button); the
  goal and assignee filters were silently applied with no way
  to tell they were even on. Replaces that one button with a
  more discoverable, composable UI pattern. 3 new regression
  tests cover no-chips, single-chip, and multi-chip URL
  construction.

### Added — round 10

- **TaskLive stuck-on banner (#274).** When an agent gets
  flagged by the LoopDetector as stuck on a specific task, the
  sentinel now surfaces on the task page itself — not just in
  the inbox. Warning-tinted banner above the usage strip shows
  the stuck agent + detected-at timestamp + reason, with
  symmetric retry / skip (reassign to director) / stop (deny
  task) buttons. Clicking any action resolves immediately and
  refreshes the banner in place. The inbox still lists
  everything; this just puts the controls where the director
  is already looking. 4 new regression tests cover render +
  all three resolve paths.

### Fixed

- **Scheduler.invalid_task_cron audit flood (#273, UAT round 9).**
  A task with an unparseable `schedule:` field was re-emitting
  `scheduler.invalid_task_cron` on every 60-second rescan
  because the dedup logic looked up the previous value from
  `state.tasks[task_id]` — but the error branch was never
  writing back to state. Fix: threading the state through the
  error branch so a stub entry (`%{schedule: ..., invalid?:
  true}`) is stashed, making the next rescan's `prev[:schedule]
  == schedule` short-circuit work. `{:fire, task_id}` for
  stashed-invalid entries is guarded (should never arrive;
  defensive) so a scheduler bug can't dispatch an unparseable
  task. 2 new regression tests — repeated-scan no-flood and
  re-emit-on-change — cover the behaviour.
- **Close-button hover affordance (#273).** The `×` glyph on
  every modal looked like static text because it had no hover
  state. Added a subtle border + surface-raised background on
  `:hover`, plus a `:focus-visible` outline for keyboard
  navigation. No text-size change; the button reveals itself
  as interactive on hover.
- **Sidebar Approvals badge/list mismatch (#272, UAT round 8).**
  Previously the badge counted every `awaiting-approval-*.md`
  sentinel including orphans (matching task file absent), while
  ApprovalQueueLive and InboxLive filtered them out. Directors
  could see "1 pending" and click through to an empty list. Fix:
  the badge counter now validates each sentinel's `<task_id>`
  resolves to a real file under `projects/<proj>/tasks/<id>.md`,
  matching the view's filter. 6 new unit tests cover orphan /
  live / mixed / malformed-id cases.
- **Audit log ISO timestamps → relative `N min ago` (#272, UAT
  round 8).** The collapsed audit row rendered
  `2026-04-21 03:50:42.555059` which scans poorly in a
  fast-scrolling log. Now shows `"7 min ago"` / `"yesterday"` /
  etc. via the existing `GlorboWeb.TimeFormat.relative/1`
  helper; the absolute timestamp is preserved on hover (`title=`)
  and in the `datetime=` attribute for screen readers.
  Malformed timestamps fall back to the raw string — nothing
  crashes.
- **ESC key now closes the ApprovalQueueLive deny modal (#272).**
  Every other modal already wired `phx-window-keydown="<cancel>"
  phx-key="Escape"`; the approval-queue deny modal was the only
  holdout, so keyboard users had to click the `×` to dismiss.
  Now ESC universally closes modals.
- **`glorbo up` crash when EPMD not running (#271).** Cold-boot
  timing: `glorbo doctor` 145ms, `glorbo status` 141ms, warm
  `glorbo up → running` 417ms. Cold `glorbo up` on a host with
  no EPMD crashed immediately with `econnrefused` on port 4369
  (Burrito ships ERTS but not a running EPMD; `Node.start/2`
  with `:longnames` needs one). `Glorbo.CLI.Lifecycle.
  Distribution.start/0` now spawns `epmd -daemon` itself before
  the first `Node.start`. The call is idempotent (epmd refuses
  to double-bind). Prefer the `epmd` shipped with the current
  ERTS release (via `:code.root_dir/0`) over `$PATH` so the
  Burrito binary always gets a matching version.
- **Inbox deny modal styling (#269).** The deny-prompt modal in
  InboxLive used `gl-modal__body` + bare `gl-form__row` /
  `gl-form__label` classes that had no CSS backing — rendering the
  form unpadded and misaligned. Added generic rules for
  `.gl-modal__body`, `.gl-modal__body .gl-form__row`, and
  `.gl-modal__body .gl-form__label` matching the padding / grid
  pattern used by the `.gl-company-md-form` wrapper other modals
  share. Every modal with a form now renders consistently whether
  it uses the shared wrapper or the bare `__body` container.
- **Topbar shortcut strip overflow (#269).** The keyboard
  shortcut strip (`g o overview · g c chat · …`) wrapped onto two
  lines at ~1400 px wide and the second line overlapped the page
  title below. Added `white-space: nowrap` + `overflow: hidden` +
  `text-overflow: ellipsis` to the strip and `flex-wrap: nowrap`
  + `overflow: hidden` to the topbar — shortcuts truncate with
  `…` on narrow widths instead of reflowing into the content.
- **Modal close-button glyph (#269).** The `✕` (U+2715) character
  used on every modal close button rendered as a fallback boxed
  "X" because neither JetBrains Mono nor IBM Plex Mono ship the
  glyph. Replaced with `×` (U+00D7 multiplication sign) across
  every LV + the filetree delete / `org_state_glyph` / tool-count
  formatter — the multiplication sign is present in every mono
  font and visually identical when rendered correctly.

### Changed

- AgentLive Runs tab + CompanyLive roster now include tool-call
  indicators when available; collapse gracefully when the
  provider doesn't emit tool telemetry.
- Sidebar gains `Goals`, `Skills`, `Brain dump`, and `Costs` nav
  entries.

### Fixed

- **`PORT` env var now honoured by `mix phx.server`**. `config/
  dev.exs` hardcoded port 4000; set `PORT=4001 mix phx.server` to
  bind to an alternate port (UAT workflow).
- **Search endpoint (`/api/search`) now piped through the
  dashboard bearer-token gate.** On LAN exposure with
  `dashboard_token:` set, the palette API was enumerable without
  auth.
- **Recurring-task loop-back covers `write_frontmatter/2`**, not
  just `write/2`. The #237 commit missed a call site hit by agent
  self-reports, kanban detail-modal save, and denial actions.

---

## [0.0.3] — 2026-04-19

### Added

- **`glorbo import paperclip <src>`** — import a paperclip.ai
  `agentcompanies` tree into a Glorbo company directory. Detects
  paperclip's per-agent layout (`<agent>/AGENTS.md`, `HEARTBEAT.md`,
  `SOUL.md`, `TOOLS.md`), wraps each `AGENTS.md` in Glorbo
  frontmatter as `AGENT.md`, copies the rest verbatim, and prints a
  hint report naming every paperclip-ism (`$AGENT_HOME`,
  `PAPERCLIP_*` env vars, `paperclip-*` skills, `/api/...` HTTP
  calls) so the Director can hand-fix them. `--as <slug>` overrides
  the target name; `--force` overwrites only `agents/` on re-import.
- **Role-specific HEARTBEAT.md templates (GEP-14 extension).** CEO
  gets a 5-step company-stewardship loop (triage inbox → check
  roster → check goals → budget + health → exit cleanly) instead of
  the minimal 4-line default. Engineer + researcher get role-shaped
  per-tick checklists too. Scaffolding picks them up
  automatically via `priv/templates/heartbeats/<name>.md`.
- **CEO AGENT.md + SOUL.md expansion.** Active-stewardship system
  prompt (three concrete priorities: work flows / goals move /
  roster fits) + actions catalogue + constraints. SOUL gets
  owner-vs-observer stance.
- **Right-panel collapse on agent detail.** Thin 14px toggle rail
  between the center (stdout) and right (config + budget + perms)
  columns. Defaults collapsed on viewports < 1200px so stdout gets
  priority. Persists in localStorage.
- **Themed scrollbars** — universal scrollbar styling matches the
  phosphor palette (transparent track, thumb on
  `--gl-border-strong`, `--gl-accent-dim` on hover). Firefox
  + WebKit both covered.
- **`glorbo new agent <co>/<slug> --template <name>`** with
  SOUL.md + HEARTBEAT.md auto-wiring per template.
- **GEP-19 Director Approval Workflow Protocol** — retroactive
  Informational GEP capturing the `awaiting-approval-<task_id>.md`
  sentinel contract, frontmatter transitions, audit-event
  vocabulary, and the Gate-daemon vs UI-direct equivalence.
- **README dashboard screenshots** — six captures (overview,
  company, kanban, agent, approvals, providers) in a 2×3 table
  showing the terminal phosphor UI.
- **GEP-8 Provider Registry + CLI Auto-Detect** — config-driven CLI
  provider system. `priv/providers/*.toml` + optional
  `~/.glorbo/providers.toml` declare invocation shape, env overrides,
  reply contract, and usage-parser bindings. Six built-in providers:
  three tracked (`claude-code`, `codex`, `gemini-cli`) and three
  untracked (`hermes`, `opencode`, `pi`). New `/providers` LiveView
  dashboard. Detection runs on boot (PATH scan only); version probes
  run on explicit refresh and respect per-entry `allow_version_probe`
  opt-in for user-declared providers.
- `agent.md` gains `allow_untracked_budget: true` frontmatter opt-in
  for routing through `usage_parser = "none"` providers. Dispatch
  refuses otherwise.
- **Dashboard UX overhaul (M1-M5 sprint)** — mockup-aligned shell
  (tri-section sidebar, topbar with brand + company picker, terminal
  phosphor tokens), company overview with stat cards + agent roster
  + org chart, agent detail three-column layout (identity /
  tabbed stdout|sandbox argv|inbox-outbox|history / config + budget
  + permissions), Kanban drag-drop with status writeback to
  frontmatter, chat channel switcher + DM enumeration, approvals
  prompt-diff with `j/k/y/n` keyboard, audit unified free-text
  search, providers card grid with TOML snippet, global `g o/h/p`
  shortcuts, TWEAKS drawer with localStorage persistence, and
  `+ new company/agent/task` entry points that call the existing
  CLI scaffolds.
- **Approval workflow polish** — director/agent `assigned_to` swap
  on approval-request/grant/deny (requesting agent slug recovered
  via `awaiting-approval-<task_id>.md` sentinel when Gate isn't
  running), denial reason surfaced on approval card + threaded
  into audit JSONL + persisted to task frontmatter, denied-reason
  modal with Escape close, Gate audit events now use canonical
  `target:` field (matches UI-path shape).
- **Agent page interactions** — `edit AGENT.md` opens in-browser
  editor, `send message` opens Director DM, `stop` kills in-flight
  dispatch (proper reply tuple, tested), `wake` prompts for
  reason in a modal.
- **Chat ergonomics** — Enter sends / Shift-Enter newlines in
  channel compose, textarea autogrows with content, view fills
  viewport with messages scrolling under a pinned compose row,
  tail-pin autoscroll on new messages (user scroll-up unpins).
- **Stdout hardening** — mid-line `\r` and OSC window-title
  sequences stripped at the streamer (killed ghost gaps between
  paragraphs rendered under `white-space: pre-wrap`); trailing
  whitespace trimmed; autoscroll pins to bottom with tail-pin
  hook, unpins when user scrolls up; stdout pane stretches to
  viewport via `.gl-view--tall` opt-in.
- **Kanban** — drag-drop writes `status:` frontmatter, live task
  search across title/assignee/task_id, comment history in task
  detail modal, denial reason surfaced on denied cards, visual
  status tags for approved/denied, severity field wired
  end-to-end.
- **Accessibility sweep** — every role="button" surface gained
  `phx-keydown=… phx-key="Enter"` and a descriptive `aria-label`
  (task cards, agent table rows, approval rows, permission rows,
  file-tree actions became actual `<button>` elements, topbar
  TWEAKS button's aria-expanded reflects state).
- **Scaffolding entry points** — new-company / new-agent / new-task
  modals wire directly to `Glorbo.CLI.Scaffold.*`; scaffold "already
  exists" responses now surface as info (not error) flashes; the
  new-agent form's provider dropdown is populated from
  `Glorbo.CLI.Registry` and its HTML `pattern` matches the scaffold
  backend regex.

### Changed (Breaking)

- **Reply-file contract** (GEP-8 D1). Agents must now write their
  final reply to `$GLORBO_REPLY_PATH` — an absolute path exported to
  the CLI's env. On exit, an empty or missing reply file is an
  invocation failure. Existing agent system prompts must be updated
  to include a "write final answer to `$GLORBO_REPLY_PATH`" directive
  or their replies will surface as `:reply_file_empty` / `:reply_file_missing`.
- `Glorbo.Agent.Dispatch.execute/3` dep-inject keys changed:
  `:adapter_registry` + `:binary_fun` → `:provider_fun`. The
  `:run_fun` signature is now 4-arity
  `(args, env, bwrap_opts, run_opts_map)`.
- `Glorbo.CLI.Adapter` behaviour and its three implementations
  (`ClaudeCode`, `Codex`, `GeminiCli`) removed. Their parsing logic
  moved to `Glorbo.CLI.Parsers.{ClaudeJsonl, CodexJsonl, GeminiStdout}`.
- Gate audit event payloads renamed `task_path:` → `target:` and
  (for denials) `reason:` → `denial_reason:` so both daemon and
  UI-direct code paths emit identical JSONL shape.

### Fixed

- 5 Critical + 15 Important + 15 Minor code-quality findings from a
  2026-04-17 review. Notable: `Network.Proxy` pipe tasks now use
  `Task.Supervisor.async_nolink` (socket-cleanup ordering);
  `BudgetTracker.init` rehydrates `alerts_fired` from filesystem on
  crash (no duplicate alert files); `Company.Router` captures a
  single `DateTime.utc_now/0` per routing (filename + frontmatter
  now consistent); `Restore.extract` preserves pre-existing user
  data on symlink-escape rejection with `--force`;
  `Sandbox.Bwrap.drain_port` caps accumulated stdout at 16 MiB;
  `Ledger.record/1` (non-raising variant) added for callers that
  need error taxonomy.
- **Task body parser** — distinguishes markdown sub-headers (`###
  foo`) from new comment posts (`## YYYY-MM-DD …`); channel message
  parser gets the same treatment so agent-posted markdown with
  sub-headers doesn't fracture into spurious posts.
- **File editor modal** — X/cancel buttons now actually close; the
  blocking `onclick="event.stopPropagation()"` on the form was
  swallowing delegated phx-click events.
- **Agent status pill** — `:stop` now covers both director kills and
  unexpected crashes (was conflating `:idle` with `:stop`).
- **Approval flash** — UI-path denial no longer claims "moved to
  history" (that only happens via Gate; UI only rewrites
  frontmatter).
- **`gl-view--tall`** — correctly stretches via `flex: 1 min-height: 0`;
  previous commit introduced the class without the flex-grow.
- **Kanban layout** — all 4 columns fit without horizontal scroll.

### Meta

- GSD workflow retired 2026-04-17; design decisions now captured as
  GEPs under `docs/geps/`. The originally planned Podman
  container-runtime restoration has been dropped entirely (see
  GEP-5 D6); agents remain CLI-tool subprocesses under bwrap
  permanently.
- `skills-lock.json` pruned of 6 entries that weren't linked into
  `.claude/skills/` (docx / pdf / pptx / xlsx office skills,
  plus stale GSD plugins retired with the workflow).
- 895/895 tests passing, Credo strict clean, `mix gep.validate`
  clean at time of writing.

---

## [0.0.2] — 2026-04-16

> **Note on references below:** this entry was written while the
> `.planning/` GSD workspace was still live. Those paths were
> deleted 2026-04-17 (design records moved to GEPs under
> `docs/geps/`, everything else lives in git history). Path
> references below are left in place as they appeared at release
> time; `git log --all --diff-filter=D -- <path>` will find the
> deleted file if you need to read it.

Closes Milestone 01 (CLI-agent runtime) by shipping the dashboard and full CLI
surface on top of the v0.0.1 Phases 1-3 foundation. 5 phases / 20 plans / 219
commits / 621 tests green / 38-of-38 v0.0.2 requirements covered.

### Phase 5 — CLI Completeness + Backup/Restore Portability

#### Added

- Lifecycle verbs: `glorbo up` (detached daemon via `setsid`), `down`
  (SIGTERM → 10s grace → SIGKILL escalation), `status` (pidfile state
  machine: running/stale/missing), `serve` (foreground-blocking
  supervision tree start), and `run` (one-shot `reindex`-like scripts).
- Pidfile with atomicity invariants: `tmp + chmod 0600 + rename` write,
  fsync on close, mode-bit enforcement, TOCTOU re-check against the
  daemon pid at every lifecycle verb boundary.
- Scaffolding verbs: `new company <slug>`, `new agent <company>/<slug>`,
  `new project <company>/<slug>`. Slug regex guards against path
  traversal; default frontmatter matches DESIGN.md §5.
- `logs <company> [agent] [--follow]` with inotify-backed live tail;
  audit-log or `stdout.log` selection; rotation-aware (handles
  `YYYY-MM.jsonl` rollover without raising).
- `backup [--output <path>]`: WAL-checkpoint via
  `PRAGMA wal_checkpoint(TRUNCATE)` before archiving; `tar.gz` over
  `~/.glorbo/companies/`, `config.md`, and audit log; pidfile
  TOCTOU re-check between checkpoint and `:erl_tar.create`; chmod
  0600 on output; archive-bomb cap at 10 GiB uncompressed sum.
- `restore <archive> [--force]`: pre-extract traversal guard rejects
  entries starting with `/` or containing `..`; archive-size cap
  enforced from verbose tar table; post-extract symlink-target walk
  via `:file.read_link/1` rejects any symlink escaping the restore
  base (CR-01); post-extract chain `migrate → reindex → doctor --fix`
  (D-22); `:non_empty_base` guard bypassed only with `--force`.
- `console`: `iex --name console@127.0.0.1 --cookie <cookie> --remsh
  glorbo@127.0.0.1` against the running daemon; pidfile-gated
  (exit 3 if daemon not running); cookie read from
  `~/.glorbo/state/.erl_cookie` (mode 0600, atomic write).
- `migrate`: `Ecto.Migrator.run(Glorbo.Repo, _, :up, all: true)` with
  `rescue` for migration errors and `catch :exit` for Ecto exit signals
  (lock-contention / connection-pool failures surface as exit 2).
- `doctor --fix`: severity-weighted exit code (0 / 1 / 2), registry of
  7 fixers (`ollama_daemon`, `runtime_image`, `podman_missing`,
  `podman_socket`, `sqlite_wal`, `pidfile_stale`, `audit_dir_mode`),
  check→fix→recheck pattern; only counts `repaired` if recheck passes;
  missing-fixer for blocker checks returns non-zero.
- End-to-end portability test (`test/integration/portability_test.exs`):
  two-root A→archive→B extract + migrate + reindex + fixer roundtrip
  with hermetic hosts.
- Distribution release uses long-name node (`-name glorbo@127.0.0.1`)
  in `rel/vm.args.eex` to support `console` remsh (short-name rejected
  by BEAM when qualified with host).

#### Security

- **CR-01** — symlink-target path-traversal bypass: archives with benign
  entry names but escaping `linkname` no longer extract successfully;
  post-extract walker wipes partially-extracted base if any symlink
  resolves outside `~/.glorbo/`.
- **WR-03** — archive-bomb DoS vector closed: restore refuses archives
  whose uncompressed entry sizes sum above the 10 GiB cap.
- **WR-04** — backup pidfile TOCTOU closed: daemon-restart between
  `ensure_down` and `write_archive` now aborts the backup.
- **WR-07** — `Restore.maybe_fixer` no longer swallows doctor-fix
  errors silently; failures surface via `Logger.warning/1` with
  structured reason while preserving the `:ok` contract.
- `Config.write_default!` and `Config.erl_cookie` use
  tmp-write → chmod 0600 → atomic rename (closes write-then-chmod
  race that exposed the cookie at umask-default mode).

### Phase 4 — LiveView Dashboard + Real-Time Channels

#### Added

- Phoenix LiveView on `:4000` with 8 views: company overview, kanban
  board, agent detail with live `stdout.log` streaming, chat, approval
  queue, audit viewer, system health, and settings.
- Phoenix Channels + PubSub wired end-to-end to `file_system` (inotify)
  events — `~/.glorbo/companies/` mutations repaint the dashboard in
  under one second with no polling.
- Append-only channel markdown files with Elixir as the sole writer;
  browser POSTs route through the Channel controller which validates
  and appends; frontmatter `status:` transitions are frontmatter-first
  (file is truth).
- `@agent-name` mention posted to a channel wakes the named agent via
  the Router; approval-queue one-click approve/reject updates the task
  file's `status:` frontmatter and fires the wake.
- `GlorboWeb.Layouts.app` default layout wired for all LiveViews.

### Tests / Infrastructure

- 621/621 unit tests green. 52 integration tests excluded-by-default
  (require live host deps: `inotify-tools`, Podman, Ollama, real
  network, real `setsid`).
- `mix compile --warnings-as-errors` clean.
- Code review (standard depth) produced 1 Critical + 15 Warnings + 12
  Info across two rounds; all Critical + Warning findings closed
  (see `.planning/phases/05-cli-completeness-backup-restore-portability/05-REVIEW-FIX.md`).
- Milestone audit: 38/38 requirements covered, no integration gaps.
  10 human-verify items tracked as pre-release checklist (non-blocking).

---

## [0.0.1] — 2026-04-16 (unreleased)

First cut of the CLI-agent runtime milestone. Tag pending the first
`v0.0.1-rc1` signed release.

### Phase 3 — CLI Agent Runtime + bwrap Isolation + Routing + Budgets

#### Added

- Per-company OTP supervision tree with crash isolation: an agent
  crash restarts only that agent; a company crash restarts only
  that company's agents; dashboard and other companies unaffected.
- Inotify-driven inbox/outbox routing. Elixir is the only writer to
  `inbox/`; agents are the only writer to `outbox/`. Cross-agent
  messages are Router-mediated — no agent touches another agent's
  files directly.
- CLI agent adapters for **Claude Code** (`claude -p`), **Gemini
  CLI** (`gemini -p`), and **Codex CLI** (`codex exec -`). Session
  state + credentials `--ro-bind`ed from the Director's home into
  each sandbox via provider-specific env redirects
  (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, etc.).
- `bwrap(1)` sandboxing for every agent wake. Baseline:
  `--die-with-parent --unshare-user-try --unshare-ipc --unshare-pid
  --unshare-uts --unshare-cgroup-try --new-session --cap-drop ALL`.
  Workspace bind-mounted `rw`; outbox `rw`; inbox `ro`;
  per-permission mounts spliced in from `agent.md` frontmatter.
- Three-value network policy enforced by kernel:
  - `none` — `--unshare-net` (egress physically blocked).
  - `api-only` — inherits host netns; `HTTPS_PROXY` + `HTTP_PROXY`
    point at a `Glorbo.Network.Proxy` listener with a hostname
    allowlist (advisory).
  - `open` — inherits host netns; no proxy.
- Per-agent monthly budgets with JSONL usage ledger, dashboard
  alerts, and hard-stop at cap.
- Skills injection: `.glorbo/skills/` markdown files discoverable
  and attachable per-agent via frontmatter.
- Director approval gates: tasks with `requires_approval: director`
  frontmatter pause until the Director explicitly approves.
- Append-only `audit/YYYY-MM.jsonl` per company. Action vocabulary
  fixed in `AUDIT_EVENTS.md`. Mode bits prevent group/other write.
- Permission model: two-layer enforcement by design. Elixir Router
  (application) and bwrap mounts (kernel). Extending to POSIX ACLs
  inside Podman containers in v0.0.2.

#### Security

- **SEC-03** (`--unshare-net` kernel-enforced egress block) validated
  on Fedora 43 dev host: `curl --max-time 3 https://api.anthropic.com`
  inside a `network: none` sandbox returns exit 7 with no packet
  ever leaving the host.

### Phase 2 — Filesystem Foundation + Container Runtime + Local LLM

#### Added

- `glorbo init` bootstrap: verifies deps, materialises `~/.glorbo/`
  hierarchy, prepares (deferred) Podman/Ollama integration
  scaffolding, writes the initial config.
- `~/.glorbo/` directory hierarchy per `DESIGN.md` §3:
  `companies/`, `containers/`, `bin/`, `models/`, `audit/`,
  `sockets/`, `state/`, `config.md`, `glorbo.db`.
- `glorbo doctor` extended with 8 new checks: `podman`, `ollama`,
  `ollama_daemon`, `runtime_image`, `runtime_exec`, `audit_dir`,
  `sockets_dir`, `tar_zstd`. Severity-weighted exit code (0 /
  warning / blocker).
- `glorbo reindex` rebuilds SQLite state fully from markdown/JSONL
  on disk. The SQLite DB is derived data — delete anytime.
- Append-only system audit log at `audit/_system/YYYY-MM.jsonl`
  recording `init.step.*` actions during bootstrap.
- Podman + Ollama + `glorbo-runtime` container design preserved
  for restoration in v0.0.2; dormant in v0.0.1 codebase
  (`.planning/deferred/container-runtime-v0.0.2/`).

### Phase 1 — Compilable Skeleton + CI Release Pipeline

#### Added

- Elixir 1.18.4 / OTP 28.0.2 toolchain, pinned via `.tool-versions`.
- Phoenix 1.8 skeleton with SQLite WAL (`ecto_sqlite3`), trimmed
  of esbuild/tailwind/heroicons scaffolding (reintroduced in
  Phase 4).
- `mix glorbo.doctor` CLI skeleton with 5 baseline checks:
  `linux_kernel`, `uidmap`, `disk_space`, `glorbo_dir`,
  `erts_version`.
- `/health` endpoint (replaces generated `/` home page).
- `Burrito`-packaged single-binary release pipeline for Linux
  x86_64 and aarch64, with bundled ERTS and Zig cross-toolchain.
- GitHub Actions CI matrix: compile-as-errors, test, Credo
  strict, format check, release build, binary smoke test, artifact
  upload.
- Cosign keyless signing (Sigstore OIDC) on tagged `v*.*.*`
  releases. `SHA256SUMS` + `.sig` per artifact.
- SQLite WAL journal mode enabled in `dev.exs`, `test.exs`,
  `runtime.exs` (FND-02).
- Credo strict mode with project-specific tunings
  (`CyclomaticComplexity` to 20 for dispatch-table functions,
  `Nesting` to 3, `AliasUsage` threshold relaxed).

### Infrastructure — Repository hygiene

#### Added

- `README.md` with Glorbo brand logo, OSS badges (CI, release,
  license, Elixir/OTP, platform, security, PRs, last-commit),
  and phase-accurate v0.0.1 scoping.
- `SECURITY.md` — vulnerability reporting policy tailored for
  Glorbo's sandbox-as-trust-boundary threat model. GitHub Private
  Vulnerability Reporting as primary channel; 72h ack, 90-day
  coordinated disclosure, safe harbor clause.
- `CONTRIBUTING.md` — dev setup, PR flow, Conventional Commits,
  quality gates, DESIGN.md invariants, review checklist.
- `LICENSE` — Apache License 2.0.

#### Changed

- Dropped Python-in-Podman agent runtime from v0.0.1 scope
  (deferred to v0.0.2). DESIGN.md and README now annotate the
  shift explicitly. The dormant container design is preserved at
  `.planning/deferred/container-runtime-v0.0.2/` for restoration.

#### Fixed (CI pipeline)

- Replaced `${@:3}` bash-ism in bwrap launcher shell with POSIX
  `shift 2; exec "$b" "$@" < "$p"` — Ubuntu's `/bin/sh` is dash
  and rejected the array slice.
- Installed unconfined AppArmor profile for `/usr/bin/bwrap` on
  Ubuntu 24.04 runners to work around
  `kernel.apparmor_restrict_unprivileged_userns=1`, which blocked
  `--unshare-net` loopback setup with `RTM_NEWADDR: Operation not
  permitted`.
- Installed `bubblewrap` package on CI runners (not default on
  ubuntu-24.04).
- Removed invalid `E` regex modifier in `config/dev.exs`
  live_reload patterns — Elixir 1.18 parses strict modifiers.
- Loosened smoke-test `.checks | length` assertion from `== 5` to
  `>= 5` to stay resilient as phases add doctor probes (Phase 1:
  5; Phase 2: +8; Phase 3: +2; total 16).
- Guarded the "unknown-command exits 1" smoke assertion against
  `bash -e` — the `( cmd; ec=$?; test ... )` subshell tripped
  errexit before capturing the exit code.

---

<!-- Link refs for GitHub -->
[Unreleased]: https://github.com/foobarto/glorbo/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/foobarto/glorbo/releases/tag/v0.4.0
[0.3.0]: https://github.com/foobarto/glorbo/releases/tag/v0.3.0
[0.2.0]: https://github.com/foobarto/glorbo/releases/tag/v0.2.0
[0.1.0]: https://github.com/foobarto/glorbo/releases/tag/v0.1.0
[0.0.4]: https://github.com/foobarto/glorbo/releases/tag/v0.0.4
[0.0.3]: https://github.com/foobarto/glorbo/releases/tag/v0.0.3
[0.0.2]: https://github.com/foobarto/glorbo/releases/tag/v0.0.2
[0.0.1]: https://github.com/foobarto/glorbo/releases/tag/v0.0.1
