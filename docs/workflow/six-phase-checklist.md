# Six-phase feature checklist

Every non-trivial feature moves through these six phases, in
order. Skipping phases is how you get to a half-shipped feature
three times in a row.

**Read first:**
[docs/workflow/governing-principles.md](governing-principles.md).
The six phases are *when*; the four principles are *how within
each phase*. Ticking phases mechanically without applying the
principles is the failure mode this doc is designed to prevent.

| # | Phase      | Artefact                                            |
|---|------------|-----------------------------------------------------|
| 1 | **Spec**   | Proposal draft (via ep-kit, in `docs/eps/` or the equivalent) |
| 2 | **Plan**   | Proposal accepted; concrete implementation outline  |
| 3 | **Build**  | Code changes + any doc-adjacent updates             |
| 4 | **Test**   | Unit green + E2E/manual where applicable            |
| 5 | **Review** | Self-review (see below) + second opinion            |
| 6 | **Ship**   | Commit + push, AND every doc the change affects     |

Bug fixes, doc tweaks, and dep bumps collapse phases 1–2 (no
proposal) but still pass through 3–6.

---

## Phase 1 — Spec

Write a proposal before writing code when the change:

- Affects a public contract (API, CLI surface, on-disk layout).
- Touches a load-bearing invariant.
- Reverses or extends a prior proposal.
- Answers a "should we do X or Y?" question that isn't obvious
  from the code.

For bug fixes, contained refactors, dep bumps — skip the
proposal, go straight to phase 3. Trust the commit message + PR
description to carry the rationale.

## Phase 2 — Plan

Proposal is `Accepted`. Outline the implementation before
opening the first file:

1. Modules/files that will change.
2. Tests you'll add or update.
3. Docs that will need updating at phase 6.
4. A rough sequence of commits (not a mandate — a sketch).

This is usually a 5-minute exercise captured in the session
journal, not a separate document.

## Phase 3 — Build

Code. Follow the project's coding discipline (usually pinned in
`CLAUDE.md`). Keep commits surgical — every changed line should
trace to the user's request.

Touch adjacent docs **in the same commit** where it's cheap:
function docstrings, README examples, schema diagrams. Save the
sweeping doc pass for phase 6.

## Phase 4 — Test

- **Unit tests** for the pure logic you changed.
- **Integration / E2E** if the change crosses module boundaries
  or user-facing behaviour.
- **Manual test checklist** update if the project has one.

Run the tests. Record results in the session journal's *Gates*
block. Do not claim done before this.

## Phase 5 — Review

Three passes, in order. **Quality and security are both
mandatory**; second opinion is expected on non-trivial changes
but optional for small diffs.

### 5a. Self-review

Read the diff as if you're seeing it for the first time. Look
for:

- Scope creep (unrelated changes sneaking in).
- Dead variables / unused imports / stale comments.
- Comments explaining *what* instead of *why*.
- Missing docstrings on public API.
- Gate failures you glossed over.

### 5b. Quality pass (mandatory)

Run the project's canonical gate (`mix precommit`, `pnpm run
check`, `cargo clippy --all-targets`, `just check`, etc.) and
any language-specific linter detected for the changed files.

Record tool + command + result in the session journal:

```markdown
**Quality:**
- `mix precommit` — clean (exit 0).
- `mix credo --strict` — 0 issues (exit 0 explicitly verified).
```

### 5c. Security pass (mandatory)

Never skip. Two paths:

- **Tool-based:** Run detected SAST (`semgrep`, `bandit`,
  `gitleaks`, etc.). If `security-kit` or similar orchestrator
  is installed, use it.
- **Manual fallback** (when no tool is available): Read the
  diff explicitly against OWASP Top 10, secret handling,
  authz/authn boundaries, input validation at system edges,
  dependency risk. Document in the journal.

Record in the journal. Any high/critical finding is a blocker
— do not proceed to phase 6 until resolved.

### 5d. Second opinion (optional for small changes)

For non-trivial changes (new modules, API contracts, security-
adjacent code, >~200 lines across 2+ files): dispatch a
second-opinion reviewer — another person, `codex exec`, or a
specialised code-review agent.

For small diffs (bug fixes under ~50 lines, doc changes, dep
bumps): skip and note the skip with reason.

Apply must-fix feedback inline. Log nice-to-haves to the
session journal.

### If cairn's `review-phase` skill is available

It orchestrates 5b-5d automatically: tool detection, plan
proposal, invocation of the `review-runner` sub-agent, summary
into the journal. Use it as the default entry point for phase
5 instead of driving these passes manually.

## Phase 6 — Ship

Commit + push if authorised. **Then** do the doc pass. Consider
updating every one of these:

- `CHANGELOG.md` — what shipped, always.
- `README.md` — if the user-facing pitch or install story
  changed.
- The project's architecture / design doc — if module map,
  invariants, or tech stack changed.
- Proposal status — flip `Accepted → Implemented` when the
  implementation lands.
- `docs/todo.md` — cross off whatever this change addressed.
- Manual test checklist — if a UI surface was added.
- Knowledge-graph notes — if you uncovered a gotcha, surprising
  call chain, or load-bearing invariant.

"Ship" is not done until the docs that lie about the code have
been updated. Stale docs are technical debt that compounds.

---

## Anti-patterns to catch yourself doing

| Signal | What it usually means |
|---|---|
| "I'll document it later." | Phase 6 will be skipped. Do it now. |
| "The tests will catch it." | Phase 4 was rushed. Add tests *before* the implementation settles. |
| "I didn't need a proposal for this." | Phase 1 was skipped. If the change touches a contract, pause and write one. |
| "Let me just improve this adjacent bit." | Scope creep. Note it in `docs/todo.md` and move on. |
| Shipping without second opinion | Phase 5 half-done. For trivial changes it's OK; flag it honestly in the session journal. |
