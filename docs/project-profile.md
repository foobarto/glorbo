---
cairn-artifact: project-profile
version: 1
last-synthesised: 2026-06-10
---

# Glorbo project profile

<!--
  cairn project-profile for Glorbo. Short statement of the
  project's values, stances, and tradeoff preferences. Read
  at session start by every contributor (human or agent) to
  calibrate implementation choices without having to re-infer
  them from the code.

  Differs from CLAUDE.md in role: CLAUDE.md is operational
  (commands, file paths, skills); this is dispositional
  (stances, values, risk tolerances).
-->

## Code style

- Idiomatic Elixir; `mix format` is authoritative for
  whitespace.
- Prefer pattern-matching over conditionals where it doesn't
  cost legibility.
- Comments explain the *why* — the *what* is the code's job.
  A comment describing what the next three lines do is a
  smell; a comment explaining why the lines look wrong but
  aren't is gold.
- Module docstrings for every public module — one paragraph
  minimum, explaining its role in the system.
- Function docstrings for every public function that isn't
  self-evident; `@doc false` on internal-but-visible helpers.
- No magic numbers: named module attributes or config keys.

## Architecture style

- **OTP supervision is the bedrock.** Crash isolation, let-it-
  crash, bounded blast radius. Whenever a design question
  comes up, "what's the supervision shape?" is the first
  question.
- **Kernel-enforced security beats application checks.**
  bwrap mount namespaces + network namespaces over "the app
  will check permissions" (GEP-5).
- **Filesystem is source of truth** (GEP-3); SQLite is
  derived. Any design that inverts this is wrong.
- **One write-path per mutation.** No parallel write paths
  (GEP-6 D6, GEP-29 D3). Every frontend routes through the
  same Elixir action layer (the driver behind the
  in-progress GEP-36 + GEP-38).
- **No Python anywhere.** No native runtime either. Pure
  Elixir + Burrito + bwrap.
- **Single-user-per-instance product model.** Many directors
  running their own instances, not multi-tenant.

## Risk tolerance

**Level: Moderate to Aggressive.**

- L2 autonomy is the comfortable default for autonomous
  rounds. L3 acceptable case-by-case — e.g., promoting a
  Placeholder to Draft when the design space is clearly
  settled.
- Pre-1.0 atomic-cut discipline stays (no backwards-compat
  shims, no soft migrations). Breaking changes are cheap now
  and expensive later — lean into the opportunity.
- Dep bumps: roll them. Don't wait.
- Schema/file-format changes: fine, but always with a
  `reindex` escape hatch so the filesystem truth can rebuild
  the SQLite projection.
- "Shared-state corruption" and "force-push published
  history" are still ask-before-doing, not L3 autonomous.

## Security posture

**Stance: Paranoid.**

The maintainer is a security-minded developer; public
shipping of unpatched findings or egg-on-face bugs is
unacceptable. Security is not a compliance checkbox — it's
pride of work.

**Sensitive areas:**

- **Agent-writable-file surface.** Anything under
  `~/.glorbo/companies/<co>/agents/<slug>/{inbox, outbox,
  state, memory, workspace}/`. All writes go through
  `Glorbo.Filesystem.AgentWritableFile` with lstat-before-
  touch, symlink ancestor check, and atomic tmp+rename.
  Never introduce raw `File.*!` writes to these paths.
- **Frontmatter parsers.** YAML input from agent output is
  untrusted. `Glorbo.Filesystem.Frontmatter` and
  `Glorbo.FileSpec.*` enforce the allow-listed key sets;
  any new kind needs a validator entry.
- **`Glorbo.Company.Router`.** Single enforcement point for
  outbox classification and kind-gating. All mutations from
  the agent side land here first.
- **`GlorboWeb.MCP.*`.** Localhost-only, single write path
  through `GlorboWeb.Actions` (GEP-29 D3). Any new tool must
  follow the same route.
