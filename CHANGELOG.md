# Changelog

All notable changes to Glorbo will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0 caveat: APIs, CLI flags, on-disk layout, and SQLite schema may
change between minor versions. Pin exact versions in downstream usage.

## [Unreleased]

### Milestone 01 — v0.0.1 CLI-agent runtime (in progress)

#### Phase 4 — LiveView Dashboard + Real-Time Channels (in progress)

- Phoenix LiveView on `:4000` with company overview, kanban board,
  agent detail with live `stdout.log` streaming, chat, approval
  queue, audit viewer, and system health, powered by Phoenix
  Channels + PubSub wired to inotify events.

### Planned

#### Phase 5 — CLI Completeness + Backup/Restore Portability

- Full CLI surface: `new`, `logs`, `console`, `migrate`, `backup`,
  `restore`, `doctor --fix`.
- Verified end-to-end portability: `backup` → `scp` → `restore` +
  `doctor --fix` reproduces a functional install on a fresh host.

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
[Unreleased]: https://github.com/foobarto/glorbo/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/foobarto/glorbo/releases/tag/v0.0.1
