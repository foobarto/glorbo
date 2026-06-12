---
gep: 44
title: Visual regression baselines for the LiveView dashboard
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Process
created: 2026-04-25
see-also: [6, 30]
history:
  - date: 2026-04-25
    status: Draft
    note: |
      Initial draft + v1 baselines captured for the eight Tier-1
      LiveViews against the v0.10.0 build. Harness is bash + node
      (`scripts/ui-baseline.sh`) using Playwright + pixelmatch via
      `npm exec` so contributors don't need a project-level node
      install. Diff threshold set conservatively at 0.5% pixel
      delta; can be tightened once we see real cross-run noise.
  - date: 2026-04-26
    status: Implemented
    note: |
      Tier-2 + Tier-3 baselines added (16/18 LVs gated; `/health`
      and `/providers` excluded via `DIFF_SKIP` because their
      content is env-dependent — captured but not diffed).
      `.github/workflows/release.yml` runs the VR check step as an
      informational `continue-on-error` gate (x86_64 only — VR
      harness depends on Playwright Chromium which isn't
      available on aarch64 GHA runners). Cross-run drift settled
      at 0.000–0.045% across three back-to-back local runs after
      adding the top-30/bottom-30 clip rect that excludes the
      browser path bar + clock. v0.11.1 CHANGELOG records the
      ship.
---

# GEP-44: Visual regression baselines for the LiveView dashboard

## Problem

Glorbo's LiveView surface keeps growing — 19 LVs as of v0.10.0,
several of which had visible-but-subtle regressions during prior
cycles (modal narrow-viewport class bugs, topbar overflow, the
GEP-19 `pending-approval` Kanban filter dropping tasks silently,
modal `__body` styling rot). Each was caught by manual UAT, but
only after the regression had been live for at least a session.

Unit tests cover correctness; LiveView render tests cover markup;
neither catches **what the screen actually looks like**. A diff
of `kanban_live.html.heex` doesn't reveal that the new column-bar
adds 8px of unintended margin around every card.

We want a fixture-based comparison: capture a known-good screenshot
per LV, compare future runs against it, fail if the perceptual
delta crosses a threshold. Standard visual-regression pattern.

## Goals

- Catch unintended LV visual changes between releases without manual
  UAT.
- Harness must run from CI without requiring a graphical desktop
  (headless Chromium).
- Baselines must live in the repo so reviewers can eyeball-diff a
  PR's "did the screenshot change" against `git diff`.
- One command (`bash scripts/ui-baseline.sh check`) returns
  non-zero if any LV's screenshot drifted past the threshold.
- Updating baselines after an intended UI change must be a
  one-flag operation
  (`bash scripts/ui-baseline.sh update`).

## Non-goals

- **Full LV coverage in v1.** Eight Tier-1 LVs (the surfaces a
  Director uses daily) are enough to catch the largest blast-
  radius regressions. Tier-2 and Tier-3 expansions land in
  follow-up rounds when their utility is proven.
- **Cross-browser pixel parity.** Baselines are captured with
  one specific Chromium version; rendering on Firefox or Safari
  will differ. We don't promise pixel-identical output across
  browsers — we promise drift detection between runs of the
  *same* browser version.
- **Automatic baseline updates on CI.** Updates are an explicit
  human action — reviewers should look at what changed before
  the new state becomes the baseline.

## Design

### Storage layout

```
test/fixtures/ui-baselines/
├── README.md                                      # how to update + threshold
├── 2026-04-25-v0.10.0/                            # first baseline set
│   ├── 01-overview.png
│   ├── 02-company.png
│   ├── 03-kanban.png
│   ├── 04-audit.png
│   ├── 05-inbox.png
│   ├── 06-agent.png
│   ├── 07-task.png
│   └── 08-health.png
└── current/                                       # symlink → most recent set
```

Each baseline set is timestamp+version-named so the history of
"what the UI looked like at vN" is self-documenting via `git log
-- test/fixtures/ui-baselines/`. The `current/` symlink points at
the active comparison target.

### Tier-1 LVs (v1 scope) — Director-daily surfaces

Pages that a Director hits daily — regressions here block normal use:

1. `/companies` — overview (multi-company list)
2. `/companies/:co` — single company dashboard
3. `/companies/:co/kanban` — task board
4. `/companies/:co/audit` — audit log
5. `/companies/:co/inbox` — approvals queue
6. `/companies/:co/agents/:agent` — agent detail
7. `/companies/:co/tasks/:task_id` — single task editor
8. `/health` — doctor surface