- **`bwrap` / `pasta` sandbox setup** (`Glorbo.Sandbox.*`).
  Mount namespace + netns construction; typoed allowlists
  let real compromise through.
- **Release-surface signing** (`cosign`, SHA256SUMS, the
  Homebrew tap). Tap formula + GitHub Release body must
  stay consistent.

**Required review tools per sensitive-area change:**

- `mix precommit` — non-negotiable.
- `mix credo --strict` — zero findings to ship; check
  `$?` explicitly (credo doesn't exit non-zero on refactor
  warnings per past incident).
- Manual diff review against OWASP Top 10 when touching
  input-handling paths, path-traversal guards, or anything
  that reads / writes to filesystem segments owned by
  agents.
- Second-opinion review (`codex exec` at minimum) for
  non-trivial diffs — see `feedback_codex_review_before_commit`
  memory.

**Security findings left sliding are a P0.** Rolling medium
queue is tracked at `docs/testing/threatmodel.md`; every
finding gets closed before a version cut or explicitly
deferred with rationale in that doc.

## Quality bar

- **Test coverage target: "best effort."** No mandatory
  percentage. Rule of thumb: every public function has at
  least one test; every module-crossing change has an
  integration test.
- **Functional / E2E tests preferred over unit tests** at
  higher app layers. Unit tests earn their keep for
  "should-never-happen" defensive scenarios where higher
  layers don't reach that branch. Integration / LiveView
  render tests + E2E (Playwright via CDP) are where real
  confidence comes from.
- **E2E UAT before every version cut.** `docs/testing/uat.md`
  checklist walk-through is non-negotiable. "All tests
  pass" is not enough — the actual UI has to be exercised.
- **Performance target: no explicit numbers.** Regressions
  flagged in review. Single-operator scale is the ceiling;
  don't over-optimise for scale that won't happen.
- **Quality over partial result.** (Operator directive,
  2026-06-08, during the GEP-0055 reframing.) When a feature's
  honest scope is bigger than one sitting, ship the smaller
  *complete* slice — not a wider slice with stubbed-out
  load-bearing parts. A "done" that only covers the happy
  path is a partial result, not a result.
- **Docs: best effort, refreshed before version cuts.** See
  below on pre-release cleanup.

## Contribution norms

- Small atomic commits. One concern per commit.
- Commit subject in conventional-commit form
  (`feat(scope):`, `fix(security):`, `docs(session):`, etc.).
  Body explains the *why* when non-obvious.
- PR size: not team-gated (solo project today), but mental
  bar is "can one reviewer hold the whole change in mind."
  If not, split.
- **Codex second opinion** for non-trivial diffs before
  commit. Docs-only + tiny fixes can skip; flag the skip in
  the session journal.
- **Autonomous commits** allowed per cairn's autonomy
  protocol (L2 default). Pushes require explicit
  authorisation per commit batch.

## Tech-debt stance

- **Pay down when:** touching a module for a feature surfaces
  the debt; it blocks a new feature; it has a security
  implication; it's become a source of recurrent bugs.
- **Defer when:** isolated in a deprecated code path; cost-
  benefit unclear at current scale; pre-1.0 and not blocking
  anything.
- **Refactors for their own sake:** no. Surgical changes
  principle — every line changed traces to a user request
  or a concrete bug.

**P0 definition — "actively wrong":**

- **Security finding left sliding past a version cut — never
  OK.** Either fix upstream, or **apply mitigation in our
  own code** if upstream can't be fixed (e.g., vulnerability
  in a critical dependency with no patched version: wrap the
  dep with extra filtering/validation that prevents the
  exploitable payload from reaching the vulnerable code
  path). Silently deferring without a mitigation is never
  acceptable. The deferral-with-rationale in
  `docs/testing/threatmodel.md` must explicitly describe the
  mitigation if the fix can't be applied at the vuln site.
