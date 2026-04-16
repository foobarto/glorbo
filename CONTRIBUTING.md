# Contributing to Glorbo

Glorbo is a multi-agent AI orchestration platform with a
sandbox-as-trust-boundary architecture. Changes that touch that boundary
(permissions, bwrap, audit log, company isolation) need extra care —
see [`DESIGN.md`](./DESIGN.md) for the load-bearing invariants. This
document describes how to get set up, the workflow we use, and what we
look for in code review.

> **Project status:** pre-1.0 (v0.0.x). APIs, CLI flags, on-disk
> layout, and SQLite schema may change between minor versions. Pin to
> exact versions in downstream usage until v1.0.

## Before you start

- Read [`DESIGN.md`](./DESIGN.md) — it is authoritative when it
  conflicts with `README.md`.
- Read [`CLAUDE.md`](./CLAUDE.md) for the architectural guardrails.
- For security-sensitive reports, use [`SECURITY.md`](./SECURITY.md)
  — **do not open a public issue** for vulnerabilities.

## Development setup

Glorbo targets Linux (x86_64 and aarch64) and uses kernel-level
isolation primitives. Other hosts will not work for running agents.

Required toolchain (see [`.tool-versions`](./.tool-versions)):

- Elixir 1.18.4 / Erlang OTP 28.0.2
- `bubblewrap` (bwrap) — available as an OS package on every major
  distro. On Ubuntu 24.04 you also need an unconfined AppArmor profile
  for bwrap (see `.github/workflows/ci.yml` for the canonical fix).
- `inotify-tools` (Linux-only).
- Zig 0.15.2 (for building single-file releases via Burrito).

Recommended:

- `mix format` and `mix credo --strict` must be clean before you push.

```bash
mix deps.get
mix compile --warnings-as-errors
mix test
```

## How to contribute

### 1. Discuss before you build

For anything larger than a one-line fix, open a GitHub issue first to
align on approach. This is especially important for:

- Anything touching the kernel / Router / permission-mapper layer.
- Changes to the on-disk layout under `~/.glorbo/`.
- Changes to the SQLite schema (remember: the SQLite DB is *derived
  data* and must be reconstructable from the filesystem — see
  `CLAUDE.md`).
- New external dependencies.

### 2. Branch + PR flow

- Fork the repo (or branch directly if you have write access).
- Branch naming: `feat/<short>`, `fix/<short>`, `docs/<short>`, etc.
- Keep PRs focused — one concern per PR. If you find an unrelated
  issue while working, file it separately rather than folding it in.
- Rebase on `main` before opening the PR; avoid merge commits.

### 3. Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short summary>

<body — what and why, not how>
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`,
`perf`, `build`, `style`.

Examples from `git log`:

- `feat(01-01): generate Phoenix skeleton, pin toolchain, enable SQLite WAL`
- `fix(sandbox/bwrap): replace bash-only ${@:3} with POSIX shift`
- `docs(03): mark human UAT self-verified (2/3 passed, 1 deferred)`

### 4. Quality gates

Every PR must pass the following on CI before it can merge. You should
run them locally first:

```bash
mix compile --warnings-as-errors   # no warnings
mix test                           # all tests green
mix credo --strict                 # lint clean
mix format --check-formatted       # formatter clean
```

CI also builds a Burrito release binary and smoke-tests it (`glorbo
doctor --json`). Breaking the doctor's JSON contract is a blocker.

### 5. Tests

- New features need tests. Bug fixes should include a regression test
  that fails before the fix and passes after.
- Sandbox/bwrap integration tests gate on `bwrap` availability at
  runtime — keep it that way so contributors on non-Linux hosts can
  still run the rest of the suite.
- Prefer small, focused test files. The test filename convention
  mirrors the module under test (enforced by Credo's
  `Warning.WrongTestFilename`).

## Architectural guardrails

These are load-bearing invariants. A PR that weakens any of them needs
explicit justification and sign-off in the PR description.

- **Kernel is the policy engine.** Permissions enforced at Elixir
  Router *and* POSIX ACLs. Application-only checks are a design bug.
- **Filesystem is source of truth.** SQLite is derived; `glorbo
  reindex` must rebuild it fully from markdown/JSONL.
- **One-way inbox/outbox flow.** Elixir writes inbox, reads outbox.
  Agents read inbox, write outbox. No shortcut.
- **Audit log is append-only.** `audit/YYYY-MM.jsonl` is never
  modified or deleted.
- **Python runs in containers only.** Never on the host.
- **Company isolation is absolute.** One Podman container per company,
  only that company's directory mounted.
- **Crash isolation follows the OTP supervision tree.** Agent crash
  → only that agent restarts, never the whole dashboard.

## Code style

- Follow `mix format` (it runs on CI with `--check-formatted`).
- Don't add comments that restate WHAT the code does. Comments are for
  the non-obvious WHY: a kernel gotcha, a subtle invariant, a
  workaround citing a specific upstream bug.
- Avoid defensive error handling for scenarios that can't happen.
  Trust internal boundaries. Validate only at the edge (user input,
  external APIs).
- Keep functions small and named after what they do. Prefer pattern
  matching at the function head over `case` inside the body.

## Planning workflow

The `.planning/` directory contains GSD v1 planning artifacts
(`PLAN.md`, `RESEARCH.md`, `VERIFICATION.md` per phase). These are
committed on `main`. If you're proposing a significant feature, look
at an existing phase (e.g. `.planning/phases/03-.../`) to see the
shape — then open an issue to discuss whether a new phase is
warranted.

For smaller contributions, skip the planning overhead — just open an
issue and a PR.

## Review checklist

Before requesting review, self-check:

- [ ] Scope is clear from the PR title + description.
- [ ] `mix compile --warnings-as-errors && mix test && mix credo
      --strict && mix format --check-formatted` all pass.
- [ ] Touched `DESIGN.md` invariants? Explained why in the PR body.
- [ ] Added/updated tests for the behaviour change.
- [ ] No new top-level deps without discussion.
- [ ] No secrets, API keys, or personal paths in diffs, logs, or test
      fixtures.
- [ ] Commits are clean and Conventional.

## License

By contributing, you agree that your contribution will be licensed
under the Apache License 2.0 (see [`LICENSE`](./LICENSE)).

## Questions

Open a non-sensitive issue or email `security@example.invalid`. For
security-sensitive reports, see [`SECURITY.md`](./SECURITY.md).