### Tier-2 LVs (added 2026-04-25) — Secondary collaboration + governance

9.  `/companies/:co/channels/:channel` — chat / channel log
10. `/companies/:co/goals` — goal tracker
11. `/companies/:co/proposals` — agent-created proposals queue
12. `/providers` — provider registry / config
13. `/costs` — per-agent monthly LLM spend

### Tier-3 LVs (added 2026-04-25) — Remaining LV surfaces

14. `/companies/:co/tasks/:task_id/chain` — handoff chain timeline (GEP-40)
15. `/benchmarks` — A/B benchmark runs index (GEP-26)
16. `/companies/:co/braindump` — append-only daily braindump
17. `/companies/:co/skills` — company skill registry
18. `/companies/:co/projects/:project` — project detail / task list

A `/benchmarks/:run_id` (BenchLive) detail surface is intentionally
left out of Tier-3 until canonical fixture runs land — capturing
the empty-state index covers the parent route.

### Harness

`scripts/ui-baseline.sh` is a bash + Node.js script using:

- **Playwright** (`npm exec --package=playwright -- playwright`) for
  the headless browser — already installed during today's UAT
  unblock so it's a known-working dependency.
- **pixelmatch** (`npm exec --package=pixelmatch`) for perceptual
  diff — small, well-known library that produces an exit code +
  optional `<screen>-diff.png` next to the failing baseline.

Usage:

```sh
bash scripts/ui-baseline.sh capture <DEST_DIR>   # boot phx.server, screenshot all 8 pages
bash scripts/ui-baseline.sh check                # capture to tmp + diff vs current/
bash scripts/ui-baseline.sh update               # capture into a new dated dir + repoint current/
```

Captures run against a fresh `mix phx.server` rooted at a tmp
`GLORBO_HOME` so the baselines aren't affected by whatever's in the
contributor's actual `~/.glorbo/`. The tmp home is seeded with a
canonical fixture company so each LV has predictable content
(handled by an `--init-from-fixture` flag on the harness).

### Diff threshold

**0.5% pixel delta** — pixelmatch reports
`(diffpx / totalpx) * 100`. Any LV whose diff exceeds 0.5% fails
the check. The threshold is intentionally conservative for v1;
once we see real cross-run noise (font-render variance,
GIF-anim banner timing, etc.) we can tighten or relax per-LV.

Rationale for 0.5%:

- Anti-aliasing differences across runs typically land below 0.1%.
- A 16px font-size change on one heading would land near 0.3%.
- A new icon or button addition in a sidebar near 1.0%.
- A missing region (modal failed to render) at 5%+.

So 0.5% catches "real" visual changes while tolerating sub-pixel
rendering noise.

### What's expected to drift run-to-run

These elements vary between captures and need either masking or
deliberate stability:

1. **Wall-clock timestamps** in the topbar / footer / audit-tail.
   The harness sets a fixed `Glorbo.Clock.now/0` fake at boot, but
   only for the LVs that go through that surface. Audit log
   relative timestamps ("2 h ago", "3 d ago") will drift unless
   audit fixture uses absolute past dates.
2. **Daemon uptime** in the footer. Expected to drift; treated as
   a masked region (zero out the rectangle before diff).
3. **Live cursor / animations.** None of the Tier-1 pages use
   animation by design; if any do, mask the animated region.

### Update workflow

When an intended UI change lands:

1. Reviewer looks at the failing diff PNG (`pixelmatch` writes
   `<screen>-diff.png` next to the baseline) to confirm the
   change matches the PR's stated intent.
2. Author runs `bash scripts/ui-baseline.sh update` locally.
3. Author commits the new `2026-MM-DD-vX.Y.Z/` directory + the
   updated `current/` symlink in the same PR as the UI change.
4. Reviewer approves both code change + baseline change in one
   review pass.

This keeps baseline updates honest — a baseline-only PR with no
matching code change is suspicious; the same PR carrying both
makes the visual delta legible alongside the code delta.

## Migration / rollout

- v1 ships eight Tier-1 baselines + the harness.
- Tier-2 expansion: next baseline-sprint round (≈ 4 LVs:
  channels, goals, proposals, providers, costs). **Done 2026-04-25.**
- Tier-3 expansion: opportunistic, when the LV gains real usage.
  **Done 2026-04-25** — task_chain, benchmarks, brain_dump, skills,
  project. `/benchmarks/:run_id` deferred until canonical fixture
  runs land.

## Failure modes

### Baseline drift from font / locale changes

