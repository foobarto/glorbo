# State

Last updated: 2026-06-13

> **Superseded (2026-06-13).** This file is no longer the live state of
> record — the project moved to the cairn workflow. Current state lives in
> `docs/project-profile.md` (stance), `docs/sessions/<date>-<topic>.md`
> (running journal), and `docs/todo.md` (punch list). The snapshot below is
> kept only so its facts aren't actively wrong; treat the cairn docs as
> authoritative.

## Repo

- Branch: `main`
- Worktree status: check with `git status --short`
- HEAD: check with `git log -1 --oneline`
- Latest shipped version: `v0.26.0`

## Implementation Status

- GEP-32 is fully **Implemented** — native agent harness (filesystem
  tools, bash, web_fetch, native usage.json, audit replay, provider model
  catalog). See `docs/geps/README.md` for the canonical status.
- GEP-31 is shipped on Linux: `network: proxy` now wraps the sandbox
  launch in `pasta`, so only the per-company proxy port is reachable
  inside the agent netns.
- Native-provider support is in place: provider registry, built-in
  `openai` / `openrouter`, internal `glorbo harness`, native
  `usage.json`, and audit replay for native tool activity.
- The native tool catalog on `main` is:
  `read_file`, `write_file`, `edit_file`, `glob`, `grep`, `bash`,
  `web_fetch`.
- Native runtime knobs are now threaded end-to-end:
  `http_timeout_s`, `http_max_retries`, `web_fetch_timeout_s`, and
  `max_tool_calls_per_turn`.
- Budget ledger rows are now company-scoped, so per-agent caps,
  company caps, and spend widgets do not bleed across companies that
  reuse the same agent slug.
- Threatmodel waves 1-8 are complete, and the medium-severity queue is
  now at zero.
- GEP-33 is **Implemented** — git history layer for `~/.glorbo/` (init,
  status, log, show, diff, restore).
- Core docs are aligned with the current release surface:
  `CHANGELOG.md`, `README.md`, `docs/DESIGN.md`,
  `docs/architecture.md`, and `docs/todo.md`.

## Security Status

- Open findings in `docs/testing/threatmodel.md`: `63`
- Breakdown: `0` critical, `0` high, `0` medium, `39` low,
  `24` informational

## Next Implementation Target

- Primary next coding target: **resume the low-severity threatmodel
  queue**
- Planned scope: keep closing bounded DoS / integrity gaps now that the
  open medium count is `0`
- Secondary feature target: see `docs/todo.md` for the live punch list.
  (GEP-33 — git history — has since shipped; this snapshot's target list
  is historical. Treat the cairn docs as authoritative.)

## Remaining Work Themes

- Close the remaining low/informational threatmodel findings
- Extend the native harness beyond the phase 2b tool/runtime batch
- Address follow-up scheduler/performance and UI polish items from
  `docs/todo.md`

## Release Rule

- Delivered GEP => cut a new **minor** version
- Big batch of fixes/refinements => cut a new **patch** version
