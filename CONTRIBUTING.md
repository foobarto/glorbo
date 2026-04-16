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

### 2. Significant design changes — write a GEP

Non-trivial design changes are captured as **Glorbo Enhancement
Proposals (GEPs)** in [`docs/geps/`](./docs/geps/). A GEP is a
numbered, append-only design record with a required decision log —
the "why" that outlives any one PR. See
[`docs/geps/0001-gep-purpose-and-guidelines.md`](./docs/geps/0001-gep-purpose-and-guidelines.md)
for the full process, and
[`docs/geps/README.md`](./docs/geps/README.md) for the index.

**Write a GEP if** your change:

- Introduces a new public contract — CLI flag, config schema, on-disk
  layout, API surface, `agent.md` field.
- Touches a load-bearing invariant documented in `DESIGN.md` or an
  existing GEP.
- Reverses, supersedes, or materially extends a prior decision.
- Spans multiple modules or milestones and benefits from a shared
  reference.

**Skip the GEP for:**

- Bug fixes, dependency bumps, doc tweaks.
- Refactors contained to one module with no behaviour change.
- Performance work that doesn't change APIs.

**Outside contributors are not required to write GEPs.** A good PR
with a clear description is welcome regardless. Maintainers will
retrofit a GEP post-merge if the change warrants one. If you'd like to
collaborate on a GEP, open a Draft PR with the GEP file — we'll
iterate on it together before accepting.

**Working on a change and realising it needs a GEP?** Mention it in
your PR; the maintainer can either help you add one or retrofit it
after merge as an Informational GEP capturing what shipped.

**Proposing a GEP without a code change.** You're welcome to propose
a design, challenge an accepted GEP, or retrofit historical context
without any implementation. To avoid wasted effort on both sides:

1. **Open a GitHub issue first.** One or two paragraphs describing
   the idea. Label it `gep-proposal`.
2. **Wait for a maintainer triage response:**
   - **"Go ahead as Draft"** — open a GEP PR at `status: Draft`.
     You've worked through the design space enough to defend
     concrete choices. A maintainer flips it to `Accepted` (or
     `Rejected`) after review.
   - **"Go ahead as Placeholder"** — open a GEP PR at
     `status: Placeholder`. The idea is worth capturing and
     numbering, but the design space is still open. A Placeholder
     has a problem statement, goals, open questions, and a few
     settled decisions — the rest is explicitly flagged as
     "to be worked out." Lower review bar to merge; you (or
     someone else) promotes it to Draft later when the open
     questions are resolved. See GEP-1 §"Placeholders."
   - **"Not needed"** — the change is too small for a GEP or
     already covered elsewhere. The issue stays open for discussion
     and may evolve into something else.
   - **"Out of scope"** — the proposal doesn't fit Glorbo's
     direction. Closed with context so others can see the reasoning.
3. **Rejected GEPs stay in the repo** with `status: Rejected` and a
   brief history entry. This is deliberate — it documents "we
   considered this, here's why we passed" and saves everyone from
   re-litigating the same idea.

This triage step prevents two failure modes: contributors writing
full GEPs that get rejected on scope (wasted time), and maintainers
drowning in speculative proposals (wasted attention). A two-paragraph
issue is cheap for both sides.

### 3. Branch + PR flow

- Fork the repo (or branch directly if you have write access).
- Branch naming: `feat/<short>`, `fix/<short>`, `docs/<short>`, etc.
- Keep PRs focused — one concern per PR. If you find an unrelated
  issue while working, file it separately rather than folding it in.
- Rebase on `main` before opening the PR; avoid merge commits.

### 4. Commit messages

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

### 5. Quality gates

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

### 6. Tests

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
- **No Python anywhere.** Agents are CLI-tool subprocesses under
  bwrap. The pre-pivot plan to run Python inside Podman has been
  dropped (GEP-5 D6).
- **Company isolation is absolute.** Each agent's bwrap sandbox
  bind-mounts only the active company's directory; sibling
  companies are simply not in the mount list.
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

Significant design changes go through the GEP process described in §2
above. For smaller contributions, skip it — open an issue, open a PR,
be clear about scope. Maintainers retrofit a GEP post-merge if the
change warrants one.

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
