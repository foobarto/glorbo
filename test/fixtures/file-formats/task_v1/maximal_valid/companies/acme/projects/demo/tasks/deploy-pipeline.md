---
kind: task/v1
id: deploy-pipeline
title: Implement the new deployment pipeline
status: in-progress
assigned_to: engineer
requested_by: director
priority: high
severity: major
goal: release-v1
requires_approval: director
peer_review_required: true
reviewer: critiqueops
provider: claude-code
model: claude-sonnet-4-5
created_at: "2026-04-24T14:00:00Z"
created_by: director
done_when: pipeline deploys from main on green CI; runbook at projects/ops/runbook.md; tested on staging
handoff_chain:
  - from: director
    reason: initial dispatch
    to: ceo
    ts: "2026-04-24T14:00:00Z"
  - from: ceo
    reason: needs plan before build
    to: researcher
    ts: "2026-04-24T14:05:00Z"
  - from: researcher
    reason: plan at /projects/ops/tasks/deploy-plan-1.md; please implement
    to: engineer
    ts: "2026-04-24T14:35:00Z"
---
# Implement the new deployment pipeline

Exercises the full `task/v1` frontmatter surface including the
GEP-40 additions (`requested_by`, `severity`,
`peer_review_required`, `reviewer`, `done_when`,
`handoff_chain`) alongside all pre-existing optional fields.

Used as the golden maximal-valid fixture for:

- `FileSpec.classify_by_path/1` → `task/v1`.
- `FileSpec.Validator` → zero error findings.
- `FileSpec.Formatter.format_content/2` → byte-exact round-trip
  (canonical form; second format is `:unchanged`).

The `done_when:` field uses a single-line scalar rather than a
multi-line block-scalar because `FileSpec.Formatter` currently
re-emits block scalars as double-quoted strings with literal
newlines (ugly but valid). Follow-up: extend the formatter to
preserve `|` block-scalar notation for multi-line strings —
user-facing fields like `done_when:` deserve readable output.
