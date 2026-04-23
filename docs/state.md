# State

Last updated: 2026-04-23

> Maintenance note: keep this file updated whenever a GEP ships, a
> release is cut, threatmodel counts change, or the current primary
> implementation target changes.

## Repo

- Branch: `main`
- Worktree status: check with `git status --short`
- HEAD: check with `git log -1 --oneline`
- Latest shipped version: `v0.4.1`

## Implementation Status

- GEP-32 is implemented through **phase 2b** and shipped in `v0.4.0`.
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
- GEP-33 exists as a draft only; it is not implemented yet.
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
- Secondary feature target: GEP-33 remains draft-only and is the next
  larger design/implementation track once the next hardening batch is
  chosen

## Remaining Work Themes

- Close the remaining low/informational threatmodel findings
- Extend the native harness beyond the phase 2b tool/runtime batch
- Address follow-up scheduler/performance and UI polish items from
  `docs/todo.md`

## Release Rule

- Delivered GEP => cut a new **minor** version
- Big batch of fixes/refinements => cut a new **patch** version
