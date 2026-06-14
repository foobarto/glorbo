# Changelog

All notable changes to Glorbo will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0 caveat: APIs, CLI flags, on-disk layout, and SQLite schema may
change between minor versions. Pin exact versions in downstream usage.

## [Unreleased]

### Added

- **Multiple glorbo instances per machine** (GEP-0062). Each install now gets a
  stable per-instance node id (`node_id:` minted in its `config.md`), so the
  Erlang node name is `glorbo-<id>@127.0.0.1` instead of the old fixed
  `glorbo@127.0.0.1` — two instances with distinct `GLORBO_HOME` (+ `PORT`) no
  longer collide on the shared EPMD. `Console`'s remsh target and the EPMD
  stale-registration recovery are derived from the instance's name. Isolation
  is enforced by the existing per-home `erl_cookie` (distinct cookies ⇒ no
  cross-instance connect) plus a new `-kernel dist_auto_connect never` in
  `vm.args` (no accidental clustering; `glorbo console`'s explicit remsh still
  works). Single-instance installs are unaffected — they just get one stable
  id, minted transparently on first boot.
- **Deep-research task type** (GEP-0057, v1 — template-first). New
  `Glorbo.Research` orchestrator drives a bounded, governed
  plan → gather → read/extract → synthesise → render loop and emits a
  portable artifact pair — `report.md` + a self-contained, sanitised
  `report.html` (Earmark → `html_sanitize_ex`) — under
  `companies/<co>/projects/<slug>/reports/<id>/`. Gather rides the GEP-32
  native `web_fetch` tool; every fetched span is framed as untrusted via
  `Glorbo.Prompt.Untrusted.wrap/1` (GEP-0056, D5). Budget is
  degrade-to-partial (D4): when the budget gate refuses the next step — or
  the `max_steps` / `max_sources` caps bite — the task finalises a *partial*
  report with a leading `> Truncated at budget` banner instead of crashing.
  Ships the `research/` skill template declaring `max_steps` / `max_sources`
  / `budget_usd`.
