# Visual-regression baselines (GEP-44)

Per-LV PNG baselines for Glorbo's Tier-1 dashboard surfaces. Captured
through Playwright + headless Chromium against a deterministic
fixture-seeded `mix phx.server`. Compared via pixelmatch.

## Layout

- `current/` → symlink to the most recent baseline set (consult this
  via `bash scripts/ui-baseline.sh check`).
- `<YYYY-MM-DD>-v<X.Y.Z>/` — one directory per release-cut baseline.
  Eight PNGs named `01-overview.png` through `08-health.png` matching
  the page list in `scripts/ui-baseline.sh`.

## Workflow

```sh
# Drift check (does NOT update baselines):
bash scripts/ui-baseline.sh check
# → exits 1 if any LV's pixel delta exceeds 0.5%; writes
#   <screen>-diff.png alongside the failing baseline so you can
#   eyeball what changed.

# Update baselines (after an intended UI change):
bash scripts/ui-baseline.sh update
# → captures into a new dated dir, repoints current/ symlink.
#   Commit both the new dir + the updated symlink in the same PR
#   as the UI change so the visual delta lands alongside the code
#   delta in review.
```

## Threshold

**0.5% pixel delta** per page. Configured in
`scripts/ui-baseline.sh`'s `THRESHOLD_PCT`. Per-LV overrides are not
yet implemented — if you find a Tier-1 LV that consistently flakes
above 0.5%, file a follow-up to either add an override OR mask the
flaky region in the harness.

## Page list

### Tier-1 — Director-daily surfaces

| #  | LV         | URL                                  |
|----|------------|--------------------------------------|
| 01 | overview   | `/companies`                         |
| 02 | company    | `/companies/acme`                    |
| 03 | kanban     | `/companies/acme/kanban`             |
| 04 | audit      | `/companies/acme/audit`              |
| 05 | inbox      | `/companies/acme/inbox`              |
| 06 | agent      | `/companies/acme/agents/ceo`         |
| 07 | task       | `/companies/acme/tasks/inbox-01`     |
| 08 | health     | `/health`                            |

### Tier-2 — Secondary collaboration + governance

| #  | LV         | URL                                  |
|----|------------|--------------------------------------|
| 09 | channel    | `/companies/acme/channels/general`   |
| 10 | goals      | `/companies/acme/goals`              |
| 11 | proposals  | `/companies/acme/proposals`          |
| 12 | providers  | `/providers`                         |
| 13 | costs      | `/costs`                             |

Tier-3 (task_chain, benchmarks, brain_dump, skills, project)
expansion is queued per the GEP-44 rollout plan.

## When to update vs investigate

| diff %       | meaning                                          | action                    |
|--------------|--------------------------------------------------|---------------------------|
| < 0.1%       | sub-pixel render variance                        | within tolerance, ignore  |
| 0.1% – 0.5%  | minor styling tweak, copy change, or icon swap   | within tolerance, ignore  |
| 0.5% – 5%    | real UI change — check if intentional            | update if intended        |
| > 5%         | likely a regression: missing region, broken modal, etc. | investigate before updating |

See [`docs/geps/0044-visual-regression-baselines.md`](../../../docs/geps/0044-visual-regression-baselines.md) for the
full design.