A new system font or locale can shift baselines on every CI
machine. Mitigation: bake the font + locale into the harness's
`--init-from-fixture` setup (LANG=en_US.UTF-8, no font fallback
chain). If CI uses a different host, run the harness inside the
project's distrobox so the rendering environment matches.

### LV that depends on async data

If an LV renders empty initially and fills in via a 200ms async
load, the screenshot might catch the empty frame. Harness uses
`page.wait_for_selector(<known-loaded-marker>)` per LV; the
markers are listed in the script's `PAGES` map.

### Agent dashboard with live stdout streamer

`AgentLive` includes a stdout tail that updates live. The
baseline captures it once; subsequent captures will diff if the
streamer received new bytes. Mitigation: the harness's tmp home
seeds a fixed `agents/<slug>/stdout.log`; the streamer never gets
new content during the capture.

## Test strategy

- Unit-style: pixelmatch's diff output is deterministic — same
  inputs produce the same diff. The harness's exit code thus
  becomes the test signal.
- Run the harness on CI as a non-blocking gate during the
  baseline-sprint period (warn on diff but don't fail the build);
  promote to blocking once flake rate is measured below 1% over
  one release cycle.

## Decision log

### D1. Eight Tier-1 LVs in v1

- **Decided:** start with a fixed list of eight load-bearing LVs.
- **Alternatives:** all 19 immediately; only 3-4; auto-discover
  from router.
- **Why:** fixed list keeps the harness deterministic; eight is
  the count that covers Director daily use without making the
  capture loop take long enough to flake on CI timeouts.

### D2. Pixel-diff threshold = 0.5%

- **Decided:** 0.5% pixel delta is the failure threshold.
- **Alternatives:** 0.1% (too tight, sub-pixel AA noise); 1%
  (too loose, misses real changes).
- **Why:** 0.5% is the consensus default in similar harnesses
  (Storybook's Chromatic, Playwright's `toMatchScreenshot`).
  Per-LV override possible if specific surfaces need tighter or
  looser thresholds.

### D3. Headless Chromium, not Firefox/Safari

- **Decided:** Chromium-only baselines.
- **Alternatives:** multi-browser matrix.
- **Why:** Glorbo's dashboard isn't expected to produce identical
  output across browsers; we're measuring drift between runs of
  the *same* browser, not cross-browser parity. Multi-browser
  testing is a v2 concern when we have observable cross-browser
  bugs.

### D4. Baselines committed to repo, not stored externally

- **Decided:** `test/fixtures/ui-baselines/` is checked into git.
- **Alternatives:** S3 / CDN-hosted baselines pulled by the
  harness on each run.
- **Why:** PR reviewers can see "the baseline image changed" in
  `git diff` directly; no external service to set up. Cost: the
  repo grows by ~1.2MB per baseline set. At a baseline-set per
  release cycle that's manageable (the alternative — losing
  reviewer visibility — is worse).

### D5. Baseline update is a manual flag, not auto

- **Decided:** updating baselines requires explicit `update` invocation.
- **Alternatives:** auto-promote new captures if diff < threshold.
- **Why:** auto-promote risks "stamping" subtle drift as the new
  truth. Manual update keeps the human in the loop.

### D6. Capture from a tmp `GLORBO_HOME`, not the contributor's home

- **Decided:** harness boots `mix phx.server` against a fresh tmp
  home with a canonical fixture company.
- **Alternatives:** use the contributor's `~/.glorbo/`.
- **Why:** contributor home varies — different companies, agents,
  audit history — so baselines would never match. Fixture-based
  capture is the only way to get deterministic content.

## Open questions

- ~~**Should we add Tier-2 LVs in this v1 cut, or wait?**~~
  *Resolved 2026-04-26:* Tier-2 + Tier-3 expanded; 16/18 LVs
  gated. `/health` and `/providers` carved out via `DIFF_SKIP`
  because their content is env-dependent.
- **Per-LV threshold overrides?** Not yet. After three local
  runs at 0.000–0.045% drift the global 0.5% threshold has
  plenty of headroom; revisit if any LV proves noisier in
  practice.
- **Mobile / narrow-viewport variants?** Still out of scope.
  Director's primary use is desktop. Narrow-viewport bugs
  (the topbar truncate-popover punch-list item) deserve their
  own baseline set when the design lands.
- **aarch64 / Apple-Silicon CI parity?** Currently x86_64-only
  on GHA — Playwright Chromium isn't available on `ubuntu-24.04-arm`
  runners. Tracked but not blocking; adding aarch64 baselines
  needs a separate fixture set anyway since fonts/AA differ.