- **Semantic recall index (GEP-0058)** — optional, default-OFF hybrid
  keyword + vector recall over a company's markdown home tree. Modelled
  on the elasticsearch-style hybrid (D3): an SQLite FTS5 keyword index
  (`chunks_fts`) for candidate recall, a `chunk_vectors(company,
  source_path, chunk_id, embedding BLOB, model, dims)` table for the
  embeddings, a PURE-Elixir cosine re-rank over the FTS5 candidate set,
  and reciprocal-rank fusion (RRF) for the final ordering — no
  `sqlite-vec`, no C-NIF (GEP-53 D13). Embeddings come from a local
  `/v1/embeddings` endpoint over the app's Finch pool via an injectable
  `Glorbo.Memory.Embedder` (tests stub it; no server needed). The index
  is DERIVED state (GEP-7): `glorbo reindex` re-chunks and re-embeds
  opted-in companies LAZILY (D6) and the markdown files stay
  authoritative. Strict per-company isolation — every query is scoped to
  the calling company; a company-A search never returns company-B
  chunks. Opt in/out per company with
  `glorbo memory index <company> --enable|--disable` (default OFF;
  `--disable` purges the company's index). New modules under
  `lib/glorbo/memory/`; migration adds `chunks_fts`, `chunk_vectors`,
  and `memory_index_enabled`. `glorbo reindex` output gains a
  `memory_chunks=N` count.
- **`glorbo fit` — native hardware → model-fit scoring** (GEP-59 v1,
  scorer + recommend; the `--serve` download path is deferred):
  - **`Glorbo.Fit`** facade: probe the host, rank the catalog, and print
    a ranked recommendation (model, quant, est tok/s, fit level) plus the
    `model:` / `provider:` lines to drop into an `AGENT.md`. Closes the
    "fully local out of the box" gap — `detect-providers` (GEP-8) only
    wires an already-running server; `fit` tells you which model to run.
  - **`Glorbo.Fit.Scorer`** — pure-Elixir scoring ported from odysseus's
    `hwfit` heuristics (GEP-59 D5): per-quant×context memory estimate,
    bandwidth-blended tok/s, quality/speed/fit/context composite scores,
    and a quant-downshift search (Q8_0 → Q2_K, then context-halving)
    until a candidate fits VRAM/RAM. No C-NIF — Burrito 4-target safe
    (GEP-59 D1 / GEP-53 D13 precedent).
  - **`Glorbo.Fit.Probe`** — host probe reading `/proc/meminfo` and, best
    effort, `nvidia-smi` / `rocm-smi` (Linux) or `sysctl` (macOS Apple
    Silicon). Every external call is wrapped so a missing binary or
    driver error **degrades to RAM-only scoring, never crashes**. Runs
    host-side (not in an agent sandbox); `--host <remote>` probes a
    remote host over SSH.
  - **`Glorbo.Fit.Catalog`** — static, compiled-in model + quant catalog
    (GEP-59 D4): a glorbo-maintained curated set of GGUF-servable models
    spanning the 1.5B → 70B size ladder plus the quant byte/speed/quality
    and GPU/Apple-Silicon bandwidth tables. Offline-true, no online
    refresh.
  - **CLI**: `glorbo fit [--use-case UC] [--target-context N]
    [--host REMOTE] [--json] [--limit N]`; exit 0 when a model fits,
    1 when nothing in the catalog fits the host budget.

### Changed

- **Goals are now `goal/v1` files, not `company.md` frontmatter** (GEP-63).
  Each goal is its own `companies/<co>/goals/<id>.md` file (the same
  one-file-per-entity model as tasks/agents/projects), read by the dashboard
  through a single hardened `Glorbo.Company.Goals.list/1` loader — collapsing
  the three drifting per-LiveView readers. `id` is the one identifier (it is
  the filename basename and the `task/v1` `goal:` join key). The add-goal form
  writes a file directly; the long-promised `progress:` field is now wired
  (an explicit integer `0..100` wins, else progress derives from linked
  tasks). **Breaking, manual migration (no automated migrator):** for each
  goal previously declared under `company.md`'s `goals:` list, create
  `companies/<co>/goals/<slug>.md`:

  ```yaml
  ---
  kind: goal/v1
  id: <slug>          # = the old goals: slug, and the filename basename
  name: <title>       # = the old goals: title
  status: active      # one of: active | paused | done | cancelled
  ---
  ```

  then delete the `goals:` block from `company.md` (equivalently: re-add each
  goal through the dashboard's add-goal form). A leftover `company.md goals:`
  key is now an `unknown_key` finding on `glorbo validate`. `glorbo reindex`
  is unaffected — it stays a pure derived-state read (GEP-3/7).
- **CI split — PRs run tests only; release builds run on tags.** The
  Burrito single-binary builds (Linux x86_64/aarch64 + macOS x86_64/arm64
  cross-compile), artifact upload, and visual-regression check moved out of
  the per-PR `ci.yml` into a new tag-triggered `release.yml`. `ci.yml` now
  runs a single `test (x86_64)` job — compile-warnings-as-errors, `mix test`,
  Credo, format, Sobelow, hex/deps audit, and Dialyzer — on every
  `pull_request` and `push` to `main`. Builds, Cosign signing, SLSA
  provenance, the GitHub Release, and the Homebrew-tap update now run **only**
  on `v*.*.*` tags. Faster PR feedback and no per-PR build cost; the four
  `<arch> build + test` / `<arch> macOS cross-build` status checks the `tags`
  ruleset requires are preserved (produced by `release.yml`).
- **Provider config + credentials consolidated under `~/.config/glorbo/`**
  (GEP-61) — out of the `~/.glorbo/` data tree so naive home-folder backups
  never sweep secrets. The per-provider overrides (`providers/<name>.toml`,
  e.g. `stado.toml`), the enabled-providers registry (`providers.toml`), and
  the native API-key store (previously the non-standard
  `~/.local/etc/glorbo/credentials`) now all live under
  `$XDG_CONFIG_HOME/glorbo` (default `~/.config/glorbo`), `0700`. A new
  `Glorbo.Filesystem.ConfigMigration` moves any legacy files into place once
  on startup — copy-then-remove, no-clobber, perms-preserving, best-effort —
  so existing credentials are never orphaned. `~/.glorbo/` is now pure user
  data (companies, audit, derived SQLite). `GLORBO_CREDENTIALS_DIR` still
  overrides the credential path.

### Fixed

- **The default `~/.glorbo` works on atomic-distro homes** (GEP-0060). On
  Bazzite/Silverblue/Kinoite `/home` is a symlink to `/var/home`, so
  `Glorbo.Sandbox.SymlinkGuard` (which walks every ancestor from `/`) refused
  every path under the default `~/.glorbo` — `glorbo reindex` indexed 0 files
  and agent permission mounts failed unless `GLORBO_HOME` was pointed at the
  canonical `/var/home/<user>/.glorbo` by hand. `Glorbo.Filesystem.Hierarchy`
  now canonicalises the home root through symlinked ancestors
  (`canonicalize_home_root/1` + `default_root/0`, plus a new `home_root/0` the
  16 CLI/lifecycle/scaffold call sites use so an explicit `GLORBO_HOME` is
  resolved too). The SymlinkGuard is **unchanged** — agent-planted symlinks
  inside the workspace are still refused; only the trusted home prefix is
  resolved. Off-home GEP-27 grants keep full-ancestor checking.
- **A 0-byte / frontmatter-less `~/.glorbo/config.md` no longer locks the
  dashboard out.** An empty `config.md` (the placeholder `Hierarchy.ensure!`
  writes on first materialise) parsed to empty config, so the minted
  `dashboard_token`/`secret_key_base` never persisted (the in-place patchers
  had no `---` fence to anchor on) — leaving the dashboard in an un-unlockable
  BOOTSTRAP. `Glorbo.Config.load/1` (and `erl_cookie`/`node_id`) now treat an
  empty/unfenced file like an absent one and regenerate canonical frontmatter;
  a file that opens with `---` still fails closed via `coerce` (GEP-0053 D9),
  never clobbered. And `mix phx.server` now prints the state-aware
  `…/setup?token=…` URL on boot (gated to bootstrap/degraded), so the dev
  dashboard is reachable — previously only `glorbo serve`/`up` printed it.
- **`glorbo validate` now flags dangling `depends_on:` targets** (GEP-47). The
  spec promised a `task.dependency_missing` finding (D1 + failure-modes table +
  `DependencyGate` moduledoc), but only the runtime half shipped — the scheduler
  auto-cancels on a missing target, while parse/reindex-time validation stayed
  silent. The validator's `task/v1` check now resolves each `depends_on` entry
  against the on-disk task set (live `projects/*/tasks/<id>.md` or archived
  `projects/*/history/tasks/<id>.md`, across all of the company's projects since
  `task_id` is company-unique) and emits an `error`-severity
  `:task_dependency_missing` when an entry resolves to neither. The id is
  charset-guarded before any filesystem lookup, so a malformed/`..`-bearing
  entry is reported as unresolved rather than escaping the tree.
- **Peer-review sentinels no longer misclassify as generic inbox messages**
  (GEP-42). `Glorbo.FileSpec.classify_by_path/1` is first-match-wins, but
  `InboxMessageMd`'s `inbox/*.md` regex (a superset of the
  `peer-review-<id>.md` / `peer-review-feedback-<id>.md` sentinel paths) was
  registered *ahead* of the dedicated peer-review specs — so a not-yet-parsed
  sentinel (the validator/formatter path-fallback for brand-new files) routed
  to `inbox-message/v1` instead of its own validator. Reordered `@specs` so
  `PeerReviewFeedbackMd` → `PeerReviewRequestMd` → `InboxMessageMd` (most
  specific first; feedback before request since `peer-review-feedback-…` also
  matches the request regex). GEP-42's "routes without ambiguity" claim now
  holds. Regression test added.
- **`glorbo validate` now flags memory `type:`↔filename mismatches**
  (GEP-25). The spec's `:type_filename_mismatch` check was documented but never
  implemented: a memory file whose filename prefix (`user_` / `feedback_` /
  `project_` / `reference_`) disagrees with its frontmatter `type:` mis-files
  the entry for recall. The validator now emits a `:type_filename_mismatch`
  error when the prefix and `type:` differ. Closes a GEP↔code reconciliation
  finding.
- **Semantic-recall opt-in is now rebuildable from disk** (GEP-3 / GEP-58). The
  per-company memory-index opt-in lived only in the `memory_index_enabled`
  SQLite table, so `rm glorbo.db && glorbo reindex` silently lost it (recall
  reverted to OFF) — a GEP-3 "nothing in SQLite that can't be rebuilt from disk"
  violation. `glorbo memory index <co> --enable/--disable` now also writes
  `company.md`'s `memory_index:` boolean (the source of truth), `glorbo reindex`
  re-derives the enabled set from it and re-seeds the SQLite cache, so the
  opt-in + embeddings survive a DB wipe. New `company/v1` `memory_index:` field.
  Two follow-up correctness fixes: (1) `enable/2` now writes the disk flag
  **first** and refuses to cache an opt-in that never reached `company.md` (a
  missing file or write error is returned, not masked by a cache row that would
  evaporate on the next reindex); (2) `glorbo reindex` reconciles the cache the
  *other* way too — a company opted out on disk (or whose directory was deleted)
  has its stale `memory_index_enabled` row + derived chunks purged, so the cache
  never outlives the disk truth.
- **Kanban status moves now go through the single Director write channel**
  (GEP-36). `KanbanLive`'s drag/drop handler wrote task status directly via
  `TaskDefinition.write/2`, bypassing `Glorbo.Actions` — the one path GEP-36
  centralises validation + symlink guards + audit + history through. New
  `Glorbo.Actions.Tasks.move/4` is that path: it validates the company slug,
  the `projects/<p>/tasks/<id>.md` shape, and the target status; runs the
  symlink-ancestor + leaf guards and the approval-gate guard (a
  `requires_approval: director` task can't jump to `in-progress`/`done` until
  approved); writes atomically inside a HomeHistory `task.move` Tx; and emits
  the `task.move` audit row — so MCP/shell callers get the same guarantees, not
  just the LiveView. (The `save_task` full-edit handlers still write directly,
  pending an `Actions.Tasks.update/4`.) Closes part of a GEP↔code reconciliation
  finding.
- **Peer-review `block`/`revise` verdicts now require a reason** (GEP-41
  failure-mode). `Glorbo.Actions.Tasks.record_peer_review_verdict/4` previously
  accepted an empty note for any verdict, so a reviewer (or an agent's verdict
  reply) could `block` a task — flipping it to `denied` — with no justification.
  A `block` or `revise` with an empty/whitespace note is now rejected with
  `{:error, :reason_required}` and lands no audit row or status flip; `approve`
  stays noteless-OK. Closes a gap surfaced by the GEP↔codebase reconciliation.
- **Crashed glorbo no longer wedges every subsequent start (orphaned EPMD
  registration).** A hard crash can leave `glorbo@127.0.0.1` registered with
  EPMD even though the node is gone (a child process that inherited the EPMD
  socket fd holds it open), so the next `glorbo up` / `serve` failed
  immediately. Two bugs fixed in `Glorbo.CLI.Lifecycle.Distribution`: (1) the
  collision was matched as `{:already_started, _}`, but a cross-process EPMD
  name collision actually surfaces as a net_kernel `:nodistribution`
  shutdown (verified on OTP 29) — so the friendly path never ran and `serve`
  raised an opaque error; (2) there was no recovery. `Distribution.start/0`
  now probes the registered distribution port to tell a *running* glorbo
  (genuine collision → "run `glorbo down`") from a *stale* registration
  (no listener), and on a stale one reclaims its own orphan — SIGKILL the
  EPMD and respawn a clean one, then retry once. Recovery is fail-safe and
  gated on glorbo being EPMD's sole registrant, so a shared EPMD's other
  live nodes are never disturbed; EPMD stays hardened (no
  `-relaxed_command_check`, GEP-48).
- **Per-instance node id is now stable and race-free** (GEP-0062 follow-ups).
  (1) `glorbo up` mints+persists the `node_id` *before* spawning the daemon, so
  a `glorbo console` that races in right after the pidfile write can no longer
  mint a *different* id than the daemon registered (upgrade path: a config with
  `erl_cookie` but no `node_id`). (2) An all-digit minted id (e.g. `12345678` —
  ~1.6% of 8-hex ids) is written unquoted and YAML re-reads it as an integer;
  `Glorbo.Config` now coerces it back to its (stable) string form instead of
  failing the `is_binary` guard and re-minting a fresh id on every call.

### Security

- **`GLORBO_CREDENTIALS_DIR` is guarded consistently across both resolution
  paths** (GEP-61). `Hierarchy.native_credentials_dir/0` used the env value
  verbatim while `Providers.NativeConfig.credentials_dir/1` validated + raised
  on it — so a relative or `..`-bearing value was honoured in one path and
  rejected in another, and could redirect the credential store (and its
  read-only GEP-55 sandbox bind) outside the intended tree. `native_credentials_dir/0`
  now delegates to the single guard authority (`NativeConfig.credentials_dir/1`:
  must be absolute, no `..`, no system path), so a bad override fails loud
  everywhere; the default `<config_root>/credentials` is exposed as
  `Hierarchy.default_credentials_dir/0`.
- **Untrusted content framing (GEP-56)** — defense-in-depth against
  cross-agent prompt-injection *propagation*. Content that crosses a
  trust boundary into an agent's prompt — recalled file-based memory
  (GEP-21, authored elsewhere) and the inbox triggering message
  (inter-agent bodies routed inbox→outbox, GEP-35) — is now framed as
  **data, not instructions**. New pure module `Glorbo.Prompt.Untrusted`
  wraps each untrusted chunk in a fresh matched-random
  `UNTRUSTED-START-<r>` / `UNTRUSTED-END-<r>` boundary (`r` = 128-bit
  `:crypto.strong_rand_bytes`), so embedded guessed close markers cannot
  break out of the frame; `normalise/1` re-frames cross-hop matched
  pairs and **fails closed** (taints everything after) on an unmatched
  open; `preamble/0` states the policy once. The wake/dispatch composer
  (`Glorbo.Agent.Server.compose_prompt/4`) tags each context chunk
  `provenance: :trusted | :untrusted`, frames untrusted chunks, and
  emits the preamble once iff any untrusted chunk is present. Own-company
  scaffolding (AGENT.md system prompt, runtime context) stays trusted and
  unframed so legitimate delegation is preserved. `SECURITY.md` amended:
  single-agent injection within grants stays out of scope; cross-agent
  propagation is mitigated as DiD by GEP-56. Additive — does not touch
  the sandbox or permission enforcement.
- **Code-scanning fixes** (GitHub Security → Code scanning):
  - **Same-origin navigation guard** (SnykCode open-redirect #15):
    keyboard/command-palette navigation now routes every
    `window.location.assign` through `navigateInApp/1`, which only
    accepts rooted same-origin paths (rejects `//host`, `/\host`,
    schemes). Defence-in-depth — the sources were already
    regex-constrained to `[a-z0-9_-]` slugs.
  - **Pinned npm dependencies** (Scorecard Pinned-Dependencies #2/#10):
    `scripts/ui-baseline.sh` uses `npm ci` (hash-pinned from
    `package-lock.json`) instead of `npm install`; CI installs the
    Playwright browser via the lockfile-pinned local binary
    (`./node_modules/.bin/playwright`) instead of `npm exec`.

  The four SnykCode DOM-XSS alerts (#11–#14) are false positives — every
  dynamic value is `escapeHtml`-escaped and the only URL-derived input is
  the regex-constrained company slug — and are dismissed as such.

## [0.26.0] — 2026-06-12

### Security

- **Snyk Code (SAST) workflow** (`.github/workflows/snyk-security.yml`).
  Runs Snyk Code over the JavaScript surface (`assets/js` + `scripts/`)
  and uploads SARIF to Security → Code scanning. Report-only and
  `SNYK_TOKEN`-guarded (green no-op without the secret); all actions
  SHA-pinned per repo policy. Snyk Code can't read Elixir, so Sobelow
  stays the Elixir/Phoenix SAST; no container/IaC steps (Glorbo ships no
  Dockerfile). Replaces the broken GitHub sample template.
- **HTTP-client stack advisories — mint → 1.9.0, req → 0.6.1** (OSV /
  OpenSSF Scorecard). Six EEF advisories flagged against `mix.lock`,
  all in transitive dependencies (burrito → req → finch → mint) — none
  in Glorbo's own code, which does not call mint/req/finch directly on
  this release line:
  - mint < 1.9.0: HTTP/1 request-line CRLF injection
    (EEF-CVE-2026-48861), HTTP/1 response smuggling via lenient
    Content-Length parsing (EEF-CVE-2026-49753), unbounded HTTP/2
    `PUSH_PROMISE` growth (EEF-CVE-2026-48862), and an HTTP/2
    `CONTINUATION` flood (EEF-CVE-2026-49754) — all fixed in 1.9.0.
  - req < 0.6.1: decompression-bomb DoS via auto-decoded
    compressed/archive bodies (EEF-CVE-2026-49755, fixed 0.6.1) and
    multipart header injection via unescaped name/filename/content_type
    (EEF-CVE-2026-49756, fixed 0.6.0).

  Explicit floor pins `{:mint, "~> 1.9"}` and `{:req, ">= 0.6.1"}` added
  to `mix.exs` (finch only requires `mint ~> 1.8` and burrito only
  `req >= 0.5.0`, both of which still admit the vulnerable versions).
  `mix deps.audit` clean.

- **GEP-0055 inference-proxy hardening** (PR #47 review — codex +
  Copilot): three fixes to `Glorbo.OpenAIProxy`, all on the sandbox
  egress path:
  - **Inbound headers are no longer forwarded upstream.** The shape
    adapters passed the inbound header map straight through, so the real
    provider received the proxy's loopback `Host` (misroute / CDN
    rejection) and — for Anthropic (adds `x-api-key`, never overwrites
    `authorization`) and Gemini (query-param auth, no-op `attach_auth`) —
    the per-dispatch proxy bearer token leaked upstream via the inbound
    `Authorization`. `translate_request/2` now returns an empty
    allowlist; auth/host/content-type come from `attach_auth/2` + Req.
  - **16 KiB header cap enforced on the terminated path.** A complete
    header block arriving in one read (terminator already present)
    bypassed the cap; oversized heads now fail closed `:head_too_large`.
  - **Socket-ownership race removed.** The handler now waits for an
    explicit hand-off before touching the socket, eliminating the
    `controlling_process/2` race that yielded intermittent `:not_owner`.
  Regression tests added (per-shape allowlist, oversized-header
  rejection, no-leak assertions on the round trip).

### Fixed

- **DM channel creation race + symlink follow** (PR #42 review,
  Copilot): `Glorbo.Actions.ensure_dm_channel/3` used a non-atomic
  `exists?` + write, letting two near-simultaneous first posts clobber
  a thread back to its header, and never lstat-gated the path. Now an
  `O_CREAT|O_EXCL` exclusive create (`:eexist` = idempotent success)
  behind the M03 `AgentWritableFile` guard.
- **Zero-rounds PBKDF2 hash accepted as CONFIGURED** (PR #42 review,
  Codex P2): a hand-edited/torn `$pbkdf2-…$0$…` value passed the
  structural check and would hang/crash `/login` inside
  `Pbkdf2.verify_pass/2`. The rounds segment now requires a positive
  integer with no leading zero; bad values fail closed as DEGRADED.
- **Symlinked-path file opens mislabeled as "not found"** (Elixir 1.20
  warning audit): `GlorboWeb.AgentLive.read_workspace_file/2` dropped
  `:symlink_in_path` from its error pass-through, so opening a file
  through a symlinked directory surfaced "File no longer exists."
  instead of the symlink-refusal message. The H10 symlink *enforcement*
  was never affected — only the error label. Regression test added.

### Changed

- **Toolchain → Elixir 1.20.1 + OTP 29.0.2** (latest stable, up from
  1.19.5 / 28.5). Elixir 1.20's set-theoretic type checker surfaced 36
  own-code warnings, all driven to zero (22 dead-code removals, 1 real
  bug fixed [above], 13 defensive-net cases preserved); 15 deprecated
  `File.stream!(path, [], :line)` sites updated to the `:line`-second
  arg order. OTP 28.5 → 29.0.2 lands now that Beam Machine publishes
  29.0.2 ERTS for every Burrito target (linux x86_64/aarch64 + macOS
  universal), so the release build resolves; supersedes the interim
  `28.5.0.1` CI pin.

- **Dependency bumps** (folded from dependabot PRs #43/#44):
  earmark 1.4.49, phoenix_live_view 1.1.31, yaml_elixir 2.12.2,
  thousand_island 1.5.0 (transitive); GitHub Actions pins
  `actions/checkout` v6.0.3 and `github/codeql-action` v4.36.1.
- **Latest in-range dependency bumps**: phoenix 1.8.7 → 1.8.8,
  phoenix_live_view 1.1.31 → 1.2.1, bandit 1.11.1 → 1.12.0, credo
  1.7.18 → 1.7.19. All within existing `~>` constraints; `mix precommit`
  green. Folds dependabot #46 (bandit + credo, already covered above)
  and #45 (`github/codeql-action` v4.36.1 → v4.36.2 in scorecard.yml).

### Added

- **In-process inference proxy for sandboxed agents (GEP-0055, slices
  1–4a).** New `Glorbo.OpenAIProxy` — a per-company loopback listener
  that lets `auth = "via_proxy"` native providers keep their real API
  keys on the host: the sandbox only ever sees a per-dispatch token
  (`GLORBO_PROXY_TOKEN`) and a loopback base URL
  (`OPENAI_BASE_URL`/`GLORBO_PROXY_BASE_URL`); the proxy reads the
  upstream key from the host env var named by the new `api_key_env`
  provider field at request time and forwards the call. Includes the
  multi-shape `Glorbo.OpenAIProxy.Shape` behaviour (OpenAI v1,
  Anthropic Messages, Gemini routing), per-dispatch token mint/revoke
  in dispatch, a second pasta `-T` port forward so the netns admits
  the listener, a token-company cross-check + provider-auth check at
  the listener, and `via_proxy` support in the native harness and the
  model catalog. Not yet included (future slices): SSE streaming,
  Gemini request translation, claude-code settings.json injection,
  audit rows, and the `usage.json` write. CLI providers cannot opt in
  yet — the loader restricts `via_proxy` to `kind = "native"` until
  the per-CLI injection slice lands.

## [0.25.0] — 2026-06-03

### Added

- **`glorbo import paperclip` reads live paperclip installs (GEP-0054).**
  The importer now auto-detects the on-disk layout of a *running*
  paperclip instance (`<src>/agents/<uuid>/instructions/AGENTS.md`) in
  addition to the flat `paperclipai/companies:main` git template
  (`<src>/<agent>/AGENTS.md`). Point it at a paperclip company directory
  and it descends into `agents/`, reads each agent's contract files from
  `instructions/`, and imports under the agent's UUID directory name
  (rename later + `glorbo reindex`). Paperclip `memory/`/`life/` dirs are
  not carried over (flagged in the report, not dropped silently), and a
  zero-match import now says so loudly instead of scaffolding an empty
  company. All existing C-098 symlink/lstat guards extend to the deeper
  paths; flat-layout behaviour is unchanged. The importer's
  destination-directory guard now scopes its symlink checks to segments
  at/below the glorbo home (the threat is a symlink planted *inside* the
  home, not OS dirs above it), so `glorbo import paperclip` works with
  the default `~/.glorbo` on atomic-Fedora hosts where `/home` itself is
  a symlink (`/home → /var/home`).

- **MiniMax native provider.** New built-in `minimax` provider
  (`priv/providers/minimax.toml`) targeting MiniMax's OpenAI-compatible
  endpoint (`https://api.minimax.io/v1`) via the existing native harness
  (GEP-32) — bearer auth, `native-v1` usage tracking. Ships a static model
  catalog: `MiniMax-M3`, plus the M2.x family `MiniMax-M2.7` and
  `MiniMax-M2.5` each with their `-highspeed` low-latency serving-tier
  variant. Credentials live in
  `~/.local/etc/glorbo/credentials/minimax.toml`; select with
  `provider: minimax` + `model: MiniMax-M2.7` in `AGENT.md`.

### Security — director passphrase login (GEP-0053)

Post-implementation hardening from a final full-auth-surface review:

- **`/login` parallel-burst gate.** The throttle's check+record is now one
  atomic `reserve/0` call, so a burst of concurrent `/login` requests can't
  all slip past the pre-PBKDF2 gate (only one verify proceeds per backoff
  window). A throttled attempt no longer ratchets the delay — a flood can't
  extend the operator's own lockout.
- **`/setup` single-shot is now atomic** (`Config.put_password_hash_if_absent/2`
  under a node-global lock; proven by a concurrency test) — concurrent
  bootstrap POSTs can't double-write; the loser sees `:already_set`.
- **`/api/search` is gated by the passphrase session, not the token** — a
  `dashboard_token` holder without the passphrase can no longer enumerate
  task titles once a passphrase is set.
- **Bootstrap token stripped from the `/setup` URL** — a `?token=` is
  stashed in the session and the request 302s to a bare `/setup`, keeping
  the raw token out of the address bar / history / Referer.
- **`/api/search` CSRF gate.** The cookie-authenticated `dashboard_api`
  pipeline now runs `:protect_from_forgery` — a no-op for the only current
  route (`GET /api/search`, a safe method) but it enforces a CSRF token the
  moment any state-changing route is added to a session-authed pipeline
  (and clears the SAST gate without silencing the check globally).
- **`http_only` set explicitly on the session cookie (D20).** The director
  session cookie's `HttpOnly` flag is now declared on `@session_options`
  rather than inherited from Plug's default, so a dependency change can't
  silently drop it; a regression test pins the flag on the wire.


Browser dashboard auth via a director passphrase (PBKDF2-HMAC-SHA512),
distinct from the MCP/CLI `dashboard_token`. Once a passphrase is set the
token no longer grants browser access. Specced in GEP-0053 (hardened by a
six-lens security red-team); hashing is PBKDF2 via `pbkdf2_elixir` — pure
Elixir, chosen over Argon2id to keep the Burrito cross-build NIF-free
(GEP-0053 D13).

Shipped in full this release:

- `config.md` gains an optional `director_password_hash` key. Absent ⇒
  BOOTSTRAP, a valid `$pbkdf2-sha512$…` hash ⇒ CONFIGURED, any malformed
  value ⇒ DEGRADED (fail-closed — a corrupt byte never silently re-opens
  setup). Written double-quoted + atomically at mode 0600; survives
  `mix glorbo fmt`.
- `Glorbo.Config.put_password_hash/2` + `clear_password_hash/1` patch the
  key **frontmatter-scoped** (a body line can't divert the write) and
  span-aware (a multiline value can't orphan lines onto a neighbour).
  Runtime wires `:director_password_hash` (prod + dev), with a fail-closed
  fallback when the config can't be read.
- PBKDF2 work factor pinned: 210k rounds (OWASP) in prod, 1 in test.
- `GlorboWeb.DirectorAuth` — the browser-auth gate. One module, two entry
  points (a plug for the dead render + an `on_mount` hook for the LiveView
  socket, since the socket bypasses the router pipeline). BOOTSTRAP →
  `/setup`, CONFIGURED → requires the passphrase session (the token marker
  is never honoured here), DEGRADED → 503 fail-closed. The connected
  socket re-checks every 60s so a passphrase reset disconnects open tabs.
- **`glorbo reset-password`** — recovery from a forgotten/compromised
  passphrase: clears `director_password_hash` from `config.md`, returning
  the dashboard to first-run setup (the `dashboard_token` is untouched).
  Refuses while the daemon is running (a separate CLI process can't update
  the live node's in-memory hash, so the reset wouldn't take effect — stop
  it with `glorbo down` first).
- **State-aware startup banner** — `glorbo serve` / `up` print the
  `?token=` URL only in bootstrap (→ `/setup`); once a passphrase is set
  they print a bare `/login` and never reprint the token (it grants no
  browser access then, and stays out of scrollback/journals).
- Director passphrase params are kept out of request logs
  (`:phoenix, :filter_parameters` gains `passphrase`/`token`).
- **CSRF: no GET mutates state.** `GET /companies/:c/dms/:agent` no longer
  writes a DM channel file (a state-changing GET is forgeable under
  `SameSite=Lax`); it's now a pure redirect. The DM thread renders empty
  until the director's first message, which materialises the file on the
  CSRF-protected socket event (`Glorbo.Actions.ensure_dm_channel/3`). This
  was the only state-changing GET in the router (D19).
- **`/login` brute-force throttle** (`GlorboWeb.LoginThrottle`): an
  escalating per-failure delay (capped), consulted *before* the PBKDF2
  verify so a throttled attempt burns zero hashing cost and holds no
  connection. Deliberately **no hard lockout** — a lockout on a single-user
  loopback box is a self-inflicted DoS; the delay self-clears, so the
  director gets in after one short backoff while a brute-forcer is reduced
  to a few guesses/minute (irrelevant against a real passphrase + 210k-round
  PBKDF2). `/setup` needs no throttle — it's single-shot, so at most one
  hash is ever computed.
- The browser dashboard is now **wired behind the passphrase gate**:
  `DirectorAuth` gates the dead render + the dashboard `live_session`
  gates the socket; `DashboardToken` is now MCP/CLI-only (`:api` + `:mcp`)
  — a token leak no longer grants dashboard access once a passphrase is
  set. `/login`, first-run `/setup` (bootstrap + token-gated, single-shot),
  and `/logout` are live, with CSRF-protected forms; on success the
  session is rotated (anti-fixation) and `/setup` flips the running node to
  configured without a restart.

Hardening to the shared secret-write path (also covers `dashboard_token`
+ `erl_cookie`), surfaced by the GEP-0053 security review:

- `~/.glorbo/` is now chmod'd to `0700` (was umask-default, typically
  0755). Closes a local-user read of every secret at rest — config token,
  password hash, `secret_key_base`, `erl_cookie`, the SQLite projection,
  and the audit log. `atomic_write_secret!` also forces its parent dir
  `0700` before writing, so the brief umask-default window on a freshly
  created temp file is unreachable from other accounts (an open fd
  survives a later chmod, so the directory is the real boundary).

### Tooling — bump Elixir 1.18.4 → 1.19.5 and OTP 28.0.2 → 28.5

Latest stable on both runtimes. Picks up the security patches that
landed in OTP 28.1-28.5 (CVE fixes in the `inets` HTTP client and
`ssl` modules) plus the Elixir 1.19 minor-version improvements
(better warning output, faster `mix compile`). OTP 29.0 was just
released (2026-05-13) but is held back here — too fresh, dependency
ecosystem (Phoenix 1.8 / Bandit 1.6 / Ecto 3.12) hasn't yet
confirmed full OTP-29 compatibility.

Closes a workflow tax: rounds 5-7 of the security wave had repeated
CI format-check failures because the local Elixir 1.19 formatter
and CI's pinned 1.18 disagree on idiomatic line-splitting — each
occurrence cost a ~30-min push/wait/re-format/re-push cycle. With
both local and CI on 1.19.5 the cycle collapses.

- `.tool-versions` → `elixir 1.19.5-otp-28` + `erlang 28.5`
- `.github/workflows/ci.yml` → 3 occurrences of
  `elixir-version: '1.19.5'` + `otp-version: '28.5'`
- `README.md` quickstart updated to match
- `mix.exs` `elixir: "~> 1.18"` requirement kept (still accepts
  1.19.x; tightening to `~> 1.19` would arbitrarily block 1.18.x
  downstreams that the code itself doesn't need)

Local validation: `mix compile --warnings-as-errors`, `mix format
--check-formatted`, `mix credo --strict`, `mix test` (2939/0) all
green on the new toolchain. Dialyzer count-regression baseline
bumped 168 → 169: 1.19's inference produces +3 new findings (all
in `lib/glorbo/cli/lifecycle/` cascading from a `no_return` on
`do_start/0` — bare `rescue _ -> :ok` in `ensure_epmd/0` plus
OTP-28.5 narrowed Node.start/2 typespec interact in a way the
older inferencer didn't catch) and resolves -2 (socket-shutdown
false positives in `network/proxy.ex` that 1.19 types correctly).
Net +1. Same false-positive class as the existing baseline.
Attempted to fix the root via an explicit `@spec` — 1.19's
inference rejected it as contradictory (`invalid_contract`,
count went 169 → 170); reverted. Diagnostic confirmed by running
`mise exec elixir@1.18.4-otp-28 -- mix dialyzer` against the
same tree (168 vs 169). PLT cache key prefix updated from
`plt2-ubuntu24-otp28.0.2-ex1.18.4-` to `plt2-ubuntu24-otp28.5-ex1.19.5-`
so the new toolchain rebuilds the PLT once rather than reusing
a stale one. Full delta and follow-up plan in
`docs/testing/dialyzer-baseline.md`.

### Security — codex + gemini round-6 deep-dive: 10 hardening fixes (bundled)

Round 6 of the ongoing codex + gemini audit cycle against the
post-PR-#37 codebase. Two of these findings are **missed-sister
regressions of earlier round fixes** — same vulnerability pattern,
sibling module that the original fix didn't reach. Worth flagging
as a recurring "fixed module A, missed module B" trend across
rounds 4/5/6. 1 HIGH + 5 MED + 4 LOW.

- **Cross-tenant project enumeration via symlinked `projects/`**
  (codex, HIGH; **missed-sister of PR #37 kanban_live fix**) —
  `Glorbo.CompanyLive.load_projects_and_tasks/1` and
  `collect_goal_task_counts/1` ran bare `File.ls` over the
  projects dir with `File.dir?` filtering and NO `Slug.valid?`
  gate. `File.dir?` follows symlinks → an agent with
  `projects:write` plants `projects/evil → /etc` and the
  overview/goal-counts render reads from the target. Exact
  parallel to the symlink-bypass closed in PR #37 for
  `KanbanLive.load_tasks/2`. New `safe_projects/2` +
  `real_subdirectory?/2` (lstat-based, identical shape to
  kanban_live's gates) applied at both call sites; also gates
  the `tasks/` subdir to close PR #37's load_project_tasks
  parallel.

- **Audit JSONL unbounded read in overview** (codex, MED) —
  `CompanyLive.audit_last_wakes/2` used bare `File.read` on
  `audit/<YYYY-MM>.jsonl` while the sibling `read_audit_lines/1`
  already used `AgentWritableFile.read_bounded(path,
  @max_audit_bytes)`. Agent-driven dispatch could grow the
  audit file past memory and OOM the dashboard. Switched to
  the same bounded read.

- **BrainDump read_day unbounded + no SymlinkGuard** (codex,
  MED) — `Glorbo.BrainDump.read_day/2` used bare `File.read` on
  each day's brain-dump file. Braindump dir is currently
  director-only-writable but a previous symlink-plant via some
  other escape route would slurp through; `convert_to_task/3`
  already had the lstat discipline via `ensure_safe_dir`, the
  list path didn't. Now uses
  `AgentWritableFile.read_bounded(path, 1 MiB)` AND enforces a
  canonical `YYYY-MM-DD.md` filename regex (closes the related
  LOW-9 YAML-scalar injection vector via `braindump_ts:`).

- **Doctor write_probe predictable filename + symlink-follow**
  (gemini, MED) — `Glorbo.Doctor.write_probe/3` used
  `System.unique_integer/1` for the probe filename (monotonic
  per VM → predictable) and `File.write!` + `File.rm!` both
  follow symlinks. An attacker with write access under the
  parent dir can pre-plant `.doctor_probe_<low-N>` as a symlink
  to a sensitive file; `File.write!` writes "ok" THROUGH the
  symlink. New `do_write_probe/3` uses
  `:crypto.strong_rand_bytes(8)` for the probe name, opens
  with `:exclusive` (O_EXCL), lstat-checks the parent dir
  before writing, and does NOT `File.rm` on O_EXCL collision
  (could be a planted symlink we mustn't follow).

- **Doctor check_sockets_dir File.chmod follows symlinks**
  (gemini, MED; **missed-sister of PR #37 fix_sockets_dir**) —
  PR #37 fixed the `Glorbo.Doctor.Fixer.fix_sockets_dir/1`
  chmod-follows-symlinks finding but missed the sister
  `Glorbo.Doctor.check_sockets_dir/1` which has the same shape:
  `File.mkdir_p! → File.chmod!(0o700)`. Same exposure (attacker
  swaps `~/.glorbo/runtime/sockets/` for a symlink → chmod
  retargets). Now lstat-refuses non-directory before chmod,
  mirroring the round-5 fix.

- **import_paperclip destination symlink-follow** (gemini, MED)
  — `Glorbo.CLI.ImportPaperclip.ensure_company_dirs/1` and
  `do_import_agent/4` called `File.mkdir_p!` on the destination
  tree (`~/.glorbo/companies/<slug>` and `<co>/agents/<slug>`)
  without lstat-checking parents. Source side has C-098 lstat
  guards (good); destination side didn't. Prior-compromise that
  planted a destination dir as a symlink would land imports in
  attacker territory. New `ensure_real_dest_dir!/1` lstat-walks
  each dest parent before `mkdir_p!`.

- **CompanyLive read_first_line unbounded** (codex, LOW) —
  `read_first_line/1` used bare `File.read` on agent-routed
  inbox `.md` files (only first 80 chars rendered, but full
  file was slurped). Inconsistent with the rest of the module's
  reads. Switched to `AgentWritableFile.read_bounded(path, 4 KiB)`.

- **BrainDump braindump_ts YAML scalar injection** (codex, LOW;
  defense-in-depth, closed by the read_day filename regex) —
  `render_task/2` interpolated `entry.ts = "#{day}T#{time}Z"`
  bare into the task frontmatter; if a non-canonical day
  filename had ever landed in braindump/, the bare scalar would
  permit YAML key injection. Closed implicitly by the
  `read_day/2` canonical-filename regex above (only valid
  `YYYY-MM-DD.md` flows through, so `entry.day` is guaranteed
  safe before `entry.ts` is built).

- **Proposals scalar fields unbounded in render** (codex, LOW)
  — `subtype`, `proposed_at`, `proposed_by`, `denial_reason`,
  etc. rendered unbounded via `proposals_live.ex`. Body was
  capped via `truncate/1`; the others weren't. AgentWritableFile's
  10 MiB file cap bounds per-file but a single proposal could
  inflate ~10 MiB of HTML per list refresh. New `scalar_cap/1`
  in `Glorbo.Company.Proposals.read_one/1` truncates each
  scalar at 240 bytes via `Util.UTF8.safe_byte_slice` so every
  render path benefits, not just the LV.

- **CLI logs.ex missing slug validation** (gemini, LOW) —
  `glorbo logs <company> [<agent>]` passed positional argv
  straight into `Path.join` with no validation. Absolute paths
  don't bypass `Path.join` (Elixir strips leading `/` on later
  segments), but `..` traversal IS permitted. Combined with the
  `.log` / `.jsonl` suffix requirement the exploit is narrow
  (operator-CLI surface), but defense-in-depth: now gates both
  args through `~r/\A[a-z0-9][a-z0-9-]*\z/` at `do_run/2`.

### Security — codex + gemini round-5 deep-dive: 12 hardening fixes (bundled)

Round 5 of the ongoing codex + gemini audit cycle, focused on the
two LiveView modules deferred from round 4 (kanban_live + agent_live
— too large for one codex invocation last round) plus the
multi-tenant message-routing surface (chat/proposals/router/doctor).
6 HIGH (5 in the deferred LV files + 1 in agent_live audit filter),
3 MED, 3 LOW (4th LOW deferred — needs design discussion).

- **Cross-tenant kanban access via symlinked project ancestor**
  (codex, HIGH) — `KanbanLive.resolve_task_path/2` ran only the
  LEAF check via `AgentWritableFile.ensure_regular/1`; a
  symlinked PROJECT or TASKS ancestor (e.g. agent plants
  `projects/evil → ../../<other-co>/projects/private`) passed
  the regex + leaf-lstat and let `open_task` / `save_task` /
  `kanban:move` read+mutate cross-tenant task files. Wraps the
  resolved path through
  `Sandbox.SymlinkGuard.assert_no_symlink_segment!/2` so any
  ancestor symlink causes refusal.

- **Cross-tenant kanban board enumeration** (codex, HIGH) —
  `KanbanLive.load_tasks/2` did a bare `File.ls` on
  `projects/*/tasks/*.md` with no `Slug.valid?` gate and no
  `real_directory?` check on the project dir, despite the same
  module's `list_projects/2` already enforcing that discipline.
  A symlinked project dir surfaced another tenant's task titles,
  assignees, and statuses on every `file_event` refresh. Now
  filters via `Glorbo.Slug.valid?/1 + real_directory?/2` before
  recursing — same shape as `list_projects/2`.

- **Kanban save_task bypassed approval gate** (codex, HIGH) —
  `KanbanLive.save_task/3` wrote client-supplied `status` and
  `requires_approval` straight via
  `TaskDefinition.write_frontmatter/2`; the sibling `kanban:move`
  handler gated via `refuse_if_bypasses_approval_gate/2` but
  `save_task` was bypassed entirely. A crafted save_task payload
  could set an approval-gated task straight to `done`, or zero
  its `requires_approval` field to remove the gate. Now calls
  the existing gate refuse + a new
  `refuse_if_clears_required_approval/2` (refuses clearing
  `requires_approval` while the on-disk task is still
  gate-pending).

- **Kanban drag/drop missing audit emission** (codex, MED) —
  `kanban:move` wrote `status` via `TaskDefinition.write/2`
  without emitting any audit entry; the sibling `save_task`
  path emits `task.edit` via `emit_task_edit_audit/3`.
  Drag-to-done left no forensic trail of the status change
  actor/time. New `emit_kanban_move_audit/3` emits `task.move`
  with the new_status detail, parity with the form-edit path.

- **Kanban attachment listing leaks across tenants** (codex, MED)
  — `KanbanLive.list_task_attachments/3` used bare `File.ls` +
  `File.stat` (both follow symlinks) with no `Slug.valid?` on
  project/task_id and no `real_directory?` on the attachments
  dir. Combined with the symlinked-project primitive (above)
  this leaked another tenant's attachment filenames + sizes on
  overlay open. Now slug-gates inputs, walks ancestors via
  `SymlinkGuard`, and uses `File.lstat` for per-entry size to
  avoid following symlinks.

- **agent_live create_file bypasses dedicated Actions** (codex,
  HIGH) — `Glorbo.Actions.Agents.create_workspace_file/4` refused
  only `@contract_files` (`AGENT.md` + `stdout.log`); paths like
  `state/wake-request-foo.md`, `inbox/anything.md`,
  `outbox/memory/x.md`, `history/...` were accepted by the
  generic file manager. Authenticated dashboard client could
  create a wake-trigger or a forged inbox message via the file
  manager UI, bypassing the higher-level `wake_agent/4` +
  `post_message/N` validation + audit shape (only an
  `agent.file_create` row, not the dedicated wake/message audit).
  New `refuse_dedicated_subtree/1` rejects any rel_path whose
  first segment is `state` / `inbox` / `outbox` / `history` —
  those have their own action functions with stricter validation.

- **agent_live audit filter prefix collision** (codex, HIGH) —
  `audit_for_this_agent?/2` used
  `String.starts_with?(target, "agents/#{slug}")` so a sibling
  agent named `ceo2` polluted the audit/history stream of the
  parent `ceo`. Now matches the exact `agents/<slug>` literal
  or the `agents/<slug>/` namespace prefix — same defense pattern
  to grep for in audit_export_controller / inbox_live.

- **agent_live memory tab: symlink-follow + DoS** (codex, HIGH) —
  `load_memory_files/1` used `File.read` (follows symlinks; no
  byte cap) + `File.stat` (follows symlinks) with no file-count
  cap. (a) Symlink dimension: agent plants
  `memory/feedback_x.md → ../../../<other-co>/agents/<other>/AGENT.md`
  → dashboard renders cross-tenant content. (b) DoS dimension:
  agent writes many large memory files via the outbox/memory
  pipeline → opening Memory tab pegs the dashboard. Switched to
  `AgentWritableFile.read_bounded/2` (round-3 helper) with a
  256 KiB per-file cap, capped the entry list at 200 post-sort,
  and uses `File.lstat` for stat.

- **Cross-company proposal flip via path traversal** (gemini, MED)
  — `Glorbo.Company.Proposals.flip/4` accepted `id` straight
  from the LiveView WS frame without slug validation and passed
  it into `Path.join`. `AgentWritableFile.ensure_writable/1`
  only does lstat — no `..` normalisation. A logged-in dashboard
  user could craft a WS frame with
  `id: "../<other-co>/proposals/<their-id>"` and approve/deny
  proposals in ANOTHER company, bypassing the URL's `:company`
  scoping. (Director model is single-token so this didn't cross
  user boundaries, but it did break per-company scoping for
  write ops.) Now validates `id` against
  `~r/\A[a-z0-9][a-z0-9_-]*\z/` and company slug at flip/4's
  entry; returns `{:error, :invalid_proposal_id}` (or
  `{:error, :invalid_company}` for a bad company slug) on miss.

- **Router rejection-write YAML scalar injection** (gemini, LOW)
  — `write_rejection_file/3` and `write_rejection_notice/3`
  interpolated `msg.msg_id`, `msg.sender`, `msg.to` into quoted
  YAML scalars via raw `"#{...}"` interpolation.
  `validate_message/1` blocked `\n \r \0` (and `/` in `msg_id`)
  but NOT `"`. A malicious agent sending `to: foo"bar`
  corrupted the YAML in `history/<msg_id>.rejected.md` and
  `agents/<sender>/inbox/rejections/...`. Newline-based
  smuggling already closed; this is YAML-parse-DOS / audit-log
  corruption only. Every interpolated field now piped through
  `Glorbo.Filesystem.FrontmatterWriter.yaml_scalar/1`.

- **Doctor fix_sockets_dir File.chmod follows symlinks** (gemini,
  LOW) — `File.chmod` follows symlinks. If
  `~/.glorbo/runtime/sockets` were ever a symlink to another
  directory the user owns, the chmod would silently tighten
  perms on the target. Requires write into `~/.glorbo/runtime/`
  (not in any agent's bwrap mount view) so agent-driven
  escalation is unlikely — operator-CLI defense-in-depth. New
  `ensure_real_directory/1` runs `File.lstat` + type check
  before chmod; refuses on symlink.

NOT IN BUNDLE (logged):

- LOW codex `agent_live.ex:216/259` — no per-agent rate limit on
  dispatch-triggering wakes (needs design discussion on
  token-bucket placement: per-LV vs ETS vs supervisor; deferred
  to round 6).
- LOW gemini `router.ex:832-843` ancestor-symlink TOCTOU —
  documented known limitation; Erlang stdlib doesn't expose
  `openat`/`O_NOFOLLOW`, so partial mitigation only without a
  C NIF. Documented in module doc; logged for future GEP if
  threat model changes.
- DEFERRED to round 6: nice-to-haves from codex/gemini
  (search.ex `File.ls` ancestor symlink — same shape as
  formatter; `reject_symlink_entries` allowlist `[:regular,
  :directory]` to also block :char/:block/:fifo; audit-export
  open-then-stream still a check→use race — operator-managed
  dir = practical exposure nil).

### Security — codex + gemini round-4 deep-dive: 10 hardening fixes (bundled)

Round 4 of the ongoing codex + gemini audit cycle, scanning the
post-PR-#35 codebase. 10 findings bundled into one PR per the
"reduce review-cycle overhead" workflow; 2 HIGH (1 tar-extraction
bypass + 1 peer-review gate bypass), 4 MED (1 TOCTOU + 1 inbox
sentinel-spoof + 2 symlink-following), 4 LOW (3 defense-in-depth
+ 1 grant-pattern). Codex deferred `kanban_live.ex` +
`agent_live.ex` (too large for one codex invocation) → flagged
for round 5.

- **Restore tar symlink-extraction bypass** (gemini, HIGH) —
  `Glorbo.Restore.extract/2`'s `:erl_tar.extract` materialised
  entries in archive order, including symlinks. A crafted
  archive with entry 1 = `evil` (symlink → `/tmp`) + entry 2 =
  `evil/payload` (regular file) caused the kernel to write
  `/tmp/payload` during EXTRACT — `verify_no_escaping_symlinks`
  walked staging post-extract but couldn't undo the out-of-tree
  write. The pre-extract `traversal_guard/1` only inspected
  entry NAMES via `:erl_tar.table`, not link TARGETS. Fix:
  `reject_symlink_entries/1` refuses ANY archive containing
  `:symlink` or `:link` entries up-front. Glorbo backups never
  contain links (`Backup.run` builds via `:erl_tar.create` on a
  flat file list which stores resolved file content, not link
  records), so any link entry is the attack we're defending
  against (or a non-Glorbo archive we don't support). New
  regression test plants a `staging/evil → /tmp` symlink entry
  and asserts pre-extract refusal.

- **Peer-review verdict agent-self-approval bypass** (codex, HIGH) —
  An agent assigned to a task can write its own task .md file
  (`projects:write:<proj>` → `tasks/`) and pre-seed
  `peer_review_required: true` + `peer_review_verdict: "approve"`
  directly into the frontmatter. `Glorbo.Approvals.Gate.peer_review_ready?/1`
  only checked the verdict string, never that the verdict had
  been recorded through `Actions.Tasks.record_peer_review_verdict/4`
  (which enforces `guard_actor_is_reviewer/2` and emits the
  audit row). The gate now requires a corroborating
  `task.peer_review.approve` audit entry with `actor` matching
  the task's `peer_review_verdict_by` slug AND `target` matching
  the task path — same pattern as round-3's loop-detector
  corroboration. Closed in concert with round-3's
  `emit_tool_audits` whitelist (`Tools.valid_audit_action?/1`
  rejects `task.peer_review.approve` from agent-supplied
  `audit_events`, so the corroboration row can't be forged).
  Codex pre-push review of 3dc4eba caught a P0 regression in
  the initial gate compare: it used `"agent:" <> verdict_by`
  but the legit emitter writes the bare slug — every real
  reviewer-emitted approval would have failed corroboration in
  production. Both compare + seed helper now use the bare-slug
  shape; new G18-emitter-contract test pins the
  cross-file invariant (matches tasks_test:301 emitter
  assertion). New G18-bypass regression test pins the refusal
  shape.

- **Search index TOCTOU lstat→read** (gemini, MED) —
  `Glorbo.Search.parse_fields/2` ran `:file.read_link_info`
  (lstat — refuses symlinks), then called `File.read(path)`
  later, which re-resolves and follows symlinks. An agent that
  owns its task file can race the indexer:
  `unlink t-1.md && ln -s /home/.../other-co/proposals/secret.md t-1.md`
  between the two checks. The secret then becomes the task's
  `title` in the search cache → Ctrl+K leaks it to the director.
  Defense: `read_task_body_with_inode_check/1` opens an fd
  first, fstats it, compares the fstat inode to the inode the
  lstat saw moments earlier; refuses on mismatch. Erlang's
  `:file.open` doesn't expose `O_NOFOLLOW`, so this is the
  closest we can get without a C NIF.

- **Inbox sentinel-row spoofing** (codex, MED) —
  `Glorbo.InboxLive.sentinel_row/4` rendered any
  `agents/*/state/awaiting-approval-*.md` file as a pending
  approval row by globbing the task by id; no check that the
  task was actually in `status: pending-approval`. A malicious
  agent could drop `agents/<own>/state/awaiting-approval-victim-99.md`
  and the Director's Inbox would show victim-99 as pending —
  an Approve click would call `Actions.set_approval(:approved)`
  which only validates slug/path, flipping the victim task's
  status. Fix: require the actual `TaskDefinition.status ==
  "pending-approval"` before listing the row. Initial fix in
  3dc4eba was looser (`requires_approval` set + status not
  terminal); codex pre-push review noted the agent could
  trivially set `requires_approval: director` on its own task,
  so tightened to the canonical post-`Gate.request_approval`
  state. Sentinel left on disk for forensic + operator's manual
  review.

- **Audit symlink-following on dashboard reads** (codex, MED;
  3 sites) — `audit_export_controller`, `inbox_live`, and
  `task_live` all called `File.regular?` + `File.stream!` on
  `companies/<co>/audit/<YYYY-MM>.jsonl`. Both follow symlinks.
  If any agent ever has transient write to the `audit/` dir (or
  an ancestor), a planted symlink redirects the read to an
  arbitrary host path the daemon user owns. All three sites now
  gate via `Sandbox.SymlinkGuard.assert_no_symlink_segment!/2`
  + leaf `File.lstat` before streaming.

- **Formatter follows agent-planted symlinks** (codex, MED) —
  `Glorbo.FileSpec.Formatter.expand_paths/1` used `File.stat` +
  `File.regular?`, both of which follow symlinks. If `glorbo fmt
  --write` ran over a path containing agent-planted symlinks
  (e.g. agent symlinks `projects/x/tasks/t.md` → `/etc/passwd`),
  the formatter would read the link target and write a
  re-rendered version back into the company tree — exfiltrating
  host content into agent-readable storage. Initial fix in
  3dc4eba switched the LEAF check to `File.lstat` — but codex
  pre-push review noted that `Path.wildcard("**/*.md")` itself
  descends through symlinked intermediate directories, and
  `lstat` on the leaf resolves all-but-last (so a symlinked dir
  in the middle is invisible to leaf-only lstat). Now uses
  `Sandbox.SymlinkGuard.assert_no_symlink_segment!/2` on each
  candidate to reject any ancestor symlink, then the leaf
  lstat catches symlinked files.

- **Restore archive TOCTOU** (gemini, LOW) — `traversal_guard/1`
  and `extract/2` each opened the archive path independently. On
  a shared filesystem (archive in `/tmp` with concurrent
  writers), an attacker with write to the archive path could
  swap a verified-safe archive for a malicious one between the
  two opens. Single-user host: not exploitable. Defense-in-depth:
  `copy_archive_to_private/2` copies the archive bytes into a
  private path under `base` (which the daemon user owns) with
  `:file.open([:exclusive])` (O_EXCL); both passes run against
  that immutable local copy; cleaned up in `run/2`'s `after`.

- **home_history validate_rev permitted extended-SHA1 syntax**
  (gemini, LOW) — `validate_rev/1` rejected control chars,
  whitespace, leading `-`, but permitted `:`, `~`, `^`, `@{`,
  `..`. All carry extended `git rev-parse` semantics (`rev:path`,
  `rev~N`, `rev^N`, `rev@{date}`, `A..B`) that turn a single-rev
  arg into a range / blob-path / reflog lookup. Only `glorbo
  history show <rev>` is the live caller (director → director
  privilege boundary). Now rejects those characters outright.

- **company_boot File.dir? follows symlinks** (gemini, LOW) —
  `CompanyBoot.do_boot/1` checked `File.dir?` on
  `companies/<slug>`. An attacker who can plant
  `~/.glorbo/companies/<valid-slug>` as a symlink to an
  attacker-controlled tree (requires write to user's $HOME,
  already-compromised host) would have CompanyBoot start a
  supervisor against that tree. New `real_directory?/1` uses
  `:file.read_link_info` so symlinks don't qualify.

- **BrainDump + Search + Inbox.Archive missing internal Slug
  guards** (gemini, LOW) — Public functions accepted a
  `company`/`co` string without internal `Glorbo.Slug.valid?`
  validation. All current callers (BrainDumpLive, MCP
  CaptureBrainDump, SearchController, InboxLive) gate via
  `Slug.valid?` before calling, so not exploitable today, but a
  future caller forgetting the gate would let
  `co == "../../etc"` reach `Path.join`. Mirrors round-3's
  hardening of `Audit.Query` and `Tools.valid_audit_action?` —
  add the gate at module entry, fail safe.

### Security — codex + gemini round-3 deep-dive: 8 hardening fixes (bundled)

Round 3 of the ongoing codex + gemini audit cycle, scanning the
post-PR-#34 codebase. 8 findings bundled into one PR per the
"reduce review-cycle overhead" workflow; 5 HIGH severity (4
agent-driven privilege/bypass primitives + 1 cross-agent sandbox
escape), 1 MED (workspace symlink-follow), 2 LOW (defense-in-
depth + grant-leak window).

PR-review feedback round (codex P1 + Copilot, post-push of d5ba9b5):
calendar arithmetic fix for the corroboration-month rollover boundary
(was `DateTime.add(-32d)`, now `Date.beginning_of_month |> Date.add(-1)`),
loud failure on workspace `File.rm` errors (was silent — would have
restored the symlink-follow bug if rm ever returned `{:error, _}`),
sanitisation of `sample_actions` in the audit-rejection feedback row
(was raw `event.action`; non-binary or oversized terms now stringified
+ truncated to 80 bytes via `Util.UTF8.safe_byte_slice`), comment
correction in `stop_inflight`. 5 new boundary regression tests for the
corroboration calendar math.

- **Cross-agent sandbox escape via permission-mount symlink-segment**
  (codex, HIGH) — `Glorbo.Sandbox.PermissionMapper` emitted bwrap
  `--bind` / `--ro-bind` source paths without checking ancestor
  symlinks. Agent A holding `projects:write:foo` could plant a
  symlink at `<co>/projects/foo/tasks` → `~/.ssh`; agent B holding
  `tasks:update:foo` would then have bwrap resolve the symlink
  HOST-SIDE before the namespace switch, mounting `~/.ssh` rw
  inside B's sandbox at `/projects/foo/tasks`. Affected all
  per-scope clauses (`projects:read/write:<name>`,
  `chat:read:<channel>`, `tasks:update:<project>`). Hoisted the
  existing `Bwrap.assert_no_symlink_segment!/1` helper (from the
  GEP-27 approved-path check) into a new
  `Glorbo.Sandbox.SymlinkGuard` shared module; both call sites now
  walk + lstat every host source's ancestor segments before
  emitting the argv triple. 4 regression tests cover leaf-symlink,
  ancestor-symlink, chat-channel symlink, and happy-path.

- **Agent forges system audit actions** (gemini, HIGH) —
  `Glorbo.Agent.Dispatch.emit_tool_audits/5` forwarded
  `event.action` verbatim from the parsed CLI output into the
  audit log's `action` field. An agent could forge
  `agent.complete` (defeats LoopDetector's failure-chain
  detection), `budget.usage` (poisons reindex spend rebuild), or
  `approval.granted` (poisons approval rebuild). The native_v1
  parser already filtered at parse time, but the audit-emission
  boundary was missing the gate — any parser regression (or new
  parser) would reopen the hole. Added
  `Glorbo.CLI.Harness.Tools.valid_audit_action?/1` as the canonical
  whitelist (the same `tool.*` + `egress.web_fetch` set the
  parser uses); emission now filters via this gate and emits a
  `agent.tool_audit_rejected` audit row for any drop attempt.
  Whitelist coverage + 4 rejection-shape tests pin the new gate
  shut.

- **Inbox-message task_id traversal/glob into reply path** (gemini,
  HIGH) — `Glorbo.Agent.Server.reply_target/1` and
  `resolve_task_path/2` flowed attacker-controlled `task_id` from
  inbox-message frontmatter straight into `Path.wildcard` —
  shapes like `task_id: "../foo"` (traversal) or `task_id: "*"`
  (glob expansion) could match arbitrary task files in the
  company, and `apply_task_actions` would then run `reassign` /
  `status` mutation on the matched file. Both call sites now
  validate via the existing `safe_task_id?/1`
  (`~r/\A[a-z0-9][a-z0-9._-]*\z/`) — defense-in-depth at both
  the routing seam and the wildcard interpolation site. TA-7
  regression test exercises 9 malicious shapes and asserts the
  real task file stays untouched.

- **Agent-forged loop-detector resolutions bypass ACL** (gemini,
  HIGH) — `Glorbo.Agent.LoopDetector.apply_resolution_files/3`
  scans `agents/*/state/resolved-*-*.md` and applies any
  resolution that has a sibling `stuck-on-*.md` sentinel. Both
  files live in the agent's own state dir (agent-writable). A
  malicious agent could forge both for any task in the company
  and on the next `InboxLive` render the task would silently get
  `status: denied` (or `assigned_to: director` on skip) —
  bypassing the `projects:write` ACL entirely since
  `apply_task_mutation` doesn't re-check permissions. `resolve/5`
  now requires a corroborating `agent.loop_detected` audit entry
  with `actor: "system"` for `{agent, task_path}` before honoring
  the mutation; director-origin resolutions (button click) skip
  the check since the operator is authoritative by design. Closed
  in concert with the `emit_tool_audits` whitelist (so the agent
  can't forge `actor: "system"` audit rows in the first place).
  3 hardening rounds against codex's pre-push review of d5ba9b5
  layered on top:
  - **PATH-derived agent binding.** Frontmatter `agent` was
    agent-controlled — agent A under `/agents/A/state/` could
    forge `agent: B` to inherit any legit B-corroboration row.
    `apply_one_resolution/4` now passes the path-derived agent
    via `:path_agent`; `resolve/5` refuses with
    `:sentinel_agent_mismatch` on disagreement.
  - **Frontmatter `audit_month` ignored.** Was passed as
    `:month` to the audit query, letting agent A point the scan
    at any historical month with a legit row. Now scans current
    UTC month + previous (covers month-boundary races) only;
    no agent input honored.
  - **24h freshness window.** Without it, a single legit
    `agent.loop_detected` row could be replayed indefinitely.
    `agent.loop_detected.ts` must fall within the last 86 400
    seconds — long enough for legit operator-reaction lag,
    short enough to render replay attacks uninteresting.

  3 new regression tests for the codex-review hardening (frontmatter
  agent mismatch, stale corroboration, multi-agent file-drop),
  plus the original agent-origin refusal test; 3 pre-existing
  file-drop tests updated to seed the corroborating audit row.

- **Untracked-budget bypass via parser failure** (gemini, HIGH) —
  `Glorbo.Agent.Dispatch.check_runtime_untracked_allowed/3` gated
  only the explicit `usage: %{tracked: false}` shape. A parser
  crash (e.g. agent corrupts `usage.json` or emits bytes that
  trip the JSON decoder) returns `%{usage: nil, usage_error: <reason>}`
  — which fell through the wildcard catch-all to `:ok`, recording
  zero spend against a tracked-only budget. Narrow fix: refuse
  ONLY the parser-failure shape (`usage: nil` + `usage_error`
  set); the legitimate `:none` parser path
  (`usage: nil, usage_error: nil`) is still allowed when
  `allow_untracked_budget: true`. 2 new tests + 19 existing
  dispatch-flow tests rerouted via fixture update to keep
  exercising what they meant to exercise.

- **Workspace mkdir_p! follows attacker-planted symlinks**
  (gemini, MED) — `Glorbo.Agent.Dispatch.ensure_workspace/2`
  called `mkdir_p!(path/.local/share)` etc. directly; the
  workspace is rw-mounted INSIDE the sandbox so a previous
  dispatch could pre-plant `.local` as a symlink to an arbitrary
  host directory, and the next dispatch's host-side `mkdir_p!`
  would create `share`/`state` under the symlink target (another
  company's state dir, etc.). New `ensure_workspace_subdir!/3`
  walks each segment with `lstat`, removes any symlink found
  (and any non-directory entry), and recreates as a fresh dir
  before mkdir-ing the next segment. Regression test plants a
  symlink to a "victim" dir and asserts the workspace bind is
  unaffected after dispatch.

- **Audit query :month path-traversal foot-gun** (gemini, LOW) —
  `Glorbo.Audit.Query.for_task/4` interpolated the `:month` opt
  into the audit file `Path.join` with no validation. No live
  caller currently exposes `:month` from a request param, but
  one MCP tool already accepts month-range opts; a future caller
  dropping it through could path-traverse into any JSONL on
  disk. Now enforces `\A\d{4}-(0[1-9]|1[0-2])\z`; invalid or
  non-binary values silently fall back to the current UTC month
  rather than raising (callers without `:month` already got that
  fallback via `Keyword.get_lazy/3`). 14 malicious + 4
  non-binary shapes pinned shut.

- **stop_inflight leaks PathGrantStore grants past SIGKILL**
  (gemini, LOW) — `Glorbo.Agent.Server.handle_call/2` for
  `:stop_inflight` called `Process.exit(:kill)` on each in-flight
  dispatch Task. SIGKILL bypasses the `Dispatch.do_execute/4`
  post-with cleanup that normally calls `PathGrantStore.revoke/3`
  (plus the proxy-token revoke and slot release). PathGrantStore
  grants would leak under the `{company, agent, task_id}` key
  until the next dispatch of the same task overwrote them
  (emergency-stop blocks new dispatches in this state, bounding
  but not closing the window). Now revokes grants explicitly
  BEFORE the kill; the proxy-token expiry failsafe + semaphore
  pid-monitor catch the other two. Regression test pre-pins a
  grant, calls stop_inflight, asserts the grant is gone.

### Security — codex + gemini round-2 deep-dive: 6 hardening fixes (bundled)

Bundled wave addressing the second-round codex + gemini deep-dive
against the codebase post-PR-#33. All fixes surgical, no design
changes:

- **Provider TOML secret masking misses env keys** (codex,
  medium) — `GlorboWeb.ProvidersLive.mask_toml_secrets/1` regex
  caught only bare `api_key`/`token`/`secret`/`password`/`auth`/
  `access_key` and only double-quoted strings, so env-style names
  (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GITHUB_TOKEN`,
  `*_BEARER_TOKEN`, `*_COOKIE`, `*_PASSWORD`, single-quoted strings)
  rendered in plaintext on `/providers`. Now matches any TOML key
  whose name contains `key`, `token`, `secret`, `password`, `auth`,
  `bearer`, `credential`, `cookie`, `session`, `sas`, or
  `signature` (case-insensitive substring) and masks both quote
  styles. 4 focused tests on the helper.

- **Provider names can escape provider-owned paths** (codex, low) —
  `Loader.build_provider/3` accepted `raw["name"]` without slug/
  path-component validation; the name flowed into model-cache
  filenames, native-credential filenames, ACP session paths
  (`<reply_dir>/../sessions/<name>__<task_id>.txt`). A config-
  influencer could put `..` segments or `/` in the name and escape
  the provider-owned dirs. Now validated with strict
  `[a-z][a-z0-9_-]{0,63}` slug regex at parse time; 6 bad / 5 good
  shapes covered.

- **Incremental reindex bypasses symlink-ancestor rejection**
  (codex, medium) — `Glorbo.Filesystem.Reindex.process_path/2`
  (watcher-driven) went straight to `process_file/1` which only
  lstat'd the LEAF. Full-pass reindex's `safe_markdown_files/1`
  already rejected any path whose ancestor crossed a symlink; the
  incremental path now mirrors that discipline at the ancestor
  level. Leaf-symlink rejection stays in `process_file/1`.
  Regression test plants a symlinked sub-directory and verifies the
  watcher refuses to index files reached through it.

- **ACP reply/session writes trust workspace symlink ancestors**
  (codex, medium) — `Dispatcher.prepare_reply_dir/3` and
  `write_acp_session_id/2` did `mkdir_p!` on the parent with no
  lstat check on the ancestor chain. The ACP CLI runs concurrently
  in the workspace and can replace `.glorbo/outbox` (or
  `.glorbo/sessions`) with a symlink before returning, turning the
  host dispatcher into a confused-deputy writer at an attacker-chosen
  path. Both sites now call `AgentWritableFile.any_symlink_in_path?/1`
  on the parent BEFORE `mkdir_p!`; refusal is logged + skipped
  (session) or raised (reply dir). Regression tests cover both
  rejection + happy-path.

- **PathRequestGate denylist too narrow** (gemini, medium) —
  `@forbidden_paths` only covered `/proc /sys /dev`; an auto-
  approving director (or a human skimming a long path list) could
  approve a request for `/etc/shadow`, `~/.ssh/id_*`,
  `~/.glorbo/config.md` (dashboard_token + key_base), `/root/`,
  cloud-cred dirs, etc. Broadened to `/etc`, `/root`, `/boot`,
  `/var/log`, `/var/lib`, `/var/spool`, `/lib`, `/lib64`,
  `/usr/share/keyrings`, `/run/secrets`, plus HOME-relative dirs
  (`.ssh`, `.gnupg`, `.aws`, `.glorbo`, `.kube`, `.netrc`, and
  several more). HOME is resolved lazily so test runs can override.
  11 host-root paths + 6 HOME-relative paths pinned shut.

- **PathRequestGate task_id self-defense** (gemini, low) —
  `validate_request/1` only checked `is_binary(task_id) and != ""`,
  relying on the single live caller (`Glorbo.Company.Router`) to
  slug-validate first. Any future caller / out-of-band reader that
  skipped Router could open a YAML-injection / path-traversal hole.
  Gate now enforces the same `[a-z][a-z0-9_-]*-\d+` slug regex
  Router uses, so it's self-defending. 7 malformed task_id forms
  rejected, 4 well-formed accepted.

### Security — codex deep-dive follow-up: auth-bind canonicalisation, UTF-8-safe audit truncation, throttled-stall fix, PLT relocation, flake fix

A bundled wave of fixes addressing the five codex findings filed after
the v0.24.0 deep-dive review, plus one CI flake the wave surfaced:

- **Auth-bind dot-segment bypass** — `cli_auth_bind_flags`'s
  `normalise_path/1` previously stripped only ONE trailing `/.`, so
  variants like `/etc/./`, `/./etc`, `/./`, and `/workspace/./` slipped
  past the critical-mount denylist (kernel resolves them to the same
  forbidden target). Now uses `Path.expand/1` which collapses ALL
  dot-segments. The pre-existing `..` rejection runs first so
  `Path.expand`'s silent `..` resolution can't be smuggled. New
  regression tests pin 9 dot-segment shapes shut.
- **UTF-8-safe audit truncation** — `Glorbo.Util.UTF8.safe_byte_slice/2`
  is the new shared helper; both `Glorbo.Agent.Dispatch.bound_target/1`
  (tool-audit `target`, 1 KiB cap) and
  `Glorbo.CLI.Dispatcher.Acp.Client.truncate_string/1` (ACP detail
  fields, 256 B cap) now route through it. Previously `binary_part/3`
  could split a multi-byte codepoint, leaving an invalid UTF-8 binary
  that crashed `Jason.encode!` in the audit writer — which then
  dropped the audit record (the calling `Audit.emit/3` swallows the
  failure). The new helper walks back over UTF-8 continuation bytes
  so the cap lands on a codepoint boundary, even for 2/3/4-byte
  sequences. 7 focused tests cover ASCII, é/日/🦊 split-tail cases,
  and Jason-encodability round-trip.
- **Throttled inbox stall** — `Agent.Server`'s
  `finish/{:throttled, ...}` recorded `pending_wake` but had no retry
  mechanism; the per-company `DispatchSemaphore` doesn't notify on
  slot release, so the only consumer of `pending_wake` was a future
  unrelated dispatch's `drain_on_free`. A malicious agent that kept
  the cap saturated could stall other agents' work indefinitely. Now
  arms a jittered (1–5 s) `Process.send_after :throttled_retry` self-
  message, coalesced via a `throttled_retry_ref` so successive
  throttles don't pile up timers. Polling is bounded and only fires
  when the agent has queued work; no semaphore-coupling needed.
- **PLT relocation** — `dialyzer:` `plt_local_path` and
  `plt_core_path` moved from `priv/plts/` (inside the application's
  runtime priv tree, which Mix releases bundle as runtime data and
  Burrito packages into the shipped binary) to `_build/dialyzer_plts/`
  (release-excluded). CI cache key bumped to `plt2-…` so old cache
  entries don't restore into the new location. Avoids artifact
  bloat + low-sensitivity build-metadata leak in shipped releases.
- **`channels_test.exs` flake** — Replaced two `Process.sleep(1000)`
  calls in the `channel.archive` test with a polling
  `wait_for_history_head/3` helper. Under loaded CI (especially
  aarch64) the 1 s sleep wasn't always enough for the commit to
  fsync; the test then read HEAD and got the previous
  `channel.create` commit. Polling waits up to 10 s for the expected
  subject prefix and flunks with a clear diagnostic on timeout —
  faster on the happy path (3.4 s vs ~10 s wall) AND robust against
  slow runners.

## [0.24.0] — 2026-05-23

Substantial security-hardening release driven by a deep-dive review
using codex + gemini in parallel. **One critical, three high, five
medium** issues fixed across the sandbox, dispatcher, auth, and tool
surfaces. See entries below for per-PR detail.

### Docs — landing-page version auto-syncs to `mix.exs`

The marketing site (`assets/index.html`, deployed via the GitHub Pages
workflow) hardcoded the version in three spots and had drifted to
v0.11.1. Fixed for this release (now shows v0.24.0) AND the
`Deploy static content to Pages` workflow now re-derives the version
from `mix.exs` at deploy time, sed-substituting any `v<x>.<y>.<z>`
matches in `assets/index.html` before upload. The committed source
stays in sync at release-cut time; the deploy step is the safety net.
The trigger filter also now includes `mix.exs` so a release commit
without `assets/` changes still re-deploys.

### Security — approved-path TOCTOU re-check at bwrap argv assembly (codex-F2)

`Glorbo.PathRequestGate.do_approve/4` canonicalises every approved
path with `validate_no_symlink_segments/1` at APPROVAL time, then the
grant sits in `PathGrantStore` until the agent dispatches. Between
those events an attacker with write access to any ancestor of the
granted path could plant a symlink (`/home/u/granted-dir → /etc`) and
have `bwrap` bind the redirect, escaping the approved scope.

Fix: re-walk lstat-checks on `host_path` at `approved_path_flags/1`
argv-assembly. The TOCTOU window collapses to the `assert → Port.open`
interval (microseconds, host-FS-bound). Trailing `:enoent` segments
are still allowed (operator may approve a path the agent will create).
Regression test plants a symlink between two `approved_path_flags`
calls to prove the second one raises. Identified by the codex
deep-dive sweep.

### Security — unsandboxed runner gets drain caps + symlink-gated stdout tee (codex-F7/F8)

`Glorbo.Sandbox.Unsandboxed` (the macOS / `--no-sandbox` runner) was
missing two defenses that `Glorbo.Sandbox.Bwrap` had:

1. **Drain caps (F8).** `drain_loop`'s in-memory `acc <> data` was
   unbounded and `IO.binwrite(tee_io, data)` had no per-dispatch ceiling.
   A malicious or runaway CLI writing GBs to stdout could balloon BEAM
   heap AND fill the host filesystem (the tee log is append-mode and
   persists across dispatches). Now mirrors the bwrap path's 16 MiB
   in-memory + 16 MiB on-disk caps; once a cap is reached the port is
   still drained to completion so the CLI's exit code surfaces, but
   subsequent chunks are dropped + a one-shot truncation marker is
   written to disk.

2. **Stdout-tee symlink gate (F7, see below).**

### Security — stdout-tee paths lstat-gated before append (codex-F7)

Both `Glorbo.Sandbox.Bwrap` and `Glorbo.Sandbox.Unsandboxed` opened
the per-dispatch stdout tee log with
`File.open(stdout_log_path, [:append, :binary])`, which **follows
symlinks**. The agent has write access to its own
`agents/<slug>/stdout.log` slot; a pre-planted symlink there could
redirect host-side appends to any path the BEAM process can write —
`/tmp/glorbo.pid`, `~/.bashrc`, the operator's audit log, etc. Under
bwrap the bind layout limits the agent's reach during normal
execution, but the stdout-tee opens happen on the HOST side
(`open_stdout_tee/1` runs in the BEAM, not the sandboxed child), so
a symlink redirects host-side I/O directly.

Fixed by routing both call sites through
`Glorbo.Filesystem.AgentWritableFile.ensure_writable/1` (lstat-gates
the path before open: only regular files, or nonexistent paths where
the open creates a fresh file, are tee'd). The bwrap path logs a
warning on refusal so an operator-noticed misconfiguration surfaces in
the daemon log; the unsandboxed path silently degrades to nil
(best-effort logging stays best-effort — matches the existing
unsandboxed semantics where logging itself is permitted to fail without
disrupting the dispatch). Identified by the codex deep-dive sweep.

### Security — strip-query redirect refuses protocol-relative paths (gemini-F4)

`GlorboWeb.Plugs.DashboardToken.maybe_strip_query_token/1` 302-redirects
authenticated browser requests to the same URL minus `?token=` (C-120),
using `conn.request_path` as the `Location` header. If
`request_path` were `//evil.com/foo`, the resulting protocol-relative
`Location` header is followed off-origin by browsers — open-redirect
from a trusted origin. Bandit should normalise `//` to `/` but
defense-in-depth: a new `safe_request_path?/1` guard refuses to emit
the 302 for any path that doesn't start with a single `/`, or that
contains a backslash, NUL, CR, LF, or embedded `://`. In those
pathological cases the strip becomes a no-op (the request still
authenticates; only the cosmetic URL-bar cleanup is dropped).
Regression test pins 8 unsafe shapes (`//evil.com/...`,
`/\evil.com/...`, embedded CRLF, NUL, scheme, etc.). Identified by
the gemini deep-dive sweep.

### Security — `SmartClassifier` rejects integer-encoded IPv4 SSRF bypass

`Glorbo.Network.SmartClassifier.private_ip?/1` only string-prefix-checked
canonical dotted-decimal private IPs. An attacker could encode
`169.254.169.254` (AWS metadata) as the decimal `2852039166`, octal-dotted
`0251.0376.0251.0376`, hybrid `169.16689662`, or short-form `127.1` — all
forms that `inet_aton`'s legacy parser resolves to the same bytes, yet
none matched the string-prefix checks. In `:deny`-mode (denylist) egress
the classifier returned `:allow, :denylist_fallthrough` for these
encodings, polluting the smart-mode cache and the audit log with a
misleading allow verdict. (The proxy's DNS-rebind defense in
`open_and_splice` still catches the *resolved* IP for the data path, but
the classifier's T8 invariant — "no private-IP destination, ever" — must
hold at this layer too; a future refactor could drop the second layer
and re-expose the bypass.) Fixed by adding a `numeric_ip_shaped?` regex
gate followed by a no-DNS `:inet.getaddrs` resolution + tuple-form
private-IP check. Regression tests pin 9 integer-encoded forms and 4
public negatives (wave 26 in `smart_classifier_test.exs`). Identified by
the codex deep-dive sweep + empirical verification.

### Security — tool I/O paths refuse symlink-ancestor crossings (codex-F3/F4)

`Glorbo.CLI.Harness.Tools.resolve_tool_path/2` did a **lexical-only**
workspace containment check (`Path.expand` + `String.starts_with?`). If
an agent planted a symlink at `<workspace>/escape` pointing OUT of the
workspace (`/etc/`, `/`, etc.), a subsequent `write_file`/`edit_file`/
`read_file`/`grep` tool call with `path = "escape/poc"` would
canonicalise to `<workspace>/escape/poc`, pass the string-prefix
check, then `File.write` would follow the symlink at I/O time and hit
the host path. Under bwrap the bind mounts narrow what's reachable;
under the **unsandboxed fallback** (`Glorbo.Sandbox.Unsandboxed`,
macOS, `--no-sandbox`) it lands directly on the host FS.

Fix: `resolve_tool_path` now consults
`AgentWritableFile.any_symlink_in_path?/1` after the lexical check
and raises an `ArgumentError` (`"tool path crosses a symlinked
component"`) if any ancestor segment is a symlink. The wrapping
`Tools.execute/3` `rescue` clause surfaces this as
`{"error" => "path_crosses_symlink"}` alongside the existing
`path_escapes_workspace`. Regression test exercises 3 tool calls
(write, edit, read) with a planted symlink + 2 negative cases (normal
write succeeds, `..`-escape still produces `path_escapes_workspace`).
Identified by the codex deep-dive sweep.

### Security — bwrap auth-binds validate host+sandbox paths before argv assembly (HIGH, codex-F1)

`Glorbo.Sandbox.Bwrap` previously spliced provider-config `auth_binds`
`host` and `sandbox` paths into bwrap argv with no validation — only
`mode` was checked in the loader. A config-influencer (untrusted
provider-registry contribution, malicious copy-paste from a 3rd-party
`providers.toml`) could mount `host="/"` at `sandbox="/workspace/.creds"`,
exfiltrating the entire host FS through the sandbox surface; or
`host` at `sandbox="/etc"`/`/workspace`/`/inbox`, shadowing critical
mount points inside the namespace. Validation now runs before argv
assembly and refuses:

- **host**: not absolute (must be tilde-expanded); contains `..`;
  contains any control byte (`\x00`-`\x1F`, `\x7F`); EXACTLY matches
  a critical host root (`/`, `/etc`, `/root`, `/proc`, `/sys`,
  `/boot`, `/home`, `/lib`, `/lib64`, `/dev`).
- **sandbox**: not absolute; contains `..`; contains any control
  byte; canonically matches a critical mount point that a bind
  would shadow (`/workspace`, `/inbox`, `/outbox`, `/usr`, `/etc`,
  `/proc`, `/sys`, `/dev`, `/run`, `/bin`, `/sbin`, `/lib`,
  `/lib64`, `/var`, `/root`, `/home`, `/boot`, `/tmp`, `/`). The
  canonical check normalises trailing `/` and `/.` so
  `/workspace`, `/workspace/`, and `/workspace/.` are all caught.

Mirrors the existing `approved_path_flags` validation pattern. Legit
non-`/workspace/` bind targets (e.g. the `/tmp/glorbo-cli-<name>`
slot used by `Glorbo.Agent.Dispatch` to keep agents from enumerating
the host binary's parent dir per T5) keep working. Regression test
pins 22 unsafe shapes shut (B5d) plus positive cases (B5e). Identified
by the codex deep-dive sweep.

### Security — agent config form validates provider/model/reports_to/autonomy (HIGH, gemini-F2)

`GlorboWeb.AgentLive.do_config_save/2` used to write `provider`,
`model`, `reports_to`, and `autonomy` from the director form into
`AGENT.md` verbatim — only `network` was sanitised, and a comment
explicitly noted the form values were client-controlled. Combined with
the dispatcher's `{model}` substitution into `reply_dir` /
`reply_filename_template` (gemini-F3 — `prepare_reply_dir/2` calls
`File.rm!` on the target before writing), a malicious
`model = "../../../AGENT.md"` was an arbitrary-file-delete + write
primitive. Now each field is gated before persistence:

- **`provider`** — strict identifier (`[A-Za-z][A-Za-z0-9._-]{0,63}`).
- **`model`** — model identifier with provider-namespace slashes
  allowed (`lmstudio/qwen/...`), but `..`, `//`, and leading/trailing
  `/` refused; alphanum + `._/-` only; max 128 chars.
- **`reports_to`** — slug shape (`[a-z0-9][a-z0-9_-]{0,63}`).
- **`autonomy`** — enum (`manual` / `supervised` / `auto`).

On any failure the save aborts with a per-field flash message and
nothing reaches disk. Regression tests pin 8 path-traversal model
strings, 3 invalid provider/reports_to/autonomy shapes, AND the
legit slashed-model case (`lmstudio/qwen/qwen3.6-35b-a3b` still
saves). Identified by the gemini deep-dive sweep.

### Security — `refuse_contract_write` canonicalises before name check (CRITICAL, gemini-F1)

`Glorbo.Actions.Agents.refuse_contract_write/1` compared
`Path.basename(rel)` to `@contract_files` (`AGENT.md` / `stdout.log`).
That check could be bypassed with a trailing `/.`:

```elixir
Path.basename("workspace/../AGENT.md/.")  # => "."  (gate passes)
Path.expand("workspace/../AGENT.md/.")    # => ".../AGENT.md"  (write hits)
```

while `Path.expand/1` resolves to the real `AGENT.md` path the write
would hit. Reachable by anyone holding director-form access (or,
transitively, by any auth/CSRF/XSS path to that form). Overwriting
`AGENT.md` is a privilege-escalation primitive in a system whose trust
model rests on the contract file (it carries the agent's provider,
permissions, sandbox config). Fix: compare
`Path.basename(Path.expand(rel))` so the trailing `/.` (and any `..`)
are normalised before the gate check. Regression test pins 5 bypass
forms shut. Identified by the gemini deep-dive sweep + empirical
verification.

### Security — `doctor --install-deps` no longer trusts `$PATH` (C-043)

`Glorbo.Doctor.Fixer.run_install/3` previously did `System.cmd("sudo", …)` and
let Erlang resolve `sudo` (and the package manager) via the operator's
`$PATH`. An attacker with PATH-write but no root could plant a malicious
`sudo` and steal the password prompt the feature tells operators to
expect. `sudo` and the allowlisted package manager (`dnf`/`apt`/`pacman`)
are now resolved against a fixed list of trusted system bin dirs
(`/usr/bin`, `/usr/sbin`, `/bin`, `/sbin`) and refused with
`:install_no_trusted_path` if not found — defense-in-depth on top of
sudoers `secure_path`.

## [0.23.1] — 2026-05-23

### Fixed — CI test flakes blocking the v0.23.0 publish workflow

- **`Glorbo.Network.Proxy.stop/1`** now swallows ANY `:exit` reason, not
  only `:noproc`. Under low parallelism (`max_cases: 8` on the CI runner)
  + 10 concurrent CONNECT load, the proxy GenServer could terminate with
  a non-`:normal` reason during the teardown window between
  `Process.alive?` and `GenServer.stop` in the test `on_exit`; the
  re-exit escaped the narrow catch and failed `proxy_test.exs:233`.
  `stop/1`'s contract is just "ensure the process is gone" — any exit
  satisfies it.
- **`dispatcher_test.exs` D6 stdout-fallback test** dropped its
  `refute log =~ "reply_exists?=false"` assertion. The behavioural
  `assert {:ok, %{reply: _}} = …` is the load-bearing invariant for the
  D6 fix; the log-refute bled under `async: true` parallelism (other
  concurrent dispatcher tests legitimately emit the same warning and
  ExUnit.CaptureLog's group-leader isolation didn't hold), causing
  intermittent CI failures.

### Notes

- **v0.23.0 was tagged but publish-skipped.** A premature manual
  `gh release create v0.23.0` collided with the repo's immutable-
  releases policy: the tag stayed permanently bound to the deleted
  release, so the `Publish signed release` workflow's create-then-
  finalize call hit `HTTP 422: tag_name was used by an immutable
  release` and left the signed assets stuck in a draft. v0.23.1
  carries the same shipped content (P2 hardening + decimal CVE,
  see below) plus the two CI flake fixes above. Same supersession
  pattern as v0.12.3 → v0.12.5.

## [0.23.0] — 2026-05-22 (tagged, publish-skipped — superseded by v0.23.1)

### Security — dependency: bump `decimal` past GHSA-rhv4-8758-jx7v

- `decimal` 2.4.1 → 3.1.0 via an explicit `override: true` (it's a transitive
  dep of `ecto`, which pins `~> 2.0`, and `ecto_sqlite3`, which pins
  `~> 1.6 or ~> 2.0` — neither admits `~> 3.0`, and no decimal-3.0-aware
  upstream release exists yet). Clears the OpenSSF Scorecard "Vulnerabilities"
  high alert for the `Decimal.new` unbounded-exponent DoS
  (GHSA-rhv4-8758-jx7v; EEF advisory alias EEF-CVE-2026-32686). Glorbo never
  calls `Decimal`/uses `:decimal` Ecto types, so the vulnerable path was
  unreachable in practice — but the bump is clean (full suite green against
  3.1.0) and removes the flagged version.

### Security — P2 hardening wave: DoS caps, audit/budget integrity, scheduler/wake (codex)

A batch of 19 medium findings from the codex sweep:

- **Unbounded-read DoS caps** (C-032/C-034/C-101/C-102/C-107/C-113/B-021/C-089) —
  host-side reads of agent-controlled files now go through size-bounded readers
  (`AgentWritableFile.read_bounded` / `File.stat` gates / streaming-abort for
  `web_fetch`): native usage.json, the web_fetch HTTP client, the chat drawer +
  channel tail (256 KiB tail-read + segment cap), the overview audit/month +
  per-task reads, project icons (64 KiB), and the agent-detail io previews.
- **Audit & budget integrity** (C-033/C-087/C-053/C-054/D-187/C-099) — tool-audit
  events capped per dispatch (+ truncation marker, bounded strings); retries
  re-check budget before re-entry; budget reindex reads the nested `detail` audit
  shape and accepts underscore slugs (was silently zeroing/dropping spend);
  `BudgetTracker` uses `append_for/2` so budget events actually persist; retiring
  an agent now stops its running supervisor child + unregisters its heartbeat.
- **Scheduler/wake integrity** (C-046/C-047/C-078/C-105/C-115/D-185) — the
  scheduler re-parses the live `schedule:` on fire (no stale-cron firing) and only
  arms `kind: task/v1` files (not `*.comments.md`); heartbeat-picked inbox messages
  are drained; oversized (>5 MiB) inbox files are skipped instead of dispatched as
  an empty prompt; a queued director-approval task survives an at-cap wake.

## [0.22.0] — 2026-05-22

Security-hardening release. Resolves ~40 findings from a codex security sweep
(plus dependency CVE bumps and OpenSSF supply-chain tooling). See the per-area
entries below.

### Security — `glorbo status` no longer prints the token, history won't commit provider secrets, reassign flood capped (codex B-027/C-063/C-067)

- **B-027:** `glorbo status` inlined the dashboard token (`?token=…`) in both `--json`
  and the table — operational metadata that lands in monitoring/CI/supervisor logs.
  Status now prints the bare base URL plus a non-secret pointer; the token is gone.
- **C-063:** the HomeHistory git repo used a denylist `.gitignore` that excluded only
  `config.md`, so a user-controlled `providers.toml` carrying `[env]` API tokens got
  committed. `providers.toml` is now git-ignored by the history layer.
- **C-067:** an agent reply's `ACTIONS` block applied *every* `reassign_to` directive
  (each = a frontmatter rewrite + handoff-chain append + audit event), so one reply
  could flood the audit log. Reassign is now capped to one effective reassign per reply
  (last-writer-wins).

### Security — CLI/runtime hardening: terminal-escape, MCP DoS, poison inbox, retry spin, dep-gate (codex C-117/C-079/C-076/C-129/C-130)

- **C-117:** `glorbo logs` printed agent `stdout.log` verbatim, allowing terminal-escape
  injection into the operator's terminal. Output now passes through a new linear
  `Glorbo.Terminal.Sanitizer` (strips C0/C1 + CSI/OSC; non-backtracking to avoid the
  C-091 ReDoS cliff); `--raw` opts back in for trusted debugging.
- **C-079:** the MCP `query_audit` tool didn't bound `month`/`year`; an out-of-range
  month materialized an unbounded month stream (unauthenticated DoS). Now validated +
  capped.
- **C-076:** a poison inbox message whose derived `task_id` failed validation made the
  agent crash-loop (raise before drain). The Agent.Server now pre-validates and
  quarantines the undispatchable message to `history/rejections/` instead of looping.
- **C-129:** a throttled inbox dispatch no longer re-dispatches the identical file in a
  tight spin; it re-arms the wake for the next free slot.
- **C-130:** the scheduler captures `depends_on` authoritatively at arm time and gates on
  the union of on-disk + registered deps, so blanking/coercing `depends_on` on a mutable
  task file can no longer fail-open past the dependency gate (emits a tamper audit).

### Security — path-approval subset check, task-edit audit, token URL strip (codex B-014/C-094/C-120)

- **B-014:** the dashboard path-approval handler passed the client-supplied `paths`
  straight to `PathRequestGate.approve` without comparing them to the sentinel's
  *original* requested paths — a tampered LiveView payload could approve arbitrary
  host paths (confused deputy). The gate now re-reads the pending sentinel and
  enforces that granted paths are a subset (write→read downgrade only) of what was
  requested; new paths / read→write escalation are refused.
- **C-094:** dashboard task **edits** (TaskLive + KanbanLive `save_task`) wrote
  frontmatter with no audit entry (only deletes were audited), bypassing the
  append-only audit log. Edits now emit a `task.edit` audit event (actor + changed
  keys).
- **C-120:** after the session cookie is set, the `DashboardToken` plug now
  302-redirects to strip the `?token=` from the URL and sets `Referrer-Policy:
  no-referrer`, narrowing the token's exposure in history/Referer. (Full one-time
  rotation is GEP-0049.)

### Security — stado provider state relocated into the per-agent sandbox (codex A-001/B-006/B-023/B-026/B-024)

The bundled stado provider mounted the host's XDG data/state dirs
(`~/.local/share/stado`, `~/.local/state/stado`) as **read-write** binds shared
across *all* companies, and ran `stado stats` on the host against that shared
state. A sandboxed agent could read/modify another company's stado sessions and
git worktrees (cross-company isolation breach), and the usage walker executed the
provider outside bwrap. Now: stado's `XDG_DATA_HOME`/`XDG_STATE_HOME` point into
the agent-private workspace (the rw host binds are dropped; only `~/.config/stado`
stays RO-bound for model selection), so sessions/worktrees are per-agent and never
touch shared host state. The `stado stats` usage call is handed that same
per-agent XDG env (no host secrets reachable) and bounded by a hard timeout. ACP
session-id files are now lstat-guarded against symlink swaps (B-024). Note:
existing host-side stado sessions are not migrated (pre-1.0 atomic cut).

### Security — dependency CVE bumps + supply-chain hardening (OpenSSF)

- Bumped vulnerable deps within existing constraints: **Phoenix 1.8.5→1.8.7**
  (NDJSON long-poll memory DoS, GHSA-628h-q48j-jr6q), **Bandit 1.10.4→1.11.1**
  (chunked-encoding DoS, WebSocket OOM, request smuggling — 7 advisories),
  **Plug 1.19.1→1.19.2** (multipart header DoS, GHSA-468c-vq7p-gh64),
  **decimal 2.3.0→2.4.1**. The remaining decimal advisory (GHSA-rhv4-8758-jx7v,
  MODERATE) is first patched in 3.0.0, which the ecto-family constraint
  (`~> 2.0`) blocks; it is ignored in CI with rationale (not reachable —
  Glorbo parses no untrusted decimals).
- Added CI security gates: **sobelow** (Phoenix SAST, `.sobelow-conf` with a
  documented architecture-aware ignore list), **mix_audit** (hex advisory scan).
- Added **OpenSSF Scorecard** workflow + README badge, **`.github/dependabot.yml`**
  (weekly `mix` + `github-actions` updates), and **SLSA build-provenance
  attestation** (`actions/attest-build-provenance`) on released binaries +
  `SHA256SUMS`.

### Security — revise-feedback path, severity auto-flip, MCP actor provenance (codex B-008/C-062/C-077)

- **B-008:** `Reviews.write_revise_feedback/5` joined the task's `assigned_to` value
  (attacker-controllable) into the inbox path with a symlink-following `File.dir?`.
  It now validates the assignee + task_id slugs and refuses symlinked ancestors.
- **C-062:** a string `peer_review_required: "true"` defeated the severity auto-flip
  (major/critical tasks silently skipped review). The flip now treats only
  boolean/`"false"` as opt-out, and the parser coerces the string form properly.
- **C-077:** an overlong MCP `client_name` made `safe_actor_tag/1` collapse to the
  trusted `"director"` provenance; it now never collapses an untrusted/overlong actor
  to `director` (truncates with an `mcp:` prefix or marks `mcp:unknown`).

### Security — refuse agent-planted symlinks across host-side filesystem walks (codex B-007/C-041/B-016/B-019/B-010/C-037/C-098/C-070/D-146/C-040/C-058)

Several host-side (unsandboxed) code paths walked or read agent-writable trees
without refusing symlinked path components or validating slug/path inputs, so a
sandboxed agent could plant a symlink (or a traversal value) to leak/clobber files
in another company or on the host:
- Shell Tasks view, brain-dump→task conversion, the opt-in task migrator, paperclip
  import, and the agent-retire walk now refuse symlinked ancestors (via
  `AgentWritableFile.any_symlink_in_path?` / `:file.read_link_info`), and the retire
  walk gained a recursion-depth cap.
- Benchmark fetch/score validate the `run_id` (no traversal) and route reads through
  the lstat- + size-bounded `AgentWritableFile.read`.
- Kanban's assignee→provider lookup validates the `assigned_to` slug before joining it
  into an `AGENT.md` path (was a cross-company existence/provider probe).

### Security — bound ACP streams + stdout tee against provider-driven DoS (codex C-044/C-048/C-049/C-103)

An untrusted/looping provider could exhaust host resources through the dispatch
path: unbounded ACP frame auditing (one fsynced audit line per frame, untruncated
peer strings → audit-log/disk flood), an ACP stream with only a per-chunk-resetting
read timeout + unbounded in-memory reply accumulation, an unbounded line buffer in
the ACP framer, and a stdout tee that appended every chunk to `stdout.log` with no
cap. Now: ACP audited frames are capped per dispatch (5 000) with per-frame strings
truncated (256 B); the ACP client enforces an absolute conversation deadline and a
running reply-byte cap that aborts mid-stream; the framer caps line size (16 MiB);
and the stdout tee is capped at 16 MiB/dispatch with a truncation marker. `drain_port`
now uses a single absolute deadline instead of resetting per chunk.

### Security — secret-file permission hardening (codex B-013/C-074/C-075)

Three places could expose secret-bearing files (`config.md` carries
`secret_key_base`/`dashboard_token`/`erl_cookie`; backups archive them):
- `glorbo fmt --write` rewrote `config.md` through the generic FileSpec formatter,
  which created its temp with umask perms (0644) and renamed over the 0600 file —
  relaxing the secrets file to world-readable. The formatter now preserves the
  original file's mode.
- The backup archive temp was created 0644 and only chmodded after secret-bearing
  content was written; it is now pre-created 0600 with `O_EXCL` (also defeating a
  pre-planted-symlink swap).
- `glorbo doctor`'s private-file check used `perms > 0o600`, missing group/other-
  readable low modes (e.g. 0o044); it now flags any file with group/other bits set.

### Security — Homebrew-tap publish workflow no longer shell-injectable via tag name (codex B-009/C-035)

The `publish-homebrew-tap` CI job interpolated `${{ steps.version.outputs.version }}`
(derived from the pushed git tag `GITHUB_REF_NAME`) raw and unquoted into `run:`
shell, so a tag like `v1.2.3||id` (which matches the `v*.*.*` trigger) executed
attacker commands on the runner holding `HOMEBREW_TAP_TOKEN`. The job now validates
the version against a strict semver regex (failing the build otherwise) and passes it
through a quoted `env:` var instead of template-interpolating it into the shell.

### Security — task company-boundary check now collapses `../` traversal (codex D-186/E-201)

`TaskDefinition.parse_file/2`'s company-containment check was a lexical
`String.starts_with?` on the raw path, so a path like
`<base>/companies/<co>/projects/../../other/...` still started with the company
prefix yet resolved into a sibling company (or anywhere on the host). The check
now `Path.expand`s the path first, collapsing `.`/`..` before testing
containment, so traversal segments can no longer escape the company tree.
(Symlinked path components were already refused by `AgentWritableFile.read/1`.)

### Security — reserve `dm-director--` channel writes to the DM owner (codex B-020, write vector)

Director DMs are stored as regular channels (`channels/dm-director--<agent>.md`),
and a chat write maps to the permission `{"chat","write",<channel>}`, so a broad
`chat:write:*` grant let any agent append to **another** agent's director DM —
and, via the mention router, notify/wake that victim. The Router now reserves the
`dm-director--` prefix: an agent may only write its own `dm-director--<sender>`
thread; writes to any other agent's DM are refused (`:reserved_dm_channel`)
regardless of the wildcard. (The read vector — `chat:read:*` RO-mounts the whole
`channels/` dir, exposing all DMs in-sandbox — is a channel-layout issue tracked
separately for a GEP.)

### Security — budget enforcement wired into auto-booted agents (codex C-108)

Auto-booted agents (the heartbeat- and inbox-driven production wake path)
were started with no `:dispatch_opts`, so `Dispatch.execute` fell back to the
no-op `budget_tracker_fun` and `record_usage_fun` defaults: the per-agent
budget gate never fired AND the usage ledger was never written. Because the
company cap sums that same ledger, the SEC-05 pre-dispatch hard stop read
zero spend and never tripped — budget enforcement (a crown-jewel "no runaway
cost" guarantee) was effectively dead for every auto-booted agent.
`AgentBoot` now threads production `dispatch_opts` (the real per-company
`BudgetTracker` check + usage recorder, plus the resolved `base`) into each
agent's `Agent.Server`, so budget gating and usage recording are live on the
wake path. Threading `base` also fixes dispatch reading the wrong filesystem
root under a custom `GLORBO_HOME` (codex C-114).

### Security — auto_dispatch now requires `agents:message:<assignee>` (codex B-025)

An agent filing an outbox task with `auto_dispatch: true` caused the Router
to write directly into `agents/<assignee>/inbox` — the same privileged action
a direct `to: agent:<assignee>` message performs — but the only authorization
checked was `tasks:create`/`projects:write` for filing the task. Since
`assigned_to` is attacker-controllable frontmatter, a low-privileged agent
could wake **any** agent and make it process attacker-authored task content
(consuming its budget, acting with its privileges). `maybe_auto_dispatch` now
gates the inbox write on the same `agents:message:<assignee>` permission a
direct message requires, emitting a `task.auto_dispatch_denied` audit on
refusal. Legitimate spawn-and-dispatch flows (where the spawner holds
messaging permission) are unaffected.

## [0.21.1] — 2026-05-22

### Fixed — dashboard re-render thrash / click-drop under `:agent_status` churn

`CompanyLive` and `AgentLive` re-rendered synchronously on **every**
`:agent_status` PubSub flip. A misconfigured or looping agent flips
status several times/sec; each flip rebuilt the agent roster (CompanyLive)
or the full agent-detail panel (AgentLive) and patched the live DOM, which
could replace a toolbar/modal node mid-click and drop the click, and
thrash the detail panel's layout.

Both views now **coalesce** `:agent_status` bursts through the existing
`schedule_coalesced_reload` helper (250 ms window) — the same mechanism
already used for the `:file_event` storm — collapsing a burst to one
light reload per window. `CompanyLive` also defers the reload while a
modal/editor is open (re-arming on close), matching the `:file_event`
behaviour. The "working on …" roster line is now backed by a **durable
per-slug overlay** (`working_on_by_slug`) re-applied by *both* the
`:file_event` and `:agent_status` reload paths, so a filesystem-driven
reload no longer erases the working-on line of a busy agent until its
next status flip. `schedule_coalesced_reload/4` + `clear_reload_pending/2`
gained a `latch_key` so the two coalesced streams don't share a pending
flag. (TODO P1: modal click-drop + agent-detail thrash.)

## [0.21.0] — 2026-05-21

### Fixed — `network: proxy` dispatch hard-failed with `:invalid_proxy_url`

`Glorbo.Sandbox.Bwrap`'s proxy-URL parser rejected any URL carrying
`userinfo`, but GEP-23 Phase 5 embeds the per-dispatch auth token there
(`http://<token>@127.0.0.1:<port>`) so the sandboxed CLI's CONNECT can
send `Proxy-Authorization`. Every `network: proxy` dispatch therefore
failed at sandbox start with `{:invalid_proxy_url, …}`. The parser now
accepts userinfo and **preserves the token** in the canonical
`HTTPS_PROXY` value (host normalised to `127.0.0.1`; only the bare port
feeds the network-namespace egress rule). Found via full e2e UAT.

### Fixed — dashboard unusable while an agent works (re-render thrash)

An agent actively working writes many files per second; `CompanyLive`
ran a full `load_company_data` reload + whole-page re-render on **every**
inotify `:file_event`, so the document height oscillated several times a
second (overview + agent pages) and the constant DOM patching wiped the
new-project modal's slug input and ate its create / cancel / × clicks —
the modal was unusable. File-event-driven reloads now coalesce through
`GlorboWeb.LiveHelpers.schedule_coalesced_reload/3` (one reload per
~250 ms window), and a reload is deferred while a modal/editor is open so
in-flight form inputs aren't clobbered. Verified end-to-end under
file-event churn: the new-project modal opens, the slug sticks, create
succeeds + closes, and × / cancel close — all reliably. (A misconfigured
agent that flips status several times a second can still occasionally
drop a click; tracked as a follow-up — see `docs/todo.md`.)

### Changed — dashboard token is read once, then rides a session cookie

The `DashboardToken` plug now persists a valid `?token=` to the (signed)
session as a `sha256` fingerprint, and accepts that session cookie on
subsequent requests. Operators open the printed `…/?token=<token>` URL
once and then navigate, refresh, and deep-link normally — the token no
longer has to appear on every request. This also fixes the advertised
entry URL: `GET /?token=…` redirects to `/companies`, and previously the
redirect dropped the token and 401'd; the cookie set on the redirect now
carries the auth through. Rotating `dashboard_token:` invalidates every
outstanding cookie (the fingerprint stops matching), and the raw token
is never stored in the cookie. MCP (`:api` pipeline, no session) stays
stateless — the `Authorization: Bearer` header accompanies each request.

### Fixed — GEP-48 broke the dashboard under `mix phx.server` (dev)

The mandatory-`dashboard_token` work wired the token into application
env only inside `config/runtime.exs`'s `if config_env() == :prod` block.
Releases (`glorbo serve` / the burrito binary) run that block and work,
but `mix phx.server` (dev — and the documented browser-UAT command)
skips it, leaving `Application.get_env(:glorbo, :dashboard_token)` at
`nil`. The `DashboardToken` plug then refused **every** request with a
500, including requests carrying the correct token from `config.md` —
the dev dashboard and the entire UAT path were unusable.

`config/runtime.exs` now also loads the token from `config.md` for
`config_env() == :dev` (`:test` keeps its hardcoded `"test-token"`).
Surfaced by full e2e UAT against a fresh `mix phx.server`; unit tests
missed it because they set `:dashboard_token` directly in app env.

### Fixed — GEP-47 v2: `auto_dispatch` honours the dependency gate

The F10 `auto_dispatch` path bypassed the `depends_on` gate that
`TaskScheduler.fire` enforces: an agent filing a task with
`auto_dispatch: true` + a valid `assigned_to` + an unmet `depends_on`
got dispatched immediately, ignoring its dependencies.
`Glorbo.Company.Router.maybe_auto_dispatch/5` now consults
`Glorbo.Task.DependencyGate.ready?/2` and emits `task.blocked_on_deps`
/ `task.blocked_on_failed_dep` (same classification + audit actions as
the scheduler) instead of writing the inbox event when deps are unmet.

The on-disk snapshot builder was extracted from
`TaskScheduler.build_task_snapshot/1` into `Glorbo.Task.Snapshot.build/2`
so the scheduler and the Router share one snapshot shape;
`DependencyGate` stays a pure rule module. See GEP-47 §Implementation
status (the Kanban "assigned_to changed" notification path remains
ungated pending the dispatch-chokepoint design decision).

### Security

- Bind epmd to `127.0.0.1` only — previously listened on all interfaces (`0.0.0.0:4369`).
- Dashboard and MCP auth token is now mandatory — auto-generated on first boot (or on upgrade from `dashboard_token: null`), written to `config.md` at mode 0600. `DashboardToken` plug no longer passes through unauthenticated requests.
- `glorbo serve`, `glorbo up`, and `glorbo status` now print the full token URL (`http://127.0.0.1:4000/?token=<token>`) for browser and MCP client configuration.

### Fixed — D8: F6 persistence rejects non-UUID `sessionId`

The F6 session-resume implementation persisted whatever the peer
returned in `acp_result.session_id` to
`<workspace>/.glorbo/sessions/<provider>__<task_id>.txt`, then sent
the same value back as `resumeSession` on the next dispatch. Stado
v0.46.x's ACP server validates `resumeSession` strictly: the param
must be a canonical UUID; named-session lookup is operator-only via
the `--resume` CLI flag. When stado returned a description / project
slug instead of a UUID (or when older Glorbo persisted such a value),
every subsequent dispatch for that task wedged with `code: -32602,
"resumeSession: invalid session id (must be a canonical UUID)"`.
Operators had to manually `rm` the bad session file to recover.

Both sides of the persistence round-trip now validate UUID shape via
a regex (8-4-4-4-12 hex):

- **Write** (`write_acp_session_id/2`): refuses non-UUID values, logs
  a warning, leaves the file untouched.
- **Read** (`read_acp_session_id/1`): treats non-UUID content as
  "no prior session", and best-effort `rm`s the file so the next
  dispatch starts clean and the operator's directory listing
  reflects what's actually usable.

Two new dispatcher tests cover both paths: peer returns non-UUID →
file not created; pre-existing non-UUID file (from older Glorbo) →
read returns nil + file dropped + fresh UUID from current dispatch
replaces it. Existing F6 tests had their fake `"uuid-stado-1"` /
`"acp-bench-7"` / `"s-1"` / `"s-test"` placeholders rewritten to
canonical UUID shape so the new validator's warning doesn't clutter
CI logs.

### Fixed — D3: stado provider mounts XDG_STATE_HOME for worktree creation

The default stado provider config bound `~/.config/stado` (ro) and
`~/.local/share/stado` (rw) but **not** `~/.local/state/stado`.
Stado follows the XDG spec and writes per-session git worktrees
under `XDG_STATE_HOME/stado/...`, which defaults to
`~/.local/state/stado`. With that path unmounted, stado's
`OpenSession` / `CreateSession` calls in `MkdirAllUnderUserConfig`
silently fail and the dispatched agent ends up with no executor
and no tools — a confusing "stado runs but nothing happens"
symptom in field testing.

`priv/providers/stado.toml` now declares the third auth_bind
(`~/.local/state/stado` rw, sandboxed at `/workspace/.local/state/
stado`) so all three XDG dirs are present inside the bwrap mount
namespace. The `builtin_providers_test` assertion was tightened
to pin the canonical share + state + config triple.

If you've been using a `~/.glorbo/providers/stado.toml` override,
the new default is additive — your override still wins per the
GEP-8 override pattern, but you'll want to add the same
`~/.local/state/stado` entry to your override so worktree creation
works.

### Fixed — D6: stdout fallback no longer triggers a misleading `reply_exists?=false` warning

When a CLI provider writes its reply to stdout instead of the
canonical `$GLORBO_REPLY_PATH` file, `Dispatcher.invoke/3`'s
`maybe_stdout_to_reply/4` materialises the reply file from the
captured stdout and the dispatch succeeds — but the diagnostic
log emitted just before fallback was reading
`reply_exists?` from the pre-fallback filesystem state, so every
stdout-fallback success surfaced as a "cli foo exit=0
reply_exists?=false stdout=…" warning that looked like a
failure.

Reordered the dispatch with-chain so `maybe_stdout_to_reply/4`
runs before `maybe_log_run_output/4`. The log now reads the
post-fallback `reply_exists?` value, so it only fires when there
is actually no reply (no file, no stdout) or the CLI exited
non-zero. New test `D6: stdout fallback success does not emit
reply_exists?=false warning` captures the Logger output and
asserts the warning is suppressed on the fallback success path.

### Added — F10: `auto_dispatch:` flag on agent-spawned tasks

Builds on the existing `outbox/tasks/<project>/<id>.md` mechanism
(agents file new tasks via the path-based outbox convention,
permission-checked + audited via `Glorbo.Company.Router`). When the
spawning agent sets `auto_dispatch: true` in the task frontmatter
and a valid `assigned_to:` is present, the Router writes a
synthetic inbox event for the assignee right after the task lands,
so spawned work picks up immediately instead of waiting for an
operator wake or a `schedule:` tick.

Use case: scanner agent finds an ambiguous SUID binary, spawns a
"second-opinion" task targeted at a reviewer agent — without
auto_dispatch the new task sat in `projects/<p>/tasks/` until the
operator noticed.

Skipped when:
- `auto_dispatch` is not literally `true` (booleans only — string
  `"true"` falls through, matching the strict-typing convention
  of `peer_review_required`).
- The task wants director approval (`requires_approval: director`
  or `status: pending-approval` / `pending_approval`). The
  approval gate fires first; auto-dispatch is the operator's call
  after granting.
- `assigned_to` is empty or not a valid slug.

Audit: emits `task.auto_dispatched` with the actor set to
`agent:<sender>` and detail naming the assignee + inbox message
filename.

This intentionally piggybacks on the existing path-based routing
rather than introducing a parallel flat-outbox + frontmatter
discriminator (`glorbo_request: create_task`) — the path-based
mechanism already handles the permission check, transactional
move, and audit emission, so threading auto_dispatch through it
adds the missing piece without doubling the security surface.

### Fixed — D5: auto-complete tasks on clean dispatch exit

Tasks under `companies/<co>/projects/` are mounted ro inside the
bwrap sandbox (GEP-5 / GEP-2) so an agent that finishes its work
cannot rewrite its own task file. Without intervention every task
stayed at its authored status (typically `pending`) on exit 0 and
operators had to `sed` the status field after every dispatch.

`Glorbo.Agent.Dispatch.execute/3` now runs `maybe_auto_mark_task_
done/2` after the success path's audit emission. On `exit_status:
0` and a non-recurring task, status `todo` / `in-progress` /
`pending` / `approved` are rewritten to `done` via
`FrontmatterWriter.update_keys/3` (atomic; preserves comments and
unknown keys). Recurring tasks (`schedule:` set), director-gated
states (`pending-approval`), terminal states (`done` / `denied` /
`cancelled`), and non-zero exits all skip the rewrite. Best-
effort: a write failure logs a warning but never breaks the
dispatch result.

5 new dispatch tests cover the transition matrix.

### Added — GEP-47 v1: `depends_on` for tasks

Explicit blocking dependencies between tasks within a company, plus
DFS cycle detection. Localforge bridge #1 (the depends_on half of
the kanban+priority bridge — numeric priority queue is GEP-49 next).

`task/v1` schema gains:

- `depends_on: [<task_id>, ...]` — optional. When non-empty, the
  scheduler does not dispatch the task until every listed dep
  reaches a *done-terminal* state (status `done` and, if
  `peer_review_required`, peer-review verdict `approve`). Bare
  `task_id` strings; GEP-13 D1 makes those unique within a company
  so no path prefix needed.
- `cancelled` status enum value + `cancelled_reason:` optional
  field — distinct from `denied` (which has GEP-19 director-
  approval semantics). Reserved for failure-propagation when v2
  lands the file-rewrite walker.

New module `Glorbo.Task.DependencyGate` is the single classifier:
`ready?/2` returns `:ok | {:blocked, [unmet]} | {:propagate_failure,
dep_id, reason}` for any `(depends_on, snapshot)` pair, plus
`cycle_detect/1` for DFS three-colour cycle finding. Pure module —
no IO — so every cell of the D3 terminal-state matrix and every
cycle topology is unit-testable without a fixture filesystem (23
new tests).

`Glorbo.Company.TaskScheduler.maybe_fire/4` consults
`DependencyGate.ready?/2` before writing the inbox event:

- **deps all done** → existing dispatch path runs
- **deps non-terminal** → emit `task.blocked_on_deps` audit, skip
  inbox write, re-arm the timer
- **deps failure-terminal** → emit `task.blocked_on_failed_dep`
  audit (v1 stand-in for the v2 propagation walker), skip, re-arm

The 60s rescan also runs `cycle_detect/1` over the full company
task graph; new cycles emit `task.cycle_detected`. Deduped via
state so a stable cyclic graph doesn't flood the audit log.

**v1 boundaries** (queued for the v2 follow-up commit):

- Failure-propagation walker that rewrites `status: cancelled` into
  dependent files (D4) — v1 surfaces the situation as audit instead.
- Router append-only enforcement of `depends_on` (D6).
- Full audit vocabulary (`task.failure_propagated`, `task.unblocked`).
- SQLite `task_dependencies` index (D9) — on-demand snapshot
  works for typical task counts.
- Director-wake path gate — only `TaskScheduler.fire` is gated.

Full spec + decision log: `docs/geps/0047-task-depends-on.md`. See
§Implementation status for the v1/v2 split.

### Added — `/activity` cross-company live activity feed

Localforge bridge #3. New top-level LiveView at `/activity`
subscribes to a single fan-in PubSub topic (`audit:all`) and
renders the most-recent N audit appends from every company in one
live stream. Each row carries a company tag that links back to the
per-company audit page; filters cover company (dropdown), actor,
action, and free-text against actor + action + target + detail.

`Glorbo.Company.AuditLog.broadcast_append/2` now mirrors every
per-company `{:audit_append, record}` to the new global topic with
the company slug attached: `{:audit_append, company, record}`.
The existing per-company `company:<co>:audit` topic is unchanged so
`AuditLive` keeps working without modification.

Sidebar nav picks up an "Activity" entry under the global section
alongside Providers / Benchmarks / Costs.

### Fixed — F5: auto-cancel `kind=choice` ACP updates instead of hanging

Same shape as F7 — stado v0.46.0 emits `session/update {kind:
"choice", requestId: <uuid>, options: [...]}` and waits for
`session/choice_response`. Glorbo previously fell through to the
generic `absorb_update` (counted as ignored, no response sent) and
the agent hung until `phase_timeout_ms`. Now the client intercepts
both wrapped and unwrapped choice updates and sends `session/
choice_response {sessionId, requestId, cancelled: true}`. No
choice index is included; `cancelled: true` is the unambiguous
signal that no option was selected. Headless dispatch always
cancels — surfacing choices to a real operator UI is a future GEP.

### Added — F6: ACP `sessionId` persistence + resume across dispatches

stado v0.46.0 supports `session/new {"resumeSession": "<UUID>"}` so
the agent attaches to its prior worktree (with all reasoning and
tool-call history) instead of rebuilding context from scratch on
every dispatch. Glorbo previously discarded the returned `sessionId`
after each call.

`Glorbo.CLI.Dispatcher.Acp.Client.run/3` now accepts an optional
`:resume_session_id` opt and threads it into the `session/new`
params. `Glorbo.CLI.Dispatcher.invoke/3`'s ACP path persists the
returned `session_id` to `<workspace>/.glorbo/sessions/<provider>__
<task_id>.txt` after a successful dispatch, then reads it on the
next call so the resume happens automatically — no operator
configuration. Keyed by `(provider, task_id)` so two providers
exercising the same task each get their own session, and persistence
silently skips when `task_id` is empty (no sound key, no fake one
invented).

### Fixed — F7: auto-deny `kind=approval` ACP updates instead of hanging

stado v0.46.0 ships `stado_ui_approve`; any wasm plugin calling it
emits `session/update {kind: "approval", requestId: <uuid>, ...}`
and waits for `session/approval_response`. Glorbo previously
ignored the update — the turn hung until `phase_timeout_ms` fired
(10 minutes), silently stalling any dispatch that hit a plugin
with an approval gate.

`Glorbo.CLI.Dispatcher.Acp.Client` now intercepts `kind=approval`
updates (both wrapped `{"update": {...}}` and unwrapped top-level
shapes, camelCase keys) before `absorb_update` and immediately
sends `session/approval_response {sessionId, requestId, allow:
false, cancelled: false}`, then continues draining. This is the
correct behaviour for headless agent dispatch — interactive
approval (a real `allow: true` path) needs design work and lands
under a follow-up GEP if needed.

### Fixed — F9: synthesize reply from `kind=tool_summary` on tool-only ACP turns

stado v0.46.0 emits `session/update {kind: "tool_summary",
toolCount: N, lastTool: "...", lastError: bool}` at the end of any
turn that ran ≥1 tool call but produced 0 text deltas. Previously
the ACP client (`Glorbo.CLI.Dispatcher.Acp.Client`) ignored that
update kind, so the assembled reply was empty and downstream
consumers reported a 0-byte response on tool-only turns. Now the
client captures the latest `tool_summary` (both wrapped
`{"update": {...}}` and unwrapped top-level shapes, camelCase keys)
and synthesises `"[N tool call(s); last=<lastTool>; <ok|error>]"`
when no text chunks arrived. Text chunks still take precedence when
both arrive.

This supersedes F8 (file fallback) as the primary fix; F8 remains
as belt-and-suspenders for the rare case where the model wrote to
`$GLORBO_REPLY_PATH` but neither emitted text chunks nor a tool
summary.

### Added — GEP-46: parallelisation of company agents

Three independent concurrency knobs land together:

- **Per-agent `max_concurrency: N`** in `AGENT.md` (default `1`,
  capped at 32). Allows N>1 invocations of the same agent in flight
  when the inbox is busy. `Glorbo.Agent.Server` now tracks
  `in_flight: %{ref => invocation}` instead of single
  `current_task_*` fields; legacy fields are surfaced via the
  `:status` reply for backward compat.
- **Per-company `max_concurrent_dispatches: N`** in `company.md`
  (default unset / unbounded, capped at 256). Throttles the entire
  roster without per-AGENT.md edits.
- **Verified cross-company concurrency** is still free via
  `Glorbo.CompanySupervisor`'s per-company supervision trees.

New module `Glorbo.Company.DispatchSemaphore` (registered via the
per-company `:dispatch_semaphore` role). Acquire is a synchronous
`call/2` so the cap check is atomic. Release is `cast/2`. Holders
are monitored — a crashed `Agent.Server` automatically frees its
slot. `Glorbo.Agent.Dispatch.execute/3` acquires/releases at the
top of its with-pipeline; `:throttled` propagates back as
`{:throttled, :company_dispatch_cap}` so the agent can re-queue.

Wake-queue behaviour: `pending_wake` stays a single most-recent-
wins coalesce slot. On dispatch completion, `Agent.Server` drains
the inbox to fill remaining slots — but only when the COMPLETED
trigger was inbox-flavoured (`:inbox` / `:mention`); heartbeats
and director wakes don't cascade. This preserves today's exact
trigger semantics while unlocking burst-handling under N>1.

Per-invocation `agents/<slug>/stdout-<invocation_id>.log` (was a
shared `stdout.log`) so concurrent CLI invocations don't
interleave operator-visible output.

Schema additions go through GEP-25 machinery: `FileSpec.AgentMd`
gains `:max_concurrency` in `optional`/`canonical_key_order`,
`FileSpec.CompanyMd` gains `:max_concurrent_dispatches`,
`docs/file-formats/agent_v1.md` and `company_v1.md` regenerated.

Tests: 7 new `Glorbo.Company.DispatchSemaphoreTest` cases (cap
modes, release, crash recovery, multi-token holders); 3 new
`Glorbo.Agent.ServerTest` cases for `max_concurrency > 1` plus a
regression-guard for `N=1` reproducing today's behaviour;
supervisor child-count tests updated for the new
`Company.DispatchSemaphore` sibling.

Soft budget cap is documented (overshoot bound `≤ N ×
max_per_dispatch_cost`) per GEP-46 D6. Caps are application-layer
only per GEP-46 D7 — the kernel sandbox does not enforce
concurrency.

### Added — `glorbo version` / `--version` / `-V`

Three new CLI verbs that print the binary's `:vsn` from
`Application.get_key(:glorbo, :vsn)` (so the output stays in sync
with `mix.exs` automatically). Listed in the `glorbo help` output.

### Fixed — TODO B7: ACP port-close masks `MaxTurns` error response

When a peer (e.g. stado) writes a JSON-RPC error response (like
`"runtime: exceeded N turns"`) and immediately closes the port,
glorbo's ACP client could see the EOF / read-timeout before the
error frame was parsed and report
`{:provider_protocol_error, {:eof_in_phase, :session_prompt}}` or
`{:provider_timeout, :session_prompt}` instead of
`{:provider_returned_error, %{message: "runtime: exceeded N turns"}}`.
Added a non-blocking `final_drain/2` to `next_message/2`: on EOF
or read-timeout, polls the IO seam once with timeout 0 to harvest
any final bytes, parses them into the pending queue, and retries.
The error response is now surfaced correctly and the dispatcher
attributes the failure to the peer instead of swallowing it as
infrastructure flake.

### Fixed — field-testing TODO bugs B1–B6

- **B1 (`acp/client.ex`)** — `absorb_update/2` now accepts both
  `{"kind":"text","text":"…"}` and `{"kind":"agent_message_chunk",…}`
  shapes for `session/update` events. stado emits the former; before
  this fix every stado streaming chunk was silently dropped, leaving
  the agent with a 0-byte reply file.
- **B2 (`acp/client.ex`)** — default `:phase_timeout_ms` raised
  from `30_000` to `600_000` so multi-turn ACP tool-calling sessions
  (multi-step tool-calling turns can take 5–10 min) no longer hit a
  phase deadline mid-conversation. `@doc` updated to match the new
  default.
- **B3 (`sandbox/bwrap.ex`, `agent/dispatch.ex`)** —
  `cli_auth_bind_flags/1` honours the `mode` field declared in
  provider TOML `auth_binds`. `:rw` emits `--bind`, `:ro` (and the
  legacy 2-tuple) emits `--ro-bind`. Unblocks providers that need to
  write through an auth bind (e.g. stado session-sidecar git refs,
  claude-code `session-env/` creation).
- **B4 (`cli/dispatcher.ex`)** — `invoke/3`'s `:acp` branch now
  calls `build_env` and merges the result into
  `ctx.bwrap_opts.cli_env` (with host-workspace → `/workspace`
  rewriting), matching what the stdin path already does. Provider
  TOML `[env]` entries now reach the sandboxed ACP CLI; previously
  they were silently dropped, requiring wrapper-script workarounds
  to inject API keys.
- **B5 (`agent/dispatch.ex`, `sandbox/bwrap.ex`)** —
  `cli_auth_bind_flags/1` accepts a 4-tuple
  `{host, sandbox, mode, type}` and emits `--dir <sandbox>` before
  the bind when `type == :dir`, so non-standard sandbox paths like
  `/project` exist on the tmpfs root before bwrap tries to overlay
  them. Legacy 2/3-tuple shapes still work.
- **B6 (`file_spec/agent_md.ex`)** — `:allow_untracked_budget`
  added to the `optional` list of `frontmatter_schema/0`. The runtime
  parser, dispatch gate, and MCP tool already handled the key; only
  the validator was warning `unknown_key`. `docs/file-formats/agent_v1.md`
  regenerated to match.

### Changed — `mix glorbo.build_local` hardening

- Refuses to start if another `mix release` is running on the same
  checkout. Prevents Burrito's `.zig-cache/` + `payload.foilz.xz`
  race that produces a `FileNotFound` error and a half-overwritten
  `burrito_out/`.
- Sweeps `/tmp/unpacked_erts_*` directories older than 1 day before
  building. Each unpack is ~128 MB and Burrito never cleans them up;
  cumulative builds were filling the tmpfs and breaking unrelated
  tooling.
- `CLAUDE.md` updated to recommend `mix glorbo.build_local` over
  plain `mix release` for local builds.

### Fixed — TODO D1: `mix release glorbo` interactive overwrite prompt

`mix release glorbo` (without `--overwrite`) pauses on
`Release glorbo-X.Y.Z already exists. Overwrite? [Yn]`, which blocks
non-interactive CI/scripts. New `Mix.Tasks.Glorbo.ReleaseGuard`
module wraps `mix release` via an `:aliases` entry — it always
appends `--overwrite` (idempotent if already passed) and reuses
the same concurrent-build refusal as `glorbo.build_local`. Direct
callers (`mix release`, `mix release glorbo`, CI scripts) now get
the same guards as the recommended `mix glorbo.build_local` path.

### Fixed — release manifest contained dev-only `phoenix_live_reload`

`mix.exs` had `listeners: [Phoenix.CodeReloader]` set for ALL envs.
`Phoenix.CodeReloader` ships in `phoenix_live_reload` (which is
`only: :dev`), so listing it as a project listener caused mix release
to flag the dep as a runtime requirement and embed it in
`_build/prod/rel/glorbo/lib/phoenix_live_reload-*` and the
release manifest as `permanent`. Even after
`Mix.Tasks.Glorbo.BuildLocal.purge_dev_only_artifacts!/0` wiped
`_build/prod/lib/phoenix_live_reload`, mix release re-pulled it
during assemble. Two-part fix:

- Gated the listener on `Mix.env() == :dev` in `mix.exs`.
- `mix glorbo.build_local` now re-execs itself with `MIX_ENV=prod` if
  invoked without it. `Mix.Project.config()` is evaluated once at
  startup and cached, so bumping `Mix.env(:prod)` later in the task
  has no effect on `listeners(Mix.env())` — the re-exec ensures the
  project config is loaded with the right env from the very start.

### Changed — `mix release` aliased to `mix glorbo.release_guard`

`:aliases` in `mix.exs` now routes `mix release` through
`Mix.Tasks.Glorbo.ReleaseGuard`, a string-form alias so Mix loads
the task lazily (function aliases need the module already compiled,
which fails on a clean prod build). `ReleaseGuard`:

- Acquires a per-checkout lock at `_build/.release.lock` (atomic
  exclusive create + PID liveness check via `/proc/<pid>`). Stale
  locks from crashed prior builds are detected and reclaimed.
- Replaces the earlier `pgrep` heuristic which false-positived on
  the shell wrapper whose eval string contained the literal
  "mix release" we were searching for.
- Always appends `--overwrite` (idempotent) so direct `mix release`
  callers don't pause on the interactive overwrite prompt.
- Calls `Mix.Tasks.Release.run/1` directly to avoid recursing
  through its own alias.

### Fixed — Burrito `.zig-cache` poisoning across failed builds

Burrito 1.5.0's `clean_build` step targets `zig-cache` (no leading
dot) but the actual zig cache directory uses the modern
`.zig-cache` convention. The cleanup is a no-op, which by itself
is harmless (incremental builds reuse it), but when a prior build
crashed mid-way (concurrent-build race, transient zig OOM) it left
residual `payload.foilz.xz`/`musl-runtime.so` in
`deps/burrito/src/` AND `.zig-cache` manifests still referencing
those files. The next build deleted them as part of its own setup,
then zig failed with `FileNotFound` on `@embedFile`. Added
`purge_zig_cache_if_dirty!/0` to `mix glorbo.build_local`: detects
the residual files and wipes `deps/burrito/.zig-cache` plus the
residuals before invoking mix release. Cost is one full re-compile
(~5 min) only when a prior build was unclean.

### Fixed — TODO D2: OTP release missing `glorbo run` verb

`_build/prod/rel/glorbo/bin/glorbo` is the standard OTP launcher
that only knows OTP commands (`start`, `daemon`, `eval`, `rpc`),
so `bin/glorbo run acme/operator task.md` errors with
`ERROR: Unknown command run`. Added `rel/overlays/bin/glorbo-cli`
shell wrapper that converts `bin/glorbo-cli VERB ARGS...` into
`bin/glorbo eval 'Glorbo.CLI.dispatch(argv)'`, passing argv via a
NUL-delimited tempfile so paths with quotes / dollar-signs /
newlines round-trip safely. Lets an OTP release stand in for the
Burrito binary on hosts where Burrito hasn't been published yet
(e.g. host deployments without zig).

## [0.20.0] — 2026-05-04

Headline: GEP-45 Phase 3 closes — full ACP transport stack
(audit-log replay + model catalog + token/cost telemetry) plus a
2-3× scheduler rescan win.

### Added — GEP-45 Phase 3 stado_acp usage parser (closes Phase 3)

`Glorbo.CLI.Parsers.StadoAcp` shells out to `stado stats --session
<sessionId> --json` after each ACP dispatch and maps stado's commit-
trailer-derived totals to glorbo's canonical `Parsers.usage()` shape:
prompt/completion tokens, dominant model, per-tool calls. Adds two
extras above the canonical contract — `cost_usd` and `duration_ms`
— so the budget ledger can attribute spend per dispatch.

Stado tracks usage in commit-trailer form on its per-session git
refs (offline + airgap-friendly — source is the git audit log, not
an OTel pipeline). Glorbo doesn't parse the trailers directly; it
uses stado's supported `stats --json` interface so the contract
survives stado's internal schema changes.

The dispatcher's ACP branch wires the parser when
`provider.usage_parser == "stado_acp"`. Tests inject
`:command_fun` to bypass the real subprocess. `priv/providers/stado.toml`
now declares `usage_parser = "stado_acp"` so out-of-the-box stado
dispatches collect token/cost telemetry automatically.

Requires stado >= 0.27.x for the `stats --json` flag. Older stadoes
fall back to the human table; the parser flags this as
`{:invalid_json, _}` and the dispatcher records `usage: nil` /
`usage_error` set without failing the dispatch.

11 new parser tests + 2 dispatcher tests covering the success,
non-zero-exit, malformed-JSON, missing-session-id, and
missing-host-binary paths.

This closes the last open GEP-45 Phase 3 deliverable. The full
Phase 3 stack (audit-log capture, GEP-32 catalog wiring,
usage-parser) is shipped.

### Added — Scheduler rescan O(projects × tasks) → O(changed)

`Glorbo.Company.TaskScheduler` rescans the company task tree every
60 seconds as a safety net against missed inotify events. Previous
implementation re-read every task file + re-parsed YAML frontmatter
+ re-parsed the cron expression on every tick (1000 reads + 1000
YAML parses + 1000 cron parses every minute at 1000 tasks).

`scan_one/2` now lstats first and consults a per-task mtime cache:
if the file's mtime matches the cached entry AND its armed timer
is still live (`Process.read_timer/1` > 0), the entire read + parse
+ arm pass is skipped. Mirrors the `Glorbo.Search.scan_tasks` mtime
cache pattern. Adds a `read_timer_fun` injection seam so tests
exercise both cache-hit and cache-miss paths deterministically.

3 new perf tests on top of the existing 15.

## [0.19.0] — 2026-05-04

Headline: stado lands as glorbo's first ACP-driven provider, plus a
sharp set of doctor / migrate / dashboard fixes that make
`./glorbo serve` and `./glorbo doctor --fix` actually work the way
the docs say they do.

### Added — GEP-45 Phase 3 (in progress): per-frame ACP audit-log capture

`Glorbo.CLI.Dispatcher.Acp.Client.run/3` now accepts an `:audit_fun`
callback (`(role, kind, detail -> :ok)`) invoked for every
protocol-level event so operators can replay the exchange from
`audit/_system/YYYY-MM.jsonl`. Roles: `:client` (we sent), `:peer`
(we received), `:meta` (start/complete/error bookends). Kinds map
to ACP method names plus `:dispatch_start`/`:dispatch_complete`/
`:dispatch_error`. `:peer.session_update` carries `{kind, text_size}`
so the audit shows what the agent said without leaking the full
reply (which is in the outbox already).

The dispatcher's ACP branch resolves the audit_fun to
`Glorbo.CLI.Audit.emit("acp", "<role>.<kind>", detail)` by default,
landing one audit line per frame. Tests inject a stub callback that
captures into a list to assert exact emission shape. Adds 2 new
client tests covering happy-path emission and error-path
`:meta.dispatch_error`.

The dispatcher's success result now also carries
`acp: %{session_id, chunks, ignored_updates}` so callers (the agent
runtime, future GEP-32 catalog wiring) can correlate dispatches
with stado's own session trace under `~/.local/share/stado/sessions/`.

Open Phase 3 work: stado usage-parser (token + cost ingestion via
the per-session JSONL trace) and GEP-32 model-catalog integration.
Tracked in `docs/geps/0045-stado-as-glorbo-provider-via-acp.md`.

### Added — GEP-45 Phase 2: bench-acp stado smoke

End-to-end validation of the GEP-45 ACP transport against a real
`stado` binary, gated on a pinned snapshot under
`.bench/bin/stado-pinned` (operator-local, gitignored). The bench
drives the full path — `Dispatcher.invoke` →
`Bwrap.start_acp/2` → `PortIO.wrap/1` → `Client.run/3` → real stado
running `stado acp --tools` inside the bwrap namespace — and
asserts the glorbo-side wiring carries the JSON-RPC handshake
through cleanly.

Two pass conditions, both count as Phase 2 shipped: full-reply
(stado has a backend configured) or handshake-only (stado answered
`initialize` + `session/new`, then errored on `session/prompt` with
the canonical `{:provider_returned_error, %{code, message}}` shape).
Verified handshake-only against pinned stado v0.26.4 — the
load-bearing assertion that the framing, sandbox spawn, state
machine, and error mapping all work against a real ACP server.

Integration test at `test/integration/gep_45_stado_bench_test.exs`,
tagged `@moduletag :stado_bench` and excluded by default. Skips
cleanly when `STADO_BENCH_BIN` is unset and `.bench/bin/stado-pinned`
is absent. Bench protocol + reproducibility contract documented
at `docs/research/gep-45-bench-acp.md`.

Audit-log capture of the ACP message exchange carried over to
Phase 3 — Phase 2 ships the dispatch path; per-frame audit emission
is a separate concern.

### Added — GEP-45 Phase 1b sandbox + dispatcher: end-to-end ACP path

`Glorbo.Sandbox.Bwrap.start_acp/2` spawns the sandboxed CLI as a
long-running Port without the prompt-tempfile shell redirect.
`Glorbo.CLI.Dispatcher.Acp.PortIO` wraps an Erlang `Port` into a
`%Client.IO{}` with read/write/close callbacks. The dispatcher's
`prompt_mode = :acp` branch replaces the Phase 1a stub with a real
run loop, reusing the same template-expansion + reply-file
scaffolding as the stdin path. Adds an `:acp_run_fun` injection
seam mirroring the existing `:run_fun`. 7 new tests including a
full Port → PortIO → Client → Bwrap end-to-end against a fake-ACP
shell script.

### Added — GEP-45 Phase 1b client: ACP JSON-RPC state machine

`Glorbo.CLI.Dispatcher.Acp.Client.run/3` drives a single ACP
conversation through an injected `%Client.IO{}`:
initialize → session/new → session/prompt → drain text chunks
→ shutdown. Errors map to the existing dispatch error categories
(`:provider_protocol_error` / `:provider_returned_error` /
`:provider_timeout`). 16 mock-peer tests.

### Added — GEP-45 Phase 1b foundation: ACP framing + message types

`Glorbo.CLI.Dispatcher.Acp.Framing` + `.Message` + `.RpcError` ship
the wire-format half of the ACP JSON-RPC client. Message types are
tagged tuples — `{:request, id, method, params}` /
`{:notification, method, params}` / `{:response, id, result}` /
`{:error_response, id, %RpcError{}}` — keeping the client state
machine matchable on tuples without parsing JSON inline.

The framing layer encodes any tagged tuple into iodata terminated
by `\n` (ACP uses line-delimited JSON, NOT LSP's Content-Length
headers — confirmed against `stado/internal/acp/jsonrpc.go`'s
`bufio.ReadSlice('\n')`), and decodes inbound bytes via
`parse_stream/2` which handles partial-line buffering across
arbitrary kernel chunk boundaries — caller passes the previous
remainder + the fresh chunk, gets back parsed messages + new
remainder.

20 round-trip + edge-case unit tests covering all four message
kinds, partial-line buffering across multiple reads, malformed-
line tolerance (one bad message doesn't drop surrounding good
ones), and JSON-RPC 2.0 contract violations (wrong version,
missing fields, malformed error object).

The actual client state machine + bwrap port wiring + dispatcher
integration land in subsequent Phase 1b sub-slices.

### Added — GEP-45 Phase 1a: stado provider registry entry + ACP prompt_mode

Phase 1a of GEP-45's stado-as-provider integration ships the registry
half: `Glorbo.CLI.Registry.Provider` + `Loader` accept
`prompt_mode = "acp"`, and `priv/providers/stado.toml` declares stado
as a built-in provider with `args = ["acp", "--tools"]` plus auth_binds
for `~/.config/stado` (ro) and `~/.local/share/stado` (rw).
`Glorbo.CLI.Dispatcher.invoke/3` short-circuits ACP-mode providers
with a structured `{:unimplemented_prompt_mode, %{...}}` error — no
half-working stdin fallback, no hung port handshake — pointing
operators at GEP-45 Phase 1b for the real JSON-RPC client.

`AGENT.md` validation accepts `provider: stado` automatically — the
FileSpec was already registry-driven, no schema change needed.

Phase 1b will replace the dispatcher stub with the actual ACP
client (initialize → session/new → session/prompt → drain
session/update → write reply file → shutdown).

### Added — GEP-45 (Draft): stado as glorbo provider via ACP transport

Captures the design for adding stado to glorbo's GEP-8 provider
registry as `provider: stado`, parallel to `claude-code` / `codex` /
`gemini-cli` / `opencode`. Stado is a complete standalone agent
runtime — it calls its own configured model with its own bundled
tools — so the right shape is "stado IS the agent," not "stado is a
tool source consumed by claude." The transport is ACP (JSON-RPC 2.0
over stdio per Zed's Agent Client Protocol), which stado already
exposes via `stado acp`.

The integration extends GEP-8 with a new `prompt_mode = "acp"` (joins
the existing `prompt_mode = "stdin"`). Sandbox composition,
auth_binds, the reply-file contract, and the audit pipeline all
reuse the existing GEP-8 plumbing unchanged; only the dispatcher's
run-loop branches between stdin-prompt and ACP.

Phase 1 = `Glorbo.CLI.Dispatcher.Acp` JSON-RPC client + provider
loader accepting `prompt_mode = "acp"` + `priv/providers/stado.toml`
shipping. Phase 2 = bench validation. Phase 3 = operational polish
(usage parser for stado's session JSONL, network-policy guidance,
GEP-32 catalog integration).

Bidirectional links: GEP-8 `extended-by` gains 45; GEP-9 `extended-by`
keeps 45 (this is the first concrete outbound protocol-level
integration on the direction GEP-9 sketched).

The earlier draft of this GEP framed the integration as
MCP-server-injection-into-claude-code (case B in the user-preference
memory) — the wrong shape for the dogfood ask. The Draft body was
rewritten in place after maintainer correction; the
MCP-injection concern is shelved unless a concrete need surfaces
(separate future GEP if so).

### Added — `make` Makefile wraps `mix glorbo.build_local` + common verbs

Convenience target file at the project root. `make` (default) builds
the Burrito linux_x86_64 release and materialises `./glorbo` as a
symlink — same end state as `mix glorbo.build_local`. Other targets
mirror common dev verbs (`make test`, `make precommit`, `make credo`,
`make serve`, `make doctor`, `make migrate`) plus `make build-real`
to drop a real binary file at `./glorbo` (no symlink) for tarball /
container packaging. `make help` lists everything.

### Added — `glorbo doctor --fix --install-deps` actually installs missing host packages

Previously `--fix` for `bwrap` / `pasta` / `uidmap` only printed the
matching `dnf install` / `apt install` / `pacman -S` command via the
`:explain` path — leaving the operator to copy-paste it themselves.
The new `--install-deps` flag (opt-in; default `--fix` behavior is
unchanged) extends the fixer to actually run
`sudo <pkgmgr> install -y <pkg>` after detecting the host distro from
`/etc/os-release`:

  * **fedora-family** (fedora / rhel / centos / rocky / almalinux)
    → `dnf install -y bubblewrap | passt | shadow-utils`
  * **debian-family** (debian / ubuntu / pop / mint / kali / raspbian)
    → `apt install -y bubblewrap | passt | uidmap`
  * **arch-family** (arch / endeavouros / manjaro)
    → `pacman -S --noconfirm bubblewrap | passt | shadow`

Unknown distros fall back to the existing `:explain` runbook. `sudo`
runs with `-n` to fail-fast when no cached credentials and no
controlling TTY are available; under an interactive shell it prompts
for the password normally. New `explain_uidmap` fixer covers the
`uidmap` check (previously missing from the fixer registry — now
explicit on the default path too).

`GLORBO_DOCTOR_DISTRO_OVERRIDE=fedora|debian|arch|<other>` short-
circuits `/etc/os-release` parsing for unit tests that pin the family
without rewriting `/etc/`.

Dogfood-note item from field-testing workflow integration:
"Worth a `--fix` heuristic that calls `dnf install shadow-utils
passt` on Fedora."

### Fixed — `glorbo serve` / `glorbo up` now actually bind port 4000

Phoenix endpoints default to `server: false` outside `mix phx.server`;
in a Burrito release `config/runtime.exs` only flipped `:server` to
`true` when `PHX_SERVER` was set in the environment. Without it,
`glorbo serve` printed *"Glorbo serving on http://127.0.0.1:4000"*
but the endpoint stayed in standby and never bound the port — the
browser refused to connect even though `glorbo status` reported
running. `glorbo up` had the same bug for the daemon path.

The CLI now sets the flag on its own behalf:

  * `Glorbo.CLI.Lifecycle.Serve` flips `GlorboWeb.Endpoint`'s `:server`
    config to `true` before booting the supervision tree (gated on a
    new `:serve_starts_endpoint` flag — `false` in the test env so
    ConnCase suites don't collide on port 4000).
  * `Glorbo.CLI.Lifecycle.Up` exports `PHX_SERVER=1` in the env list
    passed to the re-exec'd Burrito daemon.

Regression tests cover both paths (serve config contract +
PHX_SERVER export to the daemon child env via the `fake_daemon_binary!`
fixture). Operators no longer need to know about `PHX_SERVER`.

### Added — `glorbo doctor` flags pending schema migrations

`migrations_pending` is a new warning-severity check that compares
files in `priv/repo/migrations/` against rows in the SQLite
`schema_migrations` table. When the binary has been rebuilt past
the user's `~/.glorbo/glorbo.db` (the symptom that surfaced as a
`PendingMigrationError` 503 in the dashboard during the v0.11→v0.18
upgrade probe), doctor now points at the verb that fixes it:

    ✗ migrations_pending  [warn]  N pending migration(s) (oldest: T). Run `glorbo migrate`.

The check is read-only (`Exqlite.Sqlite3.open(:readonly)`) and
DI-friendly via `db_path_fun` / `migrations_dir_fun` deps so tests
don't touch `~/.glorbo/`. Severity is `:warning`, so a missing
migration surfaces as exit code 2 (warning-only) rather than 1
(blocker) — operators can still run the binary, but the failing
migration is loud.

### Fixed — flaky `Process.sleep` waits for Tx auto-flush

Two debounce-based test assertions ("retire roundtrip captures
deletions" in `Glorbo.Actions.AgentsTest`, "with_tx happy path"
in `Glorbo.HomeHistory.TxTest`) waited for an auto-flushed git
commit via `Process.sleep` and read the log immediately after. The
window had been bumped twice (b48c5aa → 6390127, 150ms → 1000ms)
without fully closing the aarch64 GHA flake. Replaced with a 25ms-
poll-with-deadline (`wait_for_new_commit!/3`) that returns the
moment the commit lands and only waits the full 5s on a genuinely
stuck Tx. Fixes the recurring aarch64 CI failure on `agents_test`
without slowing fast runners.

### Added — AppRoot idle-mode discovery footer

The shell now renders a one-line footer beneath every view's
body when no chord or chord-error is active:

    (? help · C-c o/t/a/c/p/h/u to switch view · q quit)

Pre-Phase-3a-revisit the help overlay was reachable only by
typing `?` blindly, and the chord prefix only via `C-c`. Both
are now discoverable on first launch without consulting docs.
Footer is suppressed during chord mode (already shown its own
`(C-c …)` hint) and after a chord error (showing the
`[chord] unknown chord: …` line) to avoid visual stacking.

## [0.18.0] — 2026-04-27

GEP-37 Phase 3-revisit slice continues: AppRoot picks up a
discoverability overlay, the Audit view picks up cross-month
navigation. Plus a test-suite cleanup round and the GEP-37
decision-log now records every revisit slice.

### Added — GEP-37 Phase 3a-revisit (AppRoot help overlay)

`?` in idle mode opens a full-screen keymap reference: chord
prefix table, list-nav primer (`j`/`k`/arrows/`r`/`q`),
plus per-view modal triggers (Inbox `a`/`d`, Chat `i`/`s`,
the three slash commands, Audit `p`/`n`). Esc or `?` again
dismiss. While the overlay is open, every other keystroke
is absorbed so the user can't accidentally navigate the
underlying view or trigger a chord. State gains a
`:help_open` boolean. 5 new tests.

### Added — GEP-37 Phase 3e-revisit (Audit older-page navigation)

The Audit view picks up cross-month navigation. `p` moves to
the next-older bucket, `n` to the next-newer; both are
no-ops at the boundaries. Header line shows the active
month plus `(p older)` / `(n newer)` hints whenever more
pages exist (so the keybinding is discoverable without a
help screen). Empty-state placeholder names the active
month. State now carries `:year_month` (the bucket being
viewed) and `:available_months` (newest-first list of
on-disk buckets, with the current month always at index 0
even when no JSONL file exists yet for it).

`Audit.Data.load_tail/3` migrated from positional
`(base, company, n)` to keyword opts `(base, company, opts)`
where opts can carry `:year_month` and `:n`. The view's
`:loader_fn` injection seam is now 3-arity
`(base, company, year_month)`. New `Audit.Data.list_year_months/2`
enumerates on-disk buckets, filters out non-jsonl entries
and malformed names (out-of-range months, garbage
filenames), and dedups the always-included current month.

12 new tests (5 view + 5 Data + 2 event_to_msg / boundary
no-ops).

### Changed

  - Test-suite cleanup round (–13 tests, –127 LOC). Removed
    `test/glorbo/stubs_test.exs` (pure `function_exported?`
    smoke checks; compile-time guaranteed), three OTP-stdlib
    `Registry` tests in `agent/registry_test.exs` (testing
    BEAM, not project code), and a self-admitted duplicate
    block + a non-contractual log-disjunction match. No
    coverage loss verified by re-running the full suite.
  - `docs/geps/0037-glorbo-shell.md` now records the eight
    Phase 3-revisit slices that shipped from v0.15.1 → v0.18.0
    plus the three structural deferrals (Tasks last-wake,
    Overview in_progress_count + goals_summary, Audit live-
    tail EventBus subscription) with reasons for each.

## [0.17.0] — 2026-04-27

GEP-37 Phase 3-revisit slice: the Chat composer learns slash
commands and the Tasks view picks up per-status glyph pills.
Both ride the existing read-side seams without growing the
filesystem or Repo dependency.

### Added — GEP-37 Phase 3g-revisit (Tasks status pill)

Each task row in the TUI Tasks view now carries a single-char
status glyph between the cursor prefix and the task id. Glyphs
distinguish the four review-lane sub-states (pending /
pending-approval / approved / denied) which all collapse into
the same lane bucket and were previously visually
indistinguishable. The mapping mirrors the LV's
`gl-status--<status>` colour split:

  · todo
  ▸ in-progress
  ? pending / pending-approval
  + approved
  ✗ denied
  ✓ done
  ? unknown

`Tasks.Data.status_glyph/1` is the new helper; the view
threads it into each row render before the task id. 9 new
tests (1 in tasks_test.exs covering all six glyphs in one
sweep + 8 in data_test.exs covering each status individually
plus unknown fallback).

### Added — GEP-37 Phase 3f-revisit-3 (composer slash commands)

The Chat composer parses `/`-prefixed buffers as commands
instead of posting them to the channel. Three commands ship:
`/switch <channel>` swaps to the named channel and reloads
through the existing `:loader_fn` seam (same path the
modal switcher uses); `/help` shows the available commands
on the action line; `/cancel` is a silent exit (no
last_action change, alias for Esc). Unknown commands record
`{:error, :command, {:unknown_command, name}}`; `/switch`
to a missing channel records
`{:error, :command, {:unknown_channel, name}}`; `/switch`
without an argument records
`{:error, :command, {:missing_argument, "switch"}}`. Errors
render on the action line as `✗ unknown command: /<name>` /
`✗ unknown channel: #<name>` / `✗ missing argument:
/<name> <arg>`. A buffer that begins with whitespace is
treated as a regular post even if `/` follows — only a
leading `/` invokes the parser. Composer hint line now
mentions `/help`. 8 new tests.

## [0.16.0] — 2026-04-27

GEP-37 Phase 3f-revisit slice. The Chat view picks up its
write path and a channel switcher, completing the LV's
chat-surface parity for the v1 TUI.

### Added — GEP-37 Phase 3f-revisit (Chat composer modal)

The Chat view picks up a write path. Pressing `i` opens a
modal composer; keystrokes accumulate into a buffer, Enter
posts the message via `Glorbo.Actions.post_message/4` (the
same Action seam the LV's chat form goes through, so
audit-log + isolation invariants are honoured), and Esc
cancels without touching disk. After a successful post the
view refreshes the message list and renders a `✓ posted`
status line; failures surface as `✗ post failed: <reason>`
without clobbering the existing list. State carries an
explicit `mode :: :list | {:compose, buf}` plus a
`last_action` field for the feedback line — same modal
shape as the Inbox deny prompt. `:post_fn` is injected so
tests don't actually shell out to `post_message`. 11 new
tests.

### Added — GEP-37 Phase 3f-revisit-2 (Chat channel switcher)

`s` in list mode opens a channel switcher modal listing
every channel the company has on disk (via
`Chat.Data.list_channels/2`). j/k navigate, Enter switches
to the highlighted channel and reloads its messages
through the existing `:loader_fn` seam, Esc cancels. Cursor
seeds onto the currently active channel so the modal opens
"in place." Same modal shape as the composer. State now
carries `mode :: :list | {:compose, buf} | {:switch,
%{channels, cursor}}`. `:list_channels_fn` injection so
tests don't hit the filesystem. 8 new tests.

## [0.15.1] — 2026-04-26

GEP-37 Phase 3-revisit slice — two views gain Repo-backed
columns matching the LV's heavier surface. Same dependency-
injection pattern (`:ledger_fetch_fn`) so tests don't hit
the Repo; production reads through.

### Added — GEP-37 Phase 3c-revisit (Overview+ spend column)

`Glorbo.Shell.Views.Overview.Data.load_companies/2` now sums
each company's current-month spend across agents (via
`Glorbo.Budget.Ledger.fetch/3`) and surfaces it as
`:spend_cents` on the row. The view appends `, $X.YZ spent`
after the alerts column when spend > 0; quiet companies stay
visually distinct. Same fail-open-with-0 + `:ledger_fetch_fn`
injection pattern as Agents+. The LV's heavier `in_progress_count`
+ `goals_summary` columns are still future work — they walk
every task file per company so the cost grows with workspace
count. 7 new tests.

### Added — GEP-37 Phase 3d-revisit (Agents+ budget columns)

`Glorbo.Shell.Views.Agents.Data.load_agents/3` now reads
each agent's monthly budget cap from frontmatter
(`budget.monthly_usd`, normalised to cents — handles
integer / float / string declarations) and current spend
from `Glorbo.Budget.Ledger.fetch/3`. Tests inject a
`:ledger_fetch_fn` stub to bypass the Repo; production
reads through. The view renders a `· $used.dd/$cap.dd`
column after `· network` when a cap is set; agents without
a declared cap (or with `0`) keep the cleaner pre-revisit
shape so untracked agents stay visually distinct.

Failure mode: the ledger fetch is wrapped in a `rescue
... -> 0` so the view still renders even when the Repo
isn't connected (e.g. `glorbo shell` boots before DB on
a recovery path). 9 new tests across the Data + view test
files covering cap normalisation, ledger fetch routing,
year_month override, and view rendering with/without
cap.

## [0.15.0] — 2026-04-26

GEP-37 Phase 3 *complete* lands on the release surface.
Phase 3g (Tasks view, the kanban-style flagship) ships
alongside the post-Phase-3 housecleaning refactor that
extracted `Glorbo.Shell.Views.Common` for shared
cursor-list helpers across all seven views. With this,
the GEP-37 v1 surface as defined in D8 ("View list
matches web surface 1:1") is shippable.

### Added — GEP-37 Phase 3g (Tasks view)

`Glorbo.Shell.Views.Tasks` is the kanban-style flagship —
the seventh and last GEP-37 view. Stacked-vertical layout
with five lanes (TODO / IN PROGRESS / REVIEW / DONE /
OTHER); each lane gets a `▾ <LANE> (<count>)` header
followed by indented task rows `<task_id> — <title>
[<assignee>]`. REVIEW collects pending / pending-approval /
approved / denied (mirrors `KanbanLive.group_by_column/1`);
OTHER catches unknown statuses. Cursor navigates the flat
sequence of task rows across lane boundaries; rows are
sorted into canonical lane order on init/refresh so the
cursor index always matches the rendered order.

`Glorbo.Shell.Views.Tasks.Data` walks
`companies/<co>/projects/*/tasks/*.md` via
`Glorbo.TaskDefinition.parse_file/2`. Helpers
`group_by_lane/1`, `lanes/0`, `lane_label/1` give the
view stable bucketing + header text.

AppRoot wires `C-c t` → `:tasks`. With this, every letter
in `view_letter_map/0` (o/t/a/c/p/h/u) routes to a real
view — there is no longer a not-yet-implemented path
through normal letters; only unmapped letters (e.g. `z`)
hit the unknown-chord branch.

**GEP-37 Phase 3 complete.** All seven D10 chord-target
views are implemented and reachable via the chord prefix.

### Changed — Phase 3 housecleaning refactor

Extracted `Glorbo.Shell.Views.Common` — shared cursor-list
helpers (`cursor_nav_event/1`, `cursor_down/2`, `cursor_up
/1`, `clamp_cursor/2`). All seven Phase-3 views routed
through it; Inbox keeps its view-specific arms ahead of
the cursor-nav fallthrough. **Net –111 LOC** (-149 from
view dedup, +38 from the new module + tests) with zero
behavior change. Future view additions inherit the helpers
automatically.

### Test count

2522 (up from 2481 at v0.14.0) — 41 net new tests:
+28 Tasks view + 13 Common helpers.

## [0.14.0] — 2026-04-26

GEP-37 Phase 3 — six new views land the chord-driven view-
switching machinery + five drop-in-parity views beyond the
v0.13.0 Inbox. The TUI now has every view its `C-c <letter>`
keybinding table claims except `:tasks` (the kanban-style
flagship; deferred to v0.15.0 because it breaks the simple
list pattern).

### Added — GEP-37 Phase 3a (chord-prefix scaffold)

`Glorbo.Shell.AppRoot` is the new top-level Elm view that
wraps per-view modules and owns the `C-c <letter>` chord
state machine (`:idle | :c_c`). Ctrl+c flips into chord
mode; the next keystroke selects a view (one of `o/t/a/c/p/
h/u`); Esc cancels. Unknown / not-yet-implemented chord
letters surface a `chord_hint` footer line without
changing the active view. View swap forwards `:base` +
`:company` opts to the new view's `init/1`. Launcher
updated to use AppRoot as root instead of Inbox directly;
`init/1` accepts a new `:initial_view` opt for non-default
starts.

### Added — GEP-37 Phase 3b (Health view)

`Glorbo.Shell.Views.Health` mirrors `glorbo doctor` output
as a cursor-navigated list: one line per check with
pass/fail glyph (`✓`/`✗`) + severity tag (`[blocker]` /
`[warning]` / `[info]`). `r` re-runs `Doctor.run_checks/0`
for live reload. AppRoot routes `C-c h`.

### Added — GEP-37 Phase 3c (Overview view)

`Glorbo.Shell.Views.Overview` is the cross-company
workspace list: one row per `companies/<slug>/` with
`slug (name) — N agents, M alerts`. The active company
(launched workspace) gets a `*` glyph; cursor lands on
the active row on first paint. FS-only read — Repo-backed
spend/in-progress/goals columns deferred to a later phase.
AppRoot routes `C-c o`.

### Added — GEP-37 Phase 3d (Agents view)

`Glorbo.Shell.Views.Agents` is the per-company roster.
Each row: `<slug> [<role>] <provider>/<model> · <network>
→ <reports_to>` (the trailing arrow only when set).
FS-only read of `agents/<slug>/AGENT.md` (or legacy
`agent.md`); `.archive/` + dotfile dirs hidden; agents
without an AGENT.md are not surfaced (not bootable).
AppRoot routes `C-c a`.

### Added — GEP-37 Phase 3e (Audit view)

`Glorbo.Shell.Views.Audit` renders the current-month
JSONL audit tail. Each line: `[<ts>] <actor> <action>
<target>` with ts trimmed to YYYY-MM-DDTHH:MM. Bounded-
memory tail strategy mirrors the LV's load_tail (default
last 100 entries). AppRoot routes `C-c u` (the "aUdit"
mapping per D10).

### Added — GEP-37 Phase 3f (Chat view)

`Glorbo.Shell.Views.Chat` renders a channel's message
stream. Header `#<channel>`; one line per message:
`[<ts>] <author>: <first body line>`. Multi-line bodies
collapsed to first line for the cursor list (Phase 3g
adds Enter-to-expand + slash-command composer). Mirrors
the LV's `## <ts> | <author>` parse contract; sub-headers
inside a body don't terminate the message. AppRoot routes
`C-c c`.

### Test count

2481 (up from 2348 at v0.13.0) — 133 net new tests across
the six Phase-3 views.

### What's left in GEP-37

- **Phase 3 / `:tasks`** — kanban-style flagship; the only
  remaining view. Breaks the simple list pattern (multiple
  status-group lanes), so deferred to v0.15.0.
- **Phase 3g** — channel switcher + slash-command composer
  for Chat; Enter-to-expand for full message body.
- **Phase 3f-2** — live-tail EventBus subscription for the
  Audit view (Phase-1 supervisor already forwards
  `company:<co>:audit` broadcasts; wire-up is a
  Runtime → AppRoot routing question).
- **Phase 3e (Agents+)** — Repo-backed budget tracking +
  last-wake hint + pill status (matches the LV's heavier
  `build_agent_row/5` slice).
- **Phase 3 (Overview+)** — spend / in-progress task /
  goals-progress columns (Repo-backed).

End-to-end in a real TTY:

    $ glorbo shell acme         # Inbox
    C-c o                       # Overview (acme highlighted)
    C-c a                       # Agents (acme's roster)
    C-c u                       # aUdit (current-month tail)
    C-c c                       # Chat (#general)
    C-c h                       # Health (doctor checks)
    C-c p                       # back to Inbox

## [0.13.0] — 2026-04-26

First launchable `glorbo shell`. GEP-37 Phases 1 + 2 + 2b + 2c
land in this release; the alpha TUI is now real software a
Director can drop into a terminal and use to triage approvals
end-to-end. The LiveView dashboard remains the primary surface
until Phase 3 widens the TUI to view parity.

### Added — GEP-37 Phases 1 / 2 / 2b / 2c (alpha shell)

- **Phase 1** — `Glorbo.Shell.{Supervisor, EventBus, Runtime}`.
  Supervisor uses `:rest_for_one` per GEP-37 D6 (EventBus →
  Runtime) — sibling of `CompanySupervisor` under
  `Glorbo.Application` so a shell crash cannot kill agents,
  router, audit, or any core service. EventBus subscribes to
  per-company PubSub topics (`projects` / `channels` / `agents`
  / `audit` / `approvals`) plus the cross-company
  `glorbo:companies` topic and forwards each broadcast as
  `{:shell_event, raw_msg}` casts to Runtime. Runtime
  accumulates the most-recent 256 events and exposes
  `state/1` for tests + future Phase-3 view callbacks.
  `Glorbo.Application` gained `apply_surface/2` reading
  `:glorbo, :surface` config (`:web` keeps the existing
  Endpoint-only tree; `:tui` swaps in the shell subtree;
  `:headless` runs neither).

- **Phase 2** — `Glorbo.Shell.Views.Inbox` implements
  `TermUI.Elm` for the approvals list with cursor navigation
  (arrows + j/k, q to quit, empty-state placeholder).
  `Glorbo.Shell.Views.Inbox.Data` is the disk-read layer
  loading `agents/*/state/awaiting-approval-*.md` sentinels;
  sentinels without matching task files surface with
  `task_path: nil` so the Director can clear dangling state
  via Phase 2b.

- **Phase 2b** — approve (`a`) / deny (`d`) actions wired to
  the wave-31 `Glorbo.Actions.set_approval/4` API. Both paths
  are dependency-injected via `:approve_fn` + `:loader_fn`
  for test isolation. After success, the approvals list
  refreshes and the cursor reclamps within new bounds.
  Defensive arms: empty list, sentinel-without-task, missing
  company/base, and `set_approval`-returns-error all surface
  via `last_action: {:error, decision, reason}` without
  crashing.

- **Phase 2c** — deny-reason prompt UX (modal `:deny_prompt`
  mode with buffered keystrokes; Enter submits with
  `denial_reason:`, Esc cancels) + new `Glorbo.Shell.Launcher`
  composing `TermUI.Runtime.run/1` opts from CLI argv +
  `~/.glorbo`. `glorbo shell <company>` is the first
  end-to-end-working alpha shell launch path. Validates the
  company is a slug + the dir exists; rejects bad input with
  operator-friendly exit-2 messages. Production callers use
  the default `runner_fn: &TermUI.Runtime.run/1`; the test
  suite passes a recording double so it never boots term_ui.

  **Production launch path is now end-to-end working.** In a
  real TTY, `glorbo shell acme` invokes
  `TermUI.Runtime.run/1` for the first time and renders the
  `term_ui`-driven Inbox view. The Director can navigate
  approvals (arrows/jk), approve (`a`), deny with reason
  (`d` → buffer → Enter), and quit (`q`).

### Changed — Housecleaning refactor

Per the code-reviewer agent's punch list (six items closed in
one bundled commit, +87/-116 net deletion, no behavior change):

- Extract `walk_company_audit_dirs/3` helper in
  `Reindex` — the three GEP-34 rebuild phases now share the
  list-companies / filter-dirs / `safe_audit_dir/1` walk via
  a single 3-arity helper.
- Extract `decode_capped_line/3` helper for the per-line
  blank-line / 64-KiB cap / Jason.decode logic that the
  three audit-replay phases used to duplicate.
- Collapse byte-identical `infer_company_name/1` +
  `infer_agent_name/1` → `parent_dir_basename/1`.
- `BudgetTracker.parse_alert_key/2` now uses
  `Frontmatter.parse/1` (already aliased) for the `month:`
  field instead of a homemade regex; the `extract_yaml_field/2`
  helper is removed.
- `reindex_test.exs` — promote two duplicate
  `seed_acme*/1` helpers into a top-level
  `seed_company/2` with a default slug arg.

### Fixed — pre-emptive flake remediation

- Three more `Process.sleep(150)` bumps (→ 1000ms) in
  `agents_test.exs` + `companies_test.exs` matching the
  v0.11.3 `channels_test.exs` + v0.12.5 `tasks_test.exs`
  HomeHistory.Tx debounce-flake pattern. Pre-emptive sweep
  to harden CI before the flakes bite a future release tag.

### Test count

2348 (up from 2265 at v0.11.3) — 83 net new tests across the
GEP-37 phases, housecleaning, and CI hardening.

## [0.12.5] — 2026-04-26

Same-day patch on top of v0.12.4. Bundles the aarch64 CI
flake fix from `tasks_test.exs:711`'s
`Process.sleep(150)` HomeHistory.Tx debounce window. The
v0.12.3 tag failed the same flake (publish-skipped); v0.12.4
got lucky on the intermittent failure and published; v0.12.5
makes the fix permanent so future patches don't flake.

Cumulative threatmodel: **100 security findings closed across
34 waves**. Three Medium-severity isolation findings
(waves 31 + 32 + 33) and two Low defense-in-depth findings
(waves 29 + 30 + 34) closed in the same day. Two findings
remain accepted-by-design.

### Security (wave 33)

- **Medium** — `Reindex` Phase 1 (`audit_events`) now also
  treats the on-disk dirname as canonical, mirroring wave 32.
  Wave 32 closed the cross-company spoof for Phase 2 + 3 but
  left Phase 1's `safe_company_slug` lenient because
  `audit_events` legitimately stores cross-routed events. On
  reflection, that argument applied only to the writer side
  (`Company.AuditLog.entry_company/1` routes to the right dir
  based on the JSONL field). At the read path the dirname has
  already encoded the canonical company by the time we
  iterate — accepting a JSONL `company:` override still let an
  attacker who could write into one company's audit dir
  pollute another company's audit feed in the dashboard.
  New helper `audit_company_slug/1` makes the dirname
  authoritative for Phase 1 with `_system` allowance for the
  system-audit dir; `safe_company_slug/2` removed (no
  remaining callers). 1 new spoof-rejection test.

### Security (wave 34)

- **Low** — `Company.BudgetTracker.parse_alert_key/2` now
  derives the agent slug from the alert filename
  (`<agent>-budget.md`) instead of the frontmatter `agent:`
  field. Same dirname-vs-content discipline as waves 31-33,
  applied to BudgetTracker's `alerts_fired` rehydrate path.
  Pre-fix, an attacker who could write to `<base>/companies/
  <co>/alerts/` (operator-only attack surface — agents are
  bwrap-prevented) could write `editor-budget.md` with
  `agent: "ceo"` in frontmatter, populating the MapSet with
  `{ceo, <month>}` and silently suppressing ceo's real
  alerts for that month. Post-fix the filename is canonical;
  frontmatter-only `agent:` mismatches are ignored. 1 new
  test confirming the rehydrate prefers the filename's
  agent over the frontmatter's.

### Fixed

- `test/glorbo/actions/tasks_test.exs` aarch64 CI flake on
  HomeHistory.Tx debounce (`Assertion with =~ failed` at
  line 714 + 738). Two `Process.sleep(150)` windows bumped
  to 1000ms with a comment naming the debounce config and
  the historical v0.11.3 channels_test precedent. The flake
  blocked v0.12.3 + v0.12.4 publish jobs (publish depends on
  aarch64 build+test success); v0.12.5 is the first patch
  in this trio to actually land a signed GitHub Release.

## [0.12.4] — 2026-04-26

Same-day security patch on top of v0.12.3 (which was tagged
but had its publish job skipped — see below). v0.12.4's
aarch64 CI job passed and the release published; v0.12.4
is therefore the FIRST release in the wave-33 trio
(0.12.3 / 0.12.4 / 0.12.5) to actually appear on GitHub.

Ships the wave-33 Medium-severity follow-up that closed the
JSONL `company:` spoof for Phase 1 (`audit_events`),
unifying the dirname-as-canonical discipline across all
three GEP-34 projections.

A sixth self-review pass after wave 33 returned clean — no
further cross-company isolation gaps in the GEP-34 surface
(approvals readers all scope by `company_slug`; budget
readers all scope by `company_slug`; audit dashboard reads
JSONL directly, not the mirror; incremental reindex doesn't
touch GEP-34 projections; the wave-31/32/33 fixes cover the
attack surface comprehensively).

Cumulative threatmodel: **99 security findings closed across
33 waves**. Three Medium-severity isolation findings (waves
31 + 32 + 33) closed in the same day, all from progressive
self-review of the GEP-34 reindex code shipped in v0.12.0.
Two findings remain accepted-by-design.

### Security (wave 33)

- **Medium** — `Reindex` Phase 1 (`audit_events`) now also
  treats the on-disk dirname as canonical, mirroring wave 32.
  Wave 32 closed the cross-company spoof for Phase 2 + 3 but
  left Phase 1's `safe_company_slug` lenient because
  `audit_events` legitimately stores cross-routed events. On
  reflection, that argument applied only to the writer side
  (`Company.AuditLog.entry_company/1` routes to the right dir
  based on the JSONL field). At the read path the dirname has
  already encoded the canonical company by the time we
  iterate — accepting a JSONL `company:` override still let an
  attacker who could write into one company's audit dir
  pollute another company's audit feed in the dashboard.
  New helper `audit_company_slug/1` makes the dirname
  authoritative for Phase 1 with `_system` allowance for the
  system-audit dir; `safe_company_slug/2` removed (no
  remaining callers). 1 new spoof-rejection test.

## [0.12.3] — 2026-04-26 (tagged, publish-skipped — superseded by v0.12.5)

> **Tag exists in git history but no GitHub Release was created.** The
> `aarch64 build + test` CI job flaked on
> `tasks_test.exs:711`'s 150ms debounce sleep, which skipped the
> `Publish signed release` job. v0.12.5 supersedes this tag with the
> same content plus the wave-33 / wave-34 closures and the flake fix;
> binaries for v0.12.3 were never signed nor uploaded.

Same-day security patch on top of v0.12.2. Ships the wave-32
Medium-severity follow-up that closed a cross-company spoofing
path left open by waves 30 + 31. Per
`docs/project-profile.md` P0 rule (no Medium security findings
sliding past a version cut), wave 32 demanded its own patch
release the moment v0.12.2 landed.

Cumulative threatmodel: **98 security findings closed across
32 waves**. Two Medium-severity isolation findings (waves
31 + 32) closed in the same day, both surfaced by self-
review of the GEP-34 reindex code shipped in v0.12.0. Two
findings remain accepted-by-design.

### Security (wave 32)

- **Medium** — `Reindex` Phase 2 (approvals) and Phase 3
  (budgets) now treat the on-disk audit dirname as the
  canonical company, ignoring the JSONL `company:` field.
  Wave 30 introduced `safe_company_slug/2` which preferred
  the JSONL field over the dirname; wave 31 added the
  `company_slug` column to `tasks_approval_state`. Together
  those left a cross-company spoofing path: an attacker who
  could write an audit JSONL line into one company's audit
  dir (e.g. via a misconfigured operator path-grant) could
  set `company: "<other-company>"` and create a spoofed row
  in the other company's projection — defeating the wave-31
  isolation fix. Phase 1 (audit_events) keeps the original
  permissive behaviour because that table stores
  cross-routed events the writer intentionally tags. New
  helper `dirname_company_slug/1` makes the dirname
  authoritative for Phase 2 + 3; rejects non-slug dirnames
  (so `_system` and other non-company tokens drop the row).
  2 new tests confirm cross-spoofing attempts via JSONL
  `company:` are ignored at both phases.

## [0.12.2] — 2026-04-26

Same-day security/quality patch on top of v0.12.1. Ships the
wave-31 Medium-severity cross-company-bleed fix off the
[Unreleased] surface (per `docs/project-profile.md` P0 rule:
no Medium security findings sliding past a version cut),
plus the GEP-34 projection-count seam-surfacing and schema
moduledoc refresh that accumulated since v0.12.1.

Cumulative threatmodel: **97 security findings closed across
31 waves**. Two findings remain accepted-by-design.

### Security (wave 31)

- **Medium** — `tasks_approval_state` schema scoped by company.
  Pre-fix, the table had a unique index on `task_path` alone
  with no `company_slug` column. If two companies had awaiting
  tasks at the same relative path (`projects/foo/tasks/x.md`),
  `Approvals.Gate.upsert_awaiting`'s `conflict_target:
  [:task_path]` silently no-op'd the second insert, and
  `find_awaiting_row(state, task_path)` returned the wrong
  company's row. Director clicking "approve" on company B's
  dashboard would update company A's row. Violates the
  CLAUDE.md "Company isolation is absolute" load-bearing
  invariant. Migration `20260426170000` drops + recreates the
  table with `company_slug NOT NULL` and a composite
  `(company_slug, task_path)` unique index (SQLite doesn't
  support ALTER COLUMN to make a column NOT NULL after
  backfill, so drop+recreate is the right call; the GEP-34
  Phase 2 reindex regenerates rows from JSONL on next
  `glorbo reindex`). All three Gate write paths
  (`upsert_awaiting`, `upsert_resolved`, `find_awaiting_row`)
  now scope by company; Reindex Phase 2 fold keys by
  `{company, task_path}` instead of just `task_path`. 2 new
  tests cover the cross-company isolation contract end-to-end
  (gate-side + reindex-side).

### Changed

- `glorbo reindex` CLI verb, `glorbo init` reindex step, and the
  Director-side reindex flash on CompanyLive now surface all
  three GEP-34 projection counts:
  `audit_events=N approvals=N budgets=N` alongside the existing
  `indexed/skipped/deleted` triplet. Pre-v0.12.1 callers had no
  visibility that the new projections had rebuilt successfully.
  `Reindex.run/1`'s no-companies-dir short-circuit also gained
  the three new zero-value keys so callers don't `KeyError`
  on an empty tree.

## [0.12.1] — 2026-04-26

Same-day security/quality patch on top of v0.12.0. Two
defense-in-depth lows closed via post-ship self-review of the
GEP-34 reindex code, plus an unrelated inotify-race test
stabilization caught while reviewing the wave-30 work.
Cumulative: **96 security findings closed across 30 waves**.

### Security (waves 29 + 30)

- **Low (wave 29)** — `Reindex` audit-dir walks now lstat before
  iterating. The Phase 1/2/3 rebuild paths shipped in v0.12.0
  were calling `File.dir?/1` on `companies/<co>/audit/` and
  `<base>/audit/_system/` without symlink discipline; the kernel
  sandbox already prevents agents from planting these symlinks,
  but mirroring the `safe_markdown_files/1` discipline at the
  application layer keeps the two enforcement points in sync.
  Single `safe_audit_dir/1` helper routes all three rebuild
  paths through `AgentWritableFile.any_symlink_in_path?/1`.
  2 new tests cover the rejection at both per-company and
  `_system` boundaries.
- **Low (wave 30)** — `Reindex` now mirrors the writer-side
  `Company.AuditLog.entry_company/1` slug discipline at the
  read path. Phase 1/2/3 replay was inserting JSONL-supplied
  `company:` and `agent:` fields verbatim into the SQLite
  mirrors. Hand-edited or backup-restored JSONL with `company:
  "../../etc"` or `agent: "../etc"` would have written garbage
  values into `audit_events.company`,
  `tasks_approval_state.agent_slug`, and
  `budgets.{company_slug,agent_slug}`. Two helpers added:
  `safe_company_slug/2` (validates against
  `Actions.Support.valid_slug?/1`, falls back to the on-disk
  dirname; allows `_system`) and `safe_agent_slug/1` (returns
  nil on non-slug, callers skip the row). Phase 3 also rejects
  `company: "_system"` since budget events are strictly
  per-company. 6 new tests across the three projections.

### Fixed

- `test/glorbo/filesystem/watcher_test.exs` W6 (GEP-28
  proposals broadcast) intermittent flake. `start_watcher/1`
  now pre-creates `proposals/` alongside the other watched
  subdirs so the inotify watch is attached during
  `wait_until_armed!`'s probe window instead of racing
  the W6 file write. Reproducer was `mix test --seed 0`
  with the wave-30 module ordering: arm-probe completes,
  W6 mkdir's `proposals/`, file write fires before the new
  dir's watch attaches, `assert_receive` times out at 2s.
  10 isolation runs + 3 full-watcher-suite runs + 2 full-mix-test
  runs at fixed seeds 0 and 999 all green post-fix.

## [0.12.0] — 2026-04-26

Same-day minor cut. Lands GEP-34 (Reindex v2) end-to-end and
makes `glorbo.db` fully derivable from disk for the first
time. The CLAUDE.md load-bearing invariant — "SQLite is
derived and must be rebuildable from disk via `glorbo
reindex`" — was previously aspirational for three tables;
this release makes it true for all of them.

### Added — GEP-34 phases 1–3 (Reindex v2)

`Glorbo.Filesystem.Reindex.run/1` now rebuilds three derived
tables from the on-disk audit JSONL during a full reindex
pass. Result map gains three new counts:
`audit_events`, `tasks_approval_state`, `budgets`.

- **`audit_events`** is rebuilt from
  `companies/<co>/audit/<YYYY-MM>.jsonl` and
  `<base>/audit/_system/<YYYY-MM>.jsonl`. Lines are streamed
  via `File.stream!([], :line)`, JSON-decoded, batched 500
  rows per `Repo.insert_all`. Malformed and oversize
  (> 64 KiB) lines are skipped with a warning so reindex
  never crashes on a bad audit entry.
- **`tasks_approval_state`** is rebuilt by folding
  `approval.{requested,granted,denied}` lines chronologically
  per `task_path`. Resolutions without a matching `requested`
  line synthesize a row, so retention-truncated audit logs
  still surface the resolution. Sentinel-retention question
  decided audit-only (GEP-34 D4): the gate continues to
  delete the awaiting sentinel on resolution; no resolved
  sentinel is written.
- **`budgets`** is rebuilt by summing `budget.usage` lines
  per `{company_slug, agent_slug, year_month}`, with
  `year_month` derived via the writer's own
  `Budget.Ledger.month_bucket/1` (GEP-34 D7) so replay rows
  match live rows bind-for-bind. The `alerts_fired` MapSet
  the spec worried about is GenServer state in
  `Company.BudgetTracker`, not a column on the schema, and
  is already rehydrated from `alerts/*.md` on tracker boot.

GEP-34 status: Draft → Implemented. Decision log carries
D1–D7.

### Fixed

- `rebuild_audit_events/1` now reads `_system` events from
  `<base>/audit/_system/*.jsonl` (writer's canonical
  subdirectory) instead of `<base>/audit/*.jsonl` (flat).
  Production system events were being silently skipped on
  every reindex. Pre-1.0 behavioural change with no compat
  shim — the writer never emitted flat-path files.

### Tests

24 new tests across `test/glorbo/filesystem/reindex_test.exs`
covering each phase's happy path, idempotency, edge cases
(missing-request synthesis, multi-month splits, multi-agent
isolation, cross-company isolation, oversized-line cap, and
the `_system` subdirectory fix).

## [0.11.3] — 2026-04-26

Same-day security/quality patch. Wave 28 closes 4 more
findings (1 medium, 3 low) plus two CI test fixes. Cumulative
**94 findings closed across 28 waves** since the 2026-04-22
security import.

### Security (wave 28)

Defense-in-depth hardenings caught by manual sweep (codex
scans v8 + v8b both hung past 30 min and were abandoned).

- **Medium** — `Actions.Reviews.atomic_write/2` and
  `FileSpec.Formatter.atomic_write/2` switched from
  `unique_integer`-suffixed temp files to
  `crypto.strong_rand_bytes(8)` + `:file.open([:exclusive])`.
  Reviews writes peer-review request sentinels into agent-RW
  inbox dirs; Formatter operates on agent-RW project / agent
  markdown.
- **Low** — `GlorboWeb.Router` `:browser` pipeline now sets an
  explicit Content-Security-Policy header
  (`default-src 'self'`, `script-src 'self'`,
  `frame-ancestors 'none'`, etc.) via the
  `put_secure_browser_headers/2` map argument. Defense-in-depth
  on top of `HtmlSanitizeEx`. Locked in by
  `test/glorbo_web/security_headers_test.exs`.
- **Low** — `CLI.Scaffold.Skill.scaffold_default/3` and
  `scaffold_from_template/4` refuse symlinked
  `companies/<co>/skills/` ancestors before `mkdir_p`. Per
  GEP-22 the skills dir is RW for agents holding
  `skills:install`, so an agent compromise could redirect
  Director-side scaffolds.
- **Low** — `Backup.write_archive/2` switched from
  `unique_integer`-suffixed tempfile to
  `crypto.strong_rand_bytes(8)` suffix. Backup tarballs
  include `config.md` (carries `secret_key_base`), so
  predictable temp names in a user-chosen output directory
  (e.g. `/tmp` on a shared box) were attacker-plantable as
  symlinks before chmod 0600 sealed the file.

### Fixed

- `test/glorbo/actions/channels_test.exs` history-debounce
  sleep windows bumped 150ms → 1000ms after the v0.11.2 release
  CI run flaked on the slow GHA runner (the post-`Channels.create`
  commit hadn't landed in 150ms; head was still
  `glorbo: initial history import`). Matches the
  WatcherBridge / Tx debounce-flake remediation pattern.
- `test/glorbo/sandbox/bwrap_test.exs` switched from
  `async: true` to `async: false`. Test "B13: prompt tempfile
  is cleaned up after invocation (no leak)" enumerates `/tmp`
  for `glorbo_bwrap_prompt_*` files before + after a
  `Bwrap.start/2` call; with concurrent siblings B11/B12 also
  creating tempfiles, B13's after-snapshot was picking up an
  in-flight sibling's tempfile and reporting a false leak.

### Docs

- GEP-44 (visual-regression baselines) bumped Draft →
  Implemented. Tier-2 + Tier-3 baselines landed; CI gate is
  live as informational `continue-on-error` x86_64 step.
- GEP-33 (git history layer) README index entry corrected
  from "Draft" to "Implemented" (file frontmatter was already
  Implemented; index drifted).
- `docs/testing/threatmodel.md` updated with the wave 28
  closure log.

## [0.11.2] — 2026-04-26

Same-day security patch. Two more Codex scans (waves 26–27)
surfaced and closed **11 findings** end-to-end (2 high, 6
medium, 3 low) — primarily extending the wave-25 symlinked-
ancestor + bounded-read patterns to surfaces that earlier
sweeps did not visit.

### Security

- **High** — Project-writable directory symlinks could redirect
  host task writes across companies. An agent with
  `projects:write:<p>` could replace `projects/<p>/tasks` with
  a symlink and have outbox-routed tasks land in another
  company's tree. `Company.Router.handle_outbox_task`,
  `Actions.Tasks.do_next_task_id`, and
  `Actions.Tasks.build_trash_dest` now refuse symlinked
  ancestors before mkdir_p / exclusive_write / rename.
- **High** — IPv4-mapped IPv6 addresses (`::ffff:127.0.0.1`)
  bypassed the proxy private-address filter. Now extract the
  embedded IPv4 octets and recheck against the IPv4 ruleset.
- **Medium** — `TaskDefinition.read_file/1` slurped full
  agent-RW task files before `Frontmatter.parse/1` capped at
  10 MiB. Routed through `AgentWritableFile.read/1`;
  preserved the `:size_limit_exceeded` error contract.
- **Medium** — `PathRequestGate.archive_request/3` walked into
  `agents/<slug>/state/path-request-archive` without symlink
  refusal. Now lstat-refuses symlinked ancestors.
- **Medium** — `Actions.Agents` workspace writers had a
  lstat→write TOCTOU. `create_workspace_file` now uses O_EXCL
  create; `write_workspace_file` writes through a random-suffix
  exclusive temp + atomic rename; `trash_workspace_file`
  refuses symlinked `agents/<slug>/history/deleted` ancestors.
- **Medium** — Inbox delivery and `@mention` writes did not
  refuse symlinked ancestors. Added `any_symlink_in_path?/1`
  guards to `Actions.write_mention`,
  `Actions.Inbox.deliver_task_assignment`,
  `Company.Router.perform_routing({:agent, _}, …)` and
  `do_write_mention`, and `PathRequestGate.notify_agent_denied`.
- **Medium** — `Search.scan_audit/2` slurped each monthly audit
  JSONL into BEAM memory before applying the 500-row limit.
  Switched to `File.stream!([], :line)` + rolling-window reduce.
- **Low** — `Agent.Parser.validate_models_aliases` and
  `parse_host_list` raised `Protocol.UndefinedError` on
  nested-map YAML via `to_string/1`. Now refuse non-binary
  keys/values up front and return structured validation errors.
- **Low** — Proposals reads (`Company.Proposals.read_one`,
  MCP `GetProposal`/`ListProposals.load`) used raw
  `File.read/1` on agent-RW `proposals/`. Routed through
  `AgentWritableFile.read/1`.
- **Low** — `Chat.Rotation` used predictable
  `<channel>.md.rotate.tmp` and plain `mkdir_p` on
  `archive/<channel>`. Random-suffix exclusive temp +
  symlinked-ancestor refusal for both live and archive paths.

Cumulative: 90 findings closed across 27 waves since the
2026-04-22 import.

## [0.11.1] — 2026-04-25

Same-day security patch. Two Codex security scans across waves
9–22 surfaced and closed **43 findings** end-to-end (1 high,
3 medium, 39 low) — the entire prior-import backlog plus 4
new findings from the post-sweep re-scan.

### Security

- **High** — `Glorbo.TaskDefinition.parse_file/2` followed
  symlinks under agent-RW `projects/*/tasks/*.md`. Cross-
  company task-content leak via MCP / LiveView surfaces was
  possible. Now lstat-gated.
- **Medium** — `Glorbo.Search.scan_tasks/2` Ctrl+K indexer
  used `File.stat` (follows links). Now lstat + 1 MiB cap.
- **Medium** — Router task-materialisation TOCTOU race
  (`ensure_regular_file_lstat` then `File.write`). Replaced
  with atomic `:file.open([:exclusive])` (O_EXCL).
- **Medium** — `Actions.Tasks.write_task_file/6` predictable
  tempfile name was attacker-guessable. Now uses
  `crypto.strong_rand_bytes` + exclusive open.
- **39 lows** closed across waves 9–21 — symlink-follow gaps,
  unbounded reads, type-coercion crashes, tempfile races, slug-
  validation gaps, UTF-8 unsafety, secret-leak masking, auth-
  gate bypasses. Threatmodel `## Open findings` block has the
  full per-wave log.

### Fixed

- `Glorbo.HomeHistory.WatcherBridge` test debounce-sleep window
  bumped to 1s for slow CI runners (Tx + retire flake parity).
- VR harness fixture-seed bug — `scripts/ui-baseline.sh` now
  uses `./glorbo` burrito subcommands rather than non-existent
  `mix glorbo.*` tasks.

### Added

- VR harness wired into `.github/workflows/ci.yml` as an
  informational `continue-on-error` gate. 16/18 LVs gated;
  `/health` + `/providers` skipped via `DIFF_SKIP` (env-
  dependent content).
- VR `scripts/package.json` with playwright + pngjs +
  pixelmatch for project-local node deps.
- VR baseline clip rect (top 30 / bottom 30) → 0.000–0.045%
  drift across 3 back-to-back local runs.

## [0.11.0] — 2026-04-25

Eleventh pre-1.0 minor. Quality-of-life cycle on top of v0.10.0:
the orchestrator now ships with a one-shot `glorbo install` verb
that writes a user-level systemd unit so you can keep Glorbo
running across shell sessions without juggling `glorbo up` /
`down` by hand. Visual-regression coverage rounded out to all
18 production LV routes.

### Added

- **`glorbo install` / `glorbo uninstall` — user-level systemd
  service.** Writes `~/.config/systemd/user/glorbo.service` (or
  `$XDG_CONFIG_HOME/...`) invoking `<self> serve` under
  `Type=simple` with `Restart=on-failure`, runs
  `systemctl --user daemon-reload`, then `enable --now` (skip with
  `--no-start`). `glorbo uninstall` disables + removes. Linux-only;
  on non-systemd hosts it returns exit 2 with a hint to use
  `glorbo serve` under your supervisor of choice. `--force`
  overwrites an existing unit. `~/.glorbo/` is never touched.
- **Tier-3 visual-regression baselines.** Five new VR baselines
  cover task_chain, benchmarks, brain_dump, skills, and project
  LVs. `scripts/ui-baseline.sh` PAGES grew 13 → 18 entries.
  `/benchmarks/:run_id` deferred until canonical fixture runs land.

### Fixed

- **CI flake in concurrent-tx test.** `Glorbo.HomeHistory.TxTest`'s
  "two open txs don't collide" case raced the §6.1 debounce
  auto-flush on slow runners; tx_b's auto-flush fired during
  tx_a's `do_commit` and the manual flush returned `:unknown_tx`.
  Pinned `debounce_ms: 60_000` for that test so neither timer
  can fire mid-test (auto-flush is exercised separately).

## [0.10.0] — 2026-04-25

Tenth pre-1.0 minor. **GEP-33 git history layer fully implemented +
the BLA-importer / browser-UAT unblock.** The opt-in
`~/.glorbo/.git/` repo now captures every host-side write through
the writer + watcher pipeline. Five GEP shifts this cycle: GEP-33
flipped to Implemented (Phases 2 + 3 + 4 on top of v0.9.0's Phase-1
ship); Phase-4 `glorbo history show / diff / restore` verbs landed.

### Added

- **GEP-33 Phase 2** — `HomeHistory.commit_marked/3` synchronous
  primitive + `HomeHistory.Tx` GenServer with §6.1 debounce
  coalescer + `with_tx/3` convenience wrapper. Wired into 8
  writer surfaces: `Companies.update`, `Channels.{create,
  archive}`, `Tasks.{create, trash, archive_to_history, reassign,
  record_peer_review_verdict}`, `Projects.{ensure_stub, update}`,
  `Goals.add_goal`, `Proposals.flip`, `BrainDump.capture`,
  `Agents.retire`, plus the Router-side agent flows
  (`outbox_task` / `outbox_memory_write` / `outbox_proposal`).
- **GEP-33 Phase 3** — `HomeHistory.WatcherBridge` GenServer
  observes existing per-company watcher events and emits
  `External` provenance commits for manual filesystem edits.
- **GEP-33 Phase 4** — Director-facing CLI verbs: `glorbo history
  show <rev>`, `glorbo history diff <rev> [<rev2>] [--path P]`,
  `glorbo history restore <rev> <path> [--yes]`. Restore is
  dry-run-by-default; `--yes` performs the actual write.
- **Browser UAT harness unblocked.** Playwright MCP now works
  inside an Ubuntu distrobox (`npx playwright install chrome` +
  `apt-get install build-essential` for muontrap NIF).
  CLAUDE.md + `docs/testing/uat.md` updated to document the
  distrobox path as preferred over the legacy Bazzite host
  workaround.

### Changed

- **`commit_marked/3` deletion-capable.** Switched to
  `git add -A -- <pathspec>` so writers that move or remove
  tracked files (e.g., `Tasks.trash`, `Channels.archive`,
  `Agents.retire`) commit deletions natively. Per GEP-33 §7 the
  prohibition is on whole-repo `-A`; the explicit-pathspec form
  preserves the bulk-stage rule.
- **`agents/.archive/` excluded** from tracked scope. Retired
  agents' frozen subtrees no longer balloon the history repo.

### Fixed

- **`glorbo history restore` `--yes` semantics were inverted.**
  Default is now dry-run; `--yes` performs the actual restore.
  Surfaced by manual UAT against the live `~/.glorbo/`.
- **`validate_rev/1` + `validate_path/1` defense-in-depth.**
  Both now reject control characters, NUL bytes, tabs, and
  newlines in addition to the prior bare-space + leading-`-`
  + `..`-traversal guards. Matches the docstring's stated
  scope ("catches hostile rev strings, arbitrary shell
  injection").

## [0.9.0] — 2026-04-25

Ninth pre-1.0 minor. **Crown-jewels phase 2 + autonomy
quality + opt-in git history + paperclip-importer hardening.**
Closes the GEP-41 half-feature gap that v0.8.0 left open
(reviewer auto-dispatcher) and ships the first slice of GEP-33
(opt-in git history layer for `~/.glorbo/`). Five GEP shifts
this cycle: GEP-42 drafted/accepted/implemented; GEP-43 pinned
as Placeholder for the eventual SQLite→ETS pivot; GEP-33 Phase
1 shipped with phases 2–4 deferred; GEP-40 dashboard surface
for `done_when:` finally rendered; GEP-23 `egress.kbps_cap`
recorded as won't-fix.

### Changed

- **`FileSpec.Formatter`** now emits multi-line frontmatter strings
  as YAML `|` (clip) block scalars instead of double-quoted scalars
  with literal `\n`. Applies both to top-level fields (`done_when:`,
  future paragraph fields) and to values inside list-of-maps items
  (`handoff_chain[].reason`). Idempotent across round-trips; a
  string written without a trailing newline becomes `:changed` once
  (gains the canonical single trailing `\n`) then `:unchanged`
  forever after.
- **`glorbo` help text** reads version from the loaded application
  spec rather than a hardcoded string. Eight version bumps had
  drifted "Glorbo 0.0.4" while `mix.exs` sat at 0.8.0; future
  bumps are self-updating via `:application.get_key(:glorbo,
  :vsn)`.

### Added

- **GEP-42 — reviewer auto-dispatcher.** Closes the GEP-41
  half-feature gap. When `Glorbo.Approvals.Gate` first observes
  that a task needs peer review, `Glorbo.Actions.Reviews.
  request_peer_review/4` drops a `peer-review-request/v1`
  sentinel into the configured reviewer's inbox; the existing
  inotify wake pipeline does the rest. Verdict-side cleanup
  (`record_peer_review_verdict/5`) deletes the request sentinel
  on every verdict and, on `revise`, drops a
  `peer-review-feedback/v1` sentinel into the original
  assignee's inbox so the fix-and-resubmit loop fires
  automatically. Missing-reviewer fails loud (D5) — the gate's
  MapSet dedupe is marked only when dispatch succeeds, so the
  next observation retries; an attacker who deletes the
  reviewer's `AGENT.md` can't silently bypass review. Two new
  FileSpec modules + auto-generated doc pages under
  `docs/file-formats/`. 10 new tests.
- **GEP-43 (Placeholder) — ETS-first derived state with
  on-disk snapshots for cold boot.** Pinned during the
  SQLite-vs-ETS sidebar that surfaced while diagnosing the
  Burrito local-build issue. Hard prerequisite is GEP-34
  (make budgets + approvals fully derivable from audit log)
  before SQLite can be removed safely. Most decisions
  intentionally open.
- **GEP-40 — `done_when:` editable from the dashboard.** The
  shared `TaskDetailForm` component (used by both `TaskLive`
  and `KanbanLive`'s shelf overlay) now renders a textarea
  for the agent-facing definition-of-done. Empty string clears
  the field via `TaskDefinition.write_frontmatter/2`'s drop-
  empty-keys rule; multi-line content survives the round-trip
  because the formatter emits `|` block scalars (also this
  cycle). Closes the GEP-40 dashboard-surfacing gap — before
  this, `done_when:` could be set in the file but was invisible
  to Directors.
- **Agent autonomy — broader retry coverage.**
  `Glorbo.Agent.Dispatch` now retries `:reply_file_empty`
  (one-turn model truncation) and `:provider_unavailable`
  (transient registry/network flap) in addition to the
  existing `:timeout` and `:reply_file_missing`. Real
  outages still exhaust `max_retries` quickly and surface
  through `LoopDetector`'s stuck sentinel; cheap to retry,
  expensive to ping the Director. Config-class errors
  (`:emergency_stopped`, `:prompt_too_large`,
  `:unknown_provider`, `:untracked_disallowed`,
  `:symlink_loop`) stay non-retryable.
- **GEP-33 Phase 1 — git history layer (opt-in).** New
  `Glorbo.HomeHistory` module + `glorbo history {init, status,
  log}` CLI verb. `init` bootstraps `~/.glorbo/.git/` with the
  GEP-33 §3 tracked-scope `.gitignore` and writes the root
  commit; `status` wraps `git status --porcelain`; `log` reads
  recent commits via record-separator format. A `tracked?/2`
  predicate mirrors the policy without shelling out. Phase 2
  (marked commits from write surfaces) and Phase 3 (watcher
  fallback) follow; `show`/`diff`/`restore` are deferred to
  Phase 4. GEP-33 stays Draft — Implemented when Phases 2 + 3
  land.

### Fixed

- **`PortabilityTest`** asserted `companies/.../agents/ceo/agent.md`
  (lowercase) but the canonical filename per `Glorbo.Agent.FileLayout`
  is `AGENT.md` (GEP-15 ALLCAPS). On case-sensitive filesystems
  (Linux) the assertion failed; corrected to match the convention.
- **`ApprovalGateE2ETest`** `write_task` helper omitted required
  `kind: task/v1` and `id:` fields (GEP-25 R26.2b cut). Added them
  as overridable defaults so existing call sites stay terse.
- **`InotifyToBwrapHappyPathTest`** had three independent stale
  assertions: (a) the `run_fun` signature pattern matched
  `(argv, env, ^spec, ctx)` but the dispatcher's actual contract is
  `(argv, env, bwrap_opts, run_opts_map)`; (b) `ctx.network_policy
  == :none` predates the GEP-23 D1 enum rename to `:loopback`;
  (c) `Map.has_key?(env, "CLAUDE_CONFIG_DIR")` predates the move to
  bind-based CLI auth redirection (`cli_auth_binds` carries the
  `~/.claude` mount; no env var). Realigned with the current shape;
  also stubs `audit_fun` since the test doesn't start a per-company
  AuditLog GenServer.
- **`InotifyToBwrapHappyPathTest`** "suite-pollution" was an
  inotify watch-attachment race: `inotifywait` attaches kernel
  watches asynchronously after `FileSystem.start_link/1` returns;
  scheduler load from preceding tests made the file write win the
  race against attachment. 250ms `Process.sleep` after
  `Watcher.start_link/1` closes the race deterministically.
- **`SearchControllerTest` + `AuditExportControllerTest`** read
  `Application.fetch_env!(:glorbo, :glorbo_base)` in setup but
  `ConnCase` doesn't put it there (only `LiveCase` does). Each
  case now owns + restores its own tmp root via
  `Glorbo.Test.TmpGlorboHome.setup/0` so order-dependent state
  from other test files doesn't leak in.
- **`OpencodeLmstudioLiveTest`** dropped the redundant
  `:integration` moduletag (ExUnit's `--include` overrides
  `--exclude` when tags overlap, so `:integration` defeated the
  `:live_model` exclusion). Test reachable solely via `--include
  live_model`. Preflight tightened to a `/v1/chat/completions`
  probe so listed-but-not-loaded models surface honestly.
  Fixture also gained the GEP-25 R26.2b required `kind:
  agent/v1` + `kind: company/v1` frontmatter.
- **`glorbo import paperclip`** wraps copied `HEARTBEAT.md` +
  `SOUL.md` files with `kind: agent-heartbeat/v1` /
  `kind: agent-soul/v1` frontmatter on copy. Source paperclip
  files have no frontmatter, but Glorbo's GEP-25 R26.2b atomic
  cut requires a `kind:` discriminator on every recognised
  file; without the wrap, `glorbo validate` errored on every
  imported agent. Surfaced by the v0.9.0 UAT benchmark vs
  paperclip data — see
  `docs/testing/benchmark-vs-paperclip-2026-04-25.md`.
- **`Glorbo.FileSpec.AgentMd` + `CompanyMd`** added
  `imported_from` and `imported_company` to the optional-key
  allowlist. The importer was already writing them (so
  Directors can grep paperclip-derived agents) but they
  surfaced as warnings on every import.

### GEPs

- **GEP-42 — reviewer auto-dispatcher (Implemented).** Drafted,
  Accepted, and Implemented in this cycle. `Glorbo.Actions.
  Reviews` is the new write seam; the gate calls
  `request_peer_review/4` on the same edge as the existing
  `peer_review.requested` audit. Two new FileSpec modules
  (`peer-review-request/v1`, `peer-review-feedback/v1`).
  Verdict-side cleanup deletes the request sentinel on every
  verdict; `revise` drops a feedback sentinel into the
  original assignee's inbox so the fix-and-resubmit loop fires
  automatically. Missing-reviewer fails loud (D5).
- **GEP-43 — ETS-first derived state with on-disk snapshots
  (Placeholder).** Pinned during the SQLite-vs-ETS sidebar
  that surfaced while diagnosing the Burrito local-build
  issue. Hard prerequisite is GEP-34 (make budgets +
  approvals fully derivable from audit log) before SQLite can
  be removed safely. Most decisions intentionally open.
- **GEP-33 — git history layer for `~/.glorbo/` (Phase 1
  shipped, GEP stays Draft).** `Glorbo.HomeHistory` +
  `glorbo history {init, status, log}` CLI verb. Opt-in;
  `init` writes the GEP-33 §3 tracked-scope `.gitignore` and
  the root commit. Phase 2 (marked commits from write
  surfaces) and Phase 3 (watcher fallback) follow; GEP-33
  flips to Implemented when those land.
- **GEP-23 `egress.kbps_cap` — won't-fix.** Maintainer-recorded
  decline (2026-04-25): kbps shaping is overkill for Glorbo's
  single-user / single-host posture. The spec line stays in §Proxy
  daemon §7 as a documented opt-out but no implementation path is
  planned. GEP-23 stays Implemented.
- **GEP-40 — `done_when:` editor surfaced in the dashboard.**
  Phase-2 polish on the Implemented GEP. History note added.
- **GEP-41 — history note added** pointing at GEP-42 closing
  the auto-dispatcher gap that v0.8.0's phase-1 left open.

## [0.8.0] — 2026-04-25

Eighth pre-1.0 minor. **Crown-jewels phase 1.** Maintainer
pivot on 2026-04-24: "pivot to crown jewels now and defer
glorbo shell until this is done." Scope:

- **GEP-40** task chain observability (`done_when:`,
  `handoff_chain:`, `severity:` + `peer_review_required:`
  frontmatter + chain audit view LiveView).
- **GEP-41** agent peer-review gate (severity-based +
  opt-in trigger, CritiqueOps as default reviewer,
  verdict-based routing).
- `Glorbo.Actions` write-seam carve-out (GEP-36 absorbing
  GEP-38) rides alongside since both crown-jewel GEPs build
  on it.

**Deferred behind v0.8.0:** `glorbo shell` implementation
(GEP-37 stays Accepted; first cut of the shell now queued
for v0.9.0 or later). Template propagation to the remaining
5 agent roles landed across Round L (cairn-style + handoff
to ceo/editor/researcher/provenance-auditor — CritiqueOps
had it from Round J) and Round O (peer-review opt-in
paragraph to all 5 non-reviewer roles), so no template work
is left outstanding for v0.8.0.

### Added

- **GEP-36 Implemented — `Glorbo.Actions.*` single-write-channel
  carve-out complete.** Eight resource-organised modules
  (`Glorbo.Actions.Tasks` / `.Companies` / `.Projects` /
  `.Audit` / `.Channels` / `.Inbox` / `.Attachments` /
  `.Agents`) now own every filesystem mutation the Director-
  facing LiveViews can make; each applies the GEP-36 contract
  (slug validation, atomic write, threatmodel-appropriate
  symlink/contract-file guards, audit emission) before the
  `File.*` call lands. Shared helpers consolidated in
  `Glorbo.Actions.Support`. New Credo custom check
  `Glorbo.Credo.Check.RawFilesystemWriteInLive` rejects any raw
  `File.write/rename/mkdir_p` under `lib/glorbo_web/live/`.
  Allowlist is empty — the ratchet is closed. Companion tests
  cover each module's happy path + guards; session log:
  `docs/sessions/2026-04-24-autonomous-round.md`.
- **`Glorbo.Search` indexes task `schedule:` frontmatter.**
  Ctrl+K palette now substring-matches schedule values; query
  `daily` surfaces every task with `schedule: every day` or
  similar. Label decorates with `(<schedule>)` when a task has
  one, so the director sees *why* a hit surfaced. Schedule
  matches score at 35 (below title/id so task names still win
  ties). 5 new tests.
- **Kanban new-task form gains a `model` combobox** (GEP-32
  phase 4 follow-up). Selecting an assignee pre-fills a
  `<datalist>` of cached model IDs for that agent's provider;
  the chosen model is persisted into task frontmatter.
  Dispatch already honours `task.model` per threatmodel M10.
  5 new tests.
- **R26.2b: per-kind golden fixtures** for every FileSpec kind.
  12 new minimal_valid fixtures (sentinel-stuck,
  sentinel-resolution, task-comments, inbox-message,
  inbox-archive, audit-event, agent-memory-index,
  benchmark-run, config, emergency-stop, proposal,
  path-request); all 24 kinds now covered by
  `GoldenFixturesTest`.
- **`docs/project-profile.md`** — declarative statement of
  Glorbo's stances (risk tolerance, security posture, quality
  bar, contribution norms, tech-debt stance, pre-release
  gate). Introduced by the cairn workflow kit; populated
  from maintainer's answers on 2026-04-24. Consumed by
  autonomous rounds and the `cairn-review-phase` skill.
- **GEP-37 Draft** — `glorbo shell` interactive terminal
  session for the Director. Pure Elixir on
  [`pcharbon70/term_ui`](https://github.com/pcharbon70/term_ui);
  Emacs-style keybindings; drop-in parity with the Phoenix
  dashboard.
- **GEP-38 Placeholder** — frontend adapter contracts (one
  internal service layer, N frontends); likely to be absorbed
  into GEP-36's atomic Actions carve-out when that lands.
- **GEP-39 Placeholder** — configurable TUI keybinding
  schemes (Emacs default / Vim / VS Code); implementation
  gated on demand.
- **Engineer agent template** rewritten cairn-style
  (commit `fe658ee`): governing principles inline, L3
  autonomy can/cannot, anti-slop discipline, handoff
  return-path, structured reply. Reference impl; propagated
  across the 4 remaining non-CritiqueOps roles in Round L.
- **Peer-review opt-in paragraph** added to engineer, ceo,
  editor, researcher, and provenance-auditor templates
  (GEP-41 D1 rollout item 5). Canonical verbatim language
  from GEP-41 plus a reminder that `peer_review_required`
  is append-only once flipped to `true` and that
  `severity: major|critical` auto-triggers the gate.
  CritiqueOps is the reviewer side and keeps its
  Round-J GEP-41 framing unchanged.
- **Chain audit view surfaces peer-review events**
  (`TaskChainLive`, GEP-41 rollout item 6). Renders
  `peer_review.requested` (from `Glorbo.Approvals.Gate`)
  and `task.peer_review.<verdict>` (from the reviewer's
  verdict-land path) in a dedicated `<details>` section
  alongside the existing reassign cross-reference. Detail
  row shows reviewer + severity on requested events and
  verdict + note on verdict events. 4 new tests.
- **GEP-40 Implemented — task chain observability.**
  Frontmatter schema (`done_when:`, `handoff_chain:`,
  `requested_by:`, `severity:`, `peer_review_required:`)
  plus append-only enforcement at the parser, Router
  handoff-chain appender in `Actions.Tasks.assign/4`, and
  `GlorboWeb.TaskChainLive` at
  `/companies/:co/tasks/:task_id/chain` with drift
  detection. Phase-1 rollout complete within v0.8.0's
  crown-jewels cut.
- **GEP-41 Implemented — agent peer-review gate.**
  Severity-based automatic trigger (`major|critical` →
  auto-flip `peer_review_required: true`) + author opt-in;
  CritiqueOps as default reviewer; three-way verdict
  (approve/revise/block); append-only
  `peer_review_required` flag; gate emits
  `peer_review.requested` audit when reviewer-blocked;
  chain view surfaces the full review lifecycle inline.
  Phase-1 rollout complete (items 1–7 across rounds J/K/
  N/O/P). Deferred to a future GEP-41 phase-3: reviewer
  auto-dispatcher (inbox delivery, sentinel dedupe,
  cadence, retry, reviewer-absent fallback).
- **`docs/project-profile.md`** extended with "The crown
  jewels — non-negotiable quality axes" section codifying
  the four axes (inter-agent, director, deliverable
  quality, anti-failure) as project stance.
- **`docs/research/crown-jewels.md`** — research + planning
  doc backing the GEP-40/41 arc. Infrastructure inventory,
  quality dimensions, external reference patterns,
  gap analysis, ranked interventions.

### Changed

- **`Gep.Validator` skips required-sections check for
  `Placeholder` status.** Matches GEP-1's "low-bar parking
  spot" definition; GEP-34/35/36 Placeholders now pass where
  they had been failing. New regression test
  `Placeholder Standards GEP skips section validation`.
- **`FileSpec.Formatter.emit_list_item/2`** — pre-existing
  indent bug fixed for list-of-map frontmatter (surfaced by
  the path-request golden fixture). Continuation keys now
  align with first key instead of dash column. Two regression
  tests lock the canonical shape.
- **`CLAUDE.md` gains an explicit pre-version release gate** —
  doc-drift pass, graphify refresh, full test run, E2E UAT,
  security review, release-artefact flow. Formalises what
  had been habit.

### Fixed

Pre-release gate findings (UAT Round 8 + codex `review --base
v0.7.0`) closed before the tag:

- **Kanban review column renders `status: pending-approval`**
  (UAT Round 8 P9). `group_by_column/1` filter previously only
  matched `["pending", "approved", "denied"]`, so Gate-set
  tasks silently disappeared from the board until the Director
  explicitly flipped the status via the Inbox. Regression test
  added.
- **Peer-review verdict requires the configured reviewer**
  (codex P1). `Actions.Tasks.record_peer_review_verdict/5` now
  rejects any actor that isn't the task's `reviewer:` (or the
  default `"critiqueops"` when unset). Pre-fix, any agent with
  `tasks:update` could write `ACTIONS: verdict: approve` in
  its reply and self-clear peer review.
- **Task create + trash audits route through the company
  audit server** (codex P1). `emit_create_audit/6` +
  `emit_trash_audit/5` now call `Support.append_audit/3`
  instead of the raw `AuditLog.append/2` with the bare module
  atom — the prod via-tuple registration meant the raw call
  exited `:noproc` and the audit row was silently lost after
  the file write had already happened.
- **Peer-review `block` verdict sticks** (codex P2). New
  `Approvals.Gate` resolve-status clause short-circuits when
  `status: "denied" + peer_review_verdict: "block"`. The
  generic `denied` clause previously treated unmarked flips
  as agent self-approval attempts and reverted the status to
  `"awaiting"`, silently erasing a legitimate reviewer block.
- **Kanban new-task validates title before consuming uploads**
  (codex P2). Pre-fix, an invalid-title form still consumed
  uploads + emitted `attachment.upload` audit rows, leaving
  orphaned attachments under `attachments/<task_id>/` when
  `Actions.Tasks.create/4` subsequently rejected the title.
- **`Actions.Agents.trash_workspace_file/4` refuses contract
  files** (codex P2). `refuse_contract_write/1` now guards the
  trash path alongside the existing create/write paths;
  threatmodel H9 (AGENT.md / stdout.log protection) is
  enforced at the core, not only the UI.
- **`write_frontmatter/2` preserves task-level `model:` +
  `provider:` overrides** (codex P2). `@editor_keys` now
  includes both keys; pre-fix, any reassign / peer-review
  verdict / Kanban save silently stripped the overrides and
  dispatch fell back to the agent default (GEP-32 per-task
  override regressed).
- **Chain view reassign cross-reference reads `from`/`to`
  from audit `detail`** (codex P3). `AuditLog.append/2` nests
  any key outside `{ts, company, actor, action, target}` under
  `detail`; the view was reading top-level, so live
  `task.reassign` events rendered as blank arrows.

### GEPs

- GEP-36 actions-layer single-write-channel — **Implemented**.
- GEP-37 `glorbo shell` — **Draft** (renamed mid-round from
  `glorbo tui`; D2 flipped from custom-on-owl to term_ui
  after maintainer review).
- GEP-38 frontend adapter contracts — **Placeholder**.
- GEP-39 configurable TUI keybindings — **Placeholder**.
- GEP-40 task chain observability — **Implemented**.
- GEP-41 agent peer-review gate — **Implemented**
  (phase-1 rollout; phase-3 reviewer auto-dispatcher is
  future work).

## [0.7.0] — 2026-04-24

Seventh pre-1.0 minor. Two shipping flags over v0.6.0: GEP-23 Phase 5
per-dispatch `Proxy-Authorization` tokens (unblocks the long-deferred
`kbps_cap` follow-up) and a deep round of security + audit + symlink
hardening from codex + opencode + claude multi-reviewer sweeps
(rounds 2, 3, 4, 4b). Also ships the `GlorboWeb.Slug → Glorbo.Slug`
dep-direction fix as a BREAKING rename, and the GEP-23 D1 network
enum rename (`none|open → loopback|full`) as an atomic migration.
All 1394+ existing tests green plus 30+ regression tests locking
in the hardening. No new GEP flips this cycle — `GEP-23` was
already Implemented at v0.6.0; Phase 5 history entry dated
2026-04-24.

### Added — GEP-23 Phase 5: per-dispatch `Proxy-Authorization` tokens

- **[FEATURE]** `Glorbo.Network.ProxyTokens` is a new ETS-backed
  registry for ephemeral proxy credentials. `Glorbo.Agent.Dispatch`
  allocates a 32-byte url-safe token per dispatch, embeds it in the
  agent's `HTTPS_PROXY` URL (`http://<token>@127.0.0.1:<port>`),
  and revokes it when the dispatch ends. TTL = 2× dispatch timeout
  as a failsafe; a reaper GenServer sweeps expired entries every
  minute.
- **[FEATURE]** `Glorbo.Network.Proxy` parses `Proxy-Authorization:
  Basic <base64(token:)>` on the CONNECT head and resolves via
  `ProxyTokens.resolve/1`, tagging decisions with
  `{company, agent, dispatch_id}` for audit attribution. Raw tokens
  (no Basic wrapper) also accepted.
- **Backward-compat.** Absent or invalid tokens fall back to
  `:anonymous` and the existing company-scoped allowlist runs
  unchanged. Tokens are audit context, not authorisation — the
  allowlist remains the gate.
- **Unblocks `kbps_cap`.** The per-dispatch throttle in the GEP-23
  D-list was deferred because the proxy had no dispatch identifier
  to key a token bucket on. Now it does. Throttle itself is a
  separate follow-up.
- GEP-23 history entry + CHANGELOG + `Glorbo.Application`
  supervision tree updated; ProxyTokens starts before
  `CompanySupervisor` so the first dispatch can't race table
  creation.

### Security — round-4 batch 2

- **[MED]** `Glorbo.Approvals.Gate.resolve_denied/3` now checks the
  `history/tasks/` ancestor chain for symlinks before `File.mkdir_p!`
  + `File.rename`. A symlinked ancestor (planted by a prior path-
  grant or operator edit) would have aliased the archive target out
  of the company tree. Opencode round-3 flagged.
- **[MED]** `Glorbo.Network.SmartClassifier.private_ip?/1` coverage
  expanded to reject `0.0.0.0`, `::`, `::1` expanded form,
  `::ffff:<rfc1918>` IPv4-mapped IPv6, `fe80::/10` IPv6 link-local,
  and `fc00::/7` IPv6 ULA. Previously an agent could CONNECT to any
  of these shapes and reach the host network namespace through the
  proxy. Regression test enumerates all six new shapes.
- **[MED]** `Glorbo.Providers.NativeConfig.credentials_dir/1` now
  validates `GLORBO_CREDENTIALS_DIR` — must be absolute, no `..`,
  not a system path (`/etc`, `/usr`, `/bin`, `/sbin`, `/proc`,
  `/sys`, `/dev`). Previously `GLORBO_CREDENTIALS_DIR=/etc` would
  silently repoint credential resolution at `/etc/<provider>.toml`
  and start bind-mounting host config into the sandbox.

### Security — round-4 surgical fixes (codex+opencode round-3 triage)

- **[HIGH]** `Glorbo.PathRequestGate.write_pending_sentinel/4` now
  quotes the agent-authored `reason:` field through
  `FrontmatterWriter.yaml_scalar/1`. A newline or `:` in the reason
  previously broke the sentinel YAML or injected a top-level key
  the Director-facing dashboard reads. Codex round-3 flag.
- **[HIGH]** `Glorbo.PathRequestGate.sandbox_path_for/1` disambiguates
  `/external/<hash8>-<basename>` so two approved paths with matching
  basenames (`/tmp/a/config.json` + `/etc/config.json`) no longer
  shadow each other at bwrap mount time. 8-char SHA-256 prefix
  on the full host_path is enough for disambiguation without
  making the sandbox path opaque.
- **[HIGH]** `Glorbo.Sandbox.Bwrap.approved_path_flags/1` now asserts
  every grant's `host_path` is absolute + `..`-free, and every
  `sandbox_path` lives under `/external/` + `..`-free. PathRequestGate
  validates these on approval, but the argv slot is load-bearing
  (a rogue `../` would mount at a different scope). Raises
  `ArgumentError` on drift.
- **[HIGH]** `GlorboWeb.KanbanLive` `kanban:move` now refuses to
  flip a task with `requires_approval: director` to `done` or
  `in-progress` unless the task is already `approved`.
  Previously drag-to-done silently skipped the Director approval
  workflow. New regression test plus a seeded plain-task fixture
  for the happy path.
- **[MED]** `GlorboWeb.Actions.write_mention/8` and
  `GlorboWeb.KanbanLive.do_notify_assignee/5` now `lstat`-guard the
  target inbox file. Inbox is `--ro-bind` to the mentioned agent,
  so the agent can't plant a symlink, but a future path grant or
  operator tool could; defense-in-depth refuses to follow one.
  On rejection, logs a warning and skips the write rather than
  crashing the whole Director action.

### Changed — docs quality pass (round-3 drift sweep)

Drift caught by codex + opencode round-3 reviews against the code
that actually shipped. History in frozen decision logs (GEP-5,
GEP-31, GEP-32) left alone — those are time-stamped records, not
live claims.

- `CLAUDE.md §Project status` bumped v0.3.0 → v0.6.0 (was stale
  across three release cycles).
- `docs/DESIGN.md §Network policy` renamed enum to
  `loopback | proxy | full` (GEP-23 D1 shipped months ago). Same
  rename in the §Security summary. Also updated the bwrap baseline
  flag list to drop the `-try` suffix and add `--clearenv` the
  round-1/3 sweeps actually shipped.
- `docs/DESIGN.md §Permissions` example updated: dropped
  `agents:list` (rejected at parse since round-3) and
  `proposals:write:*` (replaced by `proposals:propose:*` /
  `proposals:decide:*` in GEP-28). Kernel-mount table updated
  to match.
- `docs/geps/0010-agent-and-skill-templates.md` template dropped
  `agents:list` the runtime now rejects.
- `docs/geps/0028-agent-created-proposals.md` body line that said
  "This GEP is Draft" updated — frontmatter flipped to Implemented
  long ago; the stale body line was misleading to a first-time
  reader.

### Security — harness + dispatcher TOCTOU hardening

- **[HIGH]** `Glorbo.CLI.Harness.Tools.resolve_tool_path/2` now
  refuses paths whose expansion escapes the workspace directory.
  Bwrap mount scope is the primary boundary, but the harness tool
  resolver runs pre-bwrap on some paths; a bare
  `read_file("/etc/passwd")` passing absolute paths through was a
  defense-in-depth miss. Raises `ArgumentError`, caught by
  `execute/3` and surfaced as a structured
  `{"error": "path_escapes_workspace"}` tool payload.
- **[MED]** `Glorbo.CLI.Dispatcher.do_read_reply/3` previously
  `lstat`ed the reply path, then `File.stat`ed it again for the
  size cap (follows symlinks), then `File.read`. Two separate
  stat calls were a TOCTOU window — collapsed to a single `lstat`
  whose size result flows through to the reader. No re-follow.

### Fixed — reindex correctness (codex + opencode round-3)

- **[HIGH]** `Glorbo.Filesystem.Reindex.upsert_agent/2` now resolves
  the parent company via the canonical `file_path`, not via the
  mutable `Company.name` frontmatter value. A prior version called
  `Repo.get_by(Company, name: <dir_slug>)` which cross-wired two
  companies with matching `name:` frontmatter, and broke whenever
  the directory slug diverged from the frontmatter name.
- **[HIGH]** `safe_markdown_files/1` adds an ancestor-chain symlink
  check on top of its lexical `Path.expand/1` escape test. Lexical
  expansion does not follow symlinks, so a symlinked directory
  under `companies/<co>/` could smuggle external content into the
  reindex. The new `Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?/1`
  helper walks the full ancestor chain with `File.lstat` and refuses
  any segment that's a symlink. Two new regression tests pin this.

### Security — scope validation + atomic_write hardening

- **[HIGH]** `Glorbo.Sandbox.PermissionMapper.permission_to_flags/2`
  now asserts `Glorbo.Slug.valid?/1` on every scope string that
  reaches `Path.join` (`projects:read:<name>`, `projects:write:<name>`,
  `chat:read:<channel>`, `tasks:update:<project>`). Scope should
  already be validated by `ACLMapper.parse_permission/1`; this is
  defense-in-depth — a future parser regression can't produce
  `--bind ../../etc /projects/etc` any more. Raises `ArgumentError`
  on drift so the dispatch fails loudly rather than silently
  mounting the wrong path.
- **[MED]** `Glorbo.Filesystem.FrontmatterWriter.atomic_write/2`
  now `lstat`-guards the target via `AgentWritableFile.ensure_writable/1`
  and uses a unique-per-call `.tmp-<monotonic>` staging name.
  Previously the literal `<file>.tmp` collided under concurrent
  writers to the same canonical file, and a symlinked target was
  followed through the `File.write` / `File.rename` pair.

### Fixed — audit-trail correctness (codex round-3)

- **[HIGH]** `Glorbo.EmergencyStop.engage/2` + `clear/2` default
  audit-fun previously called `AuditLog.append(entry)` which targets
  the bare `AuditLog` module name. In production that registered
  name has no pid — the call exited `:noproc` AFTER the sentinel
  was written. The Director's emergency-stop button crashed mid-
  action. Now uses `AuditLog.append_for(company, entry)`.
- **[HIGH]** `Glorbo.PathRequestGate.emit_audit/4` now stamps the
  entry with `company: state.company`. Without that key
  `AuditLog.normalize_entry/1` bucketed path-access events under the
  `_system` audit tree, invisible from the owning company's audit
  log. Caught + logged path replaces the silent `catch _, _ -> :ok`.
- **[MED]** `Glorbo.Company.Proposals.resolve_audit/1` was also
  targeting the bare module — calling `AuditLog.append(co, record)`
  with the company slug in the `server` slot. Approve/deny audits
  were silently dropped. Now delegates to `append_for/2` which
  resolves the per-company Registry target.

### Security — audit log append lstat guard

- **[MED]** `Glorbo.Company.AuditLog.handle_call({:append, _})` now
  `lstat`s the target JSONL before `File.write!(:append)`. Normally
  the audit/ tree is host-owned, but defense-in-depth: if anything
  ever bind-mounts audit/ into an agent sandbox (GEP-27 path grant
  misconfiguration, future feature), a pre-planted symlink could
  redirect the append. Absent file + regular file pass; anything
  else raises and is caught by the GenServer.

### Changed — `Glorbo.Filesystem.AgentWritableFile` seam

- **[MED]** New `Glorbo.Filesystem.AgentWritableFile` module is the
  canonical host-side lstat-before-touch helper. 7 modules
  (`Router`, `Actions`, `BrainDump`, `TaskComments`,
  `TaskDefinition`, `KanbanLive`) had local private copies with
  subtly different return shapes and names
  (`ensure_regular_file`, `_lstat`, `_for_write`, `_or_absent`,
  `read_agent_writable_file`). Everyone now delegates to
  `ensure_writable/1`, `ensure_regular/1`, or `read/1`. The
  extraction is the first step toward GEP-35's Router-split + host-
  write policy seam. Error shapes preserved at each caller site to
  avoid touching the case matches downstream.

### Changed — consolidated YAML scalar escaping + error-tuple hygiene

- **[MED]** `Glorbo.Filesystem.FrontmatterWriter.yaml_scalar/1` is
  now the single canonical YAML-scalar quoter. Four private
  copies (`TaskDefinition`, `Actions`, `Goals`, `KanbanLive`) were
  delegating through a subtly-different local regex each — a
  seam for escape-drift bugs. All now thin-delegate. The merged
  implementation is the stricter of the set: quotes on
  whitespace / reserved words / control chars, escapes
  `\\`/`"`/`\n`/`\r`/`\t`, strips remaining control bytes.
  Existing test that asserted bare-scalar output on a
  whitespace-containing string was updated to match the now-
  always-quoted emission — the unquoted form was valid YAML but
  the quoted form is strictly safer.
- **[MED]** Scrubbed `inspect(reason)` from two Elixir→caller
  error-tuple paths that could leak internal state:
  - `Glorbo.Restore.migrate/1` + `reindex/1` — downgrade the raw
    exit reason to `Logger.debug` and return a bare
    `{:error, :migrate_failed}` / `{:error, :reindex_failed}`.
  - `Glorbo.Agent.Parser.validate_provider/1`,
    `validate_network/3`, `validate_one_skill/1` — now return
    opaque shape tags (`:atom`, `:integer`, `:list`, etc.) when
    the value has the wrong type, instead of `inspect()`-ing the
    struct contents into the error tuple.

### Security — Restore transactional extract (rollback-safe)

- **[HIGH]** `Glorbo.Restore.extract/2` now unpacks archives into a
  sibling `<base>.restore-<ts>/` staging directory first, verifies
  symlink containment there, and only moves the contents into
  `base` on success. On rejection, the staging dir is wiped and
  `base` is untouched. The previous path extracted directly into
  `base` and, on verify-rejection, only removed top-level entries
  that didn't exist before — pre-existing files the archive
  overwrote were already lost (codex round-2). New regression test
  locks in: a malicious archive overwriting `config.md` + an
  escaping symlink leaves the original `config.md` byte-identical.

### Security — PathRequestGate symlink-segment check (GEP-27 compliance)

- **[HIGH]** `Glorbo.PathRequestGate.do_approve` now refuses to grant
  any path whose ancestor chain contains a symlink segment.
  Previously the validator only checked the path string lexically
  (absolute, no `..`, not under `/proc|/sys|/dev`), so an operator
  could approve `/home/user/data` only to have a pre-planted
  symlink elsewhere in the path resolve to `/etc` at bwrap bind
  time. GEP-27 §Approval validation §2 required this check — now it
  ships. 4 regression tests (`validate_no_symlink_segments/1`:
  regular file, absent path, direct-symlink refusal, ancestor-
  symlink refusal).

### Security — proxy hostname parser hardening

- **[HIGH]** `Glorbo.Network.Proxy` now rejects non-ASCII hostnames
  in CONNECT lines. A CONNECT containing an IDN-homograph hostname
  (e.g. `аpi.anthropic.com` — Cyrillic `а` + latin rest) would
  previously be `String.downcase`d and compared byte-for-byte
  against an ASCII allowlist; no match, but also not rejected at
  the parser layer. Full IDN support needs an `:idna` library
  and careful normalisation; until we take that on, ASCII-only
  hostnames are the safe stance.
- **[MED]** Trailing-dot FQDN form is now stripped before the
  allowlist lookup. `api.anthropic.com` and `api.anthropic.com.`
  resolve identically at DNS, but without normalisation the latter
  would miss an exact-match allowlist entry and fall through to the
  smart classifier. Two new regression tests P8a (non-ASCII refusal)
  and P8b (trailing-dot match) pin the contract.

### Changed — `GlorboWeb.Slug` → `Glorbo.Slug` (dependency direction)

- **[BREAKING]** Moved `GlorboWeb.Slug` to `Glorbo.Slug`.
  25 modules under `lib/glorbo/` (`Router`, `AgentServer`,
  `ACLMapper`, `TaskScheduler`, `CompanyBoot`, ...) were reaching
  up into the web layer for slug validation — a dep-direction
  smell codex + opencode both flagged. The module's contract is
  unchanged (same regex, same public `valid?/1` surface); only
  the name moved. Pre-1.0 atomic cut per the "no kid gloves"
  rule.

### Changed — dead-code + silent-failure cleanup (BREAKING for
### agent.md authors granting `agents:list`)

- **[HIGH]** `Glorbo.Security.ACLMapper.parse_permission/1` now
  rejects the `agents:list:*` permission with
  `{:error, :not_implemented}`. The permission has never had a
  kernel-layer implementation (D-12 staging-tmpfs was always
  deferred) and silently promising a capability the runtime
  doesn't enforce is a lie. The dead branch in
  `Glorbo.Sandbox.PermissionMapper` and the matching test were
  removed. The stock `ceo.md` template dropped the permission.
  Migration: audit any AGENT.md granting `agents:list:*` and
  switch to `agents:message:<target>` (the supported inter-agent
  discovery path).

### Fixed — silent-rescue logging

- **[HIGH]** `Glorbo.Company.Router.maybe_request_approval/7`
  previously swallowed every exception / exit from
  `Glorbo.Approvals.Gate.request_approval/2` with a bare
  `rescue _ -> :ok` / `catch _, _ -> :ok`. A Gate crash or
  process-lookup failure meant the Director never saw the
  approval request and the agent just silently idled. Now logs
  a warning naming the offending task + agent before returning.
- **[HIGH]** `Glorbo.Company.AuditLog.append_for/2` had the same
  blanket-rescue pattern, which produced invisible audit-trail
  gaps whenever the per-company `AuditLog` GenServer hiccupped.
  Now logs the failing entry's action + target on both rescue
  and exit.

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
[Unreleased]: https://github.com/foobarto/glorbo/compare/v0.26.0...HEAD
[0.26.0]: https://github.com/foobarto/glorbo/releases/tag/v0.26.0
[0.25.0]: https://github.com/foobarto/glorbo/releases/tag/v0.25.0
[0.24.0]: https://github.com/foobarto/glorbo/releases/tag/v0.24.0
[0.23.1]: https://github.com/foobarto/glorbo/releases/tag/v0.23.1
[0.23.0]: https://github.com/foobarto/glorbo/releases/tag/v0.23.0
[0.4.0]: https://github.com/foobarto/glorbo/releases/tag/v0.4.0
[0.3.0]: https://github.com/foobarto/glorbo/releases/tag/v0.3.0
[0.2.0]: https://github.com/foobarto/glorbo/releases/tag/v0.2.0
[0.1.0]: https://github.com/foobarto/glorbo/releases/tag/v0.1.0
[0.0.4]: https://github.com/foobarto/glorbo/releases/tag/v0.0.4
[0.0.3]: https://github.com/foobarto/glorbo/releases/tag/v0.0.3
[0.0.2]: https://github.com/foobarto/glorbo/releases/tag/v0.0.2
[0.0.1]: https://github.com/foobarto/glorbo/releases/tag/v0.0.1