- Production-path bug (the single-user main workflow
  broken). Dispatch hangs, Router crashes, inbox loses
  messages.
- Stale docs that mislead new contributors or users.
  "Smell" level — fix within the next release window, don't
  let them accumulate.
- CI red for >24h. Fix or revert.
- Public release with silent corruption risk. Pull the
  release if discovered post-cut.

## Pre-release cleanup phase

Before every version cut, execute this gate — no shortcuts,
no exceptions:

1. **Doc-drift pass** — read through CHANGELOG.md,
   README.md, `docs/DESIGN.md`, `docs/architecture.md`,
   relevant moduledocs. Anything referring to changed
   modules, renamed commands, new features, or retired
   features must be updated.
2. **Graphify refresh** — `graphify update lib && mv
   lib/graphify-out/GRAPH_REPORT.md docs/knowledge-graph/ &&
   rm -rf lib/graphify-out`. Append tacit-knowledge entries
   to `docs/knowledge-graph/notes.md` for anything
   surprising in the diff.
3. **Full test run** — `mix test` green; integration test
   tags green if applicable.
4. **E2E UAT checklist** — walk `docs/testing/uat.md` in a
   real browser; mark each case green/red with notes. Ship
   findings before cutting.
5. **Security review** — review the
   `docs/testing/threatmodel.md` open queue; every open
   finding gets closed or deferred-with-reason. No silent
   deferrals.
6. **Release artefact flow** — tag → signed GH release +
   Burrito binaries + Homebrew tap formula regen. See
   `docs/releasing.md`.

## The crown jewels — non-negotiable quality axes

Per the maintainer (2026-04-24): the four things that have to
be top-notch, above all else:

1. **Inter-agent interaction** — handoffs, collaboration,
   knowing when to call another agent vs. do it yourself.
2. **Director interaction** — when to escalate, how much to
   bother the human, what earns their attention.
3. **Deliverable quality** — the artifact has to be usably
   good, not hand-wavy "done."
4. **Anti-failure modes** — no slop (vague output), no junk
   (superficially complete but wrong), no stuck (silent
   looping, lost tasks).

Web/shell surface flaws can be forgiven. Crown jewels
cannot. Research + ranked intervention list at
[`docs/research/crown-jewels.md`](research/crown-jewels.md).

## Design aesthetic

- **Simplicity over cleverness.** Three-hundred lines of
  straightforward code beats fifty lines of magic every
  time.
- **Specific over generic.** Named module per concern;
  no "Utils" or "Helpers" modules. Short names (GEP, EP,
  cairn) over long ones.
- **Honest over aspirational.** Session logs record what
  was skipped and why, not a polished "everything went
  smoothly" narrative. Commit messages reflect reality.
- **Proud craftsmanship.** This is a tool the maintainer
  uses daily and intends to use daily for years. Build
  accordingly.

## Open tensions

- **Cairn-vs-Glorbo dogfooding.** Cairn extracts Glorbo's
  workflow; Glorbo will eventually dogfood Cairn. Exact
  reconciliation TBD — worktree-based comparison planned
  before any installation.
- **`Glorbo.Actions` shape** — pure module/functions vs
  GenServer — is an open design question for the GEP-36
  Draft, unresolved at the time of this profile version.
- **v1 gating criteria** — not defined yet. Maintainer's
  north star: "useful/valuable tool, at minimum on par
  with paperclip agents."

## Long-term vision

Per the maintainer, 2026-04-24:

> I'd like [glorbo/cairn] to be useful and part of my
> daily work routine. I imagine outsourcing administrative
> tasks to glorbo like documentation writing, research,
> keeping existing documentations up to date, helping
> writing novels etc.. cairn I hope to shape up into an
> expression how I prefer to work with AI agents, for it
> to capture my workflow and expectations on how work
> should be delivered, the interactions vs autonomy I
> expect.

Use this as the calibration for "does this change move us
toward daily-use reliability?"
