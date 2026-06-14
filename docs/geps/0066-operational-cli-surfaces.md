---
gep: 66
title: Operational surfaces — content search + systemd-unit lifecycle
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
type: Standards
created: 2026-06-14
requires: [6, 48]
see-also: [30, 58]
history:
  - date: 2026-06-14
    status: Implemented
    note: |
      Retroactive governance GEP. Two shipped operational surfaces had no
      governing GEP (flagged by the 2026-06-14 reconciliation audit): the
      content-search backend behind the Ctrl+K palette
      (`lib/glorbo/search.ex`, `GET /api/search`) and the systemd-unit
      lifecycle (`lib/glorbo/cli/install.ex`, `glorbo install|uninstall`).
      Both are minor, host-integration surfaces; this GEP records their
      as-built contracts in one place. Descriptive, not a change.
---

# GEP-66: Operational surfaces — content search + systemd-unit lifecycle

Two small, shipped surfaces that touch the host or the dashboard's read path
and previously had no design record. Grouped here because each is too small for
its own GEP but both are real user-facing/host-integration contracts.

## A. Content search (`Glorbo.Search`, `GET /api/search`)

### Problem

The Ctrl+K command palette (GEP-30/20) needs a fast "find a task or audit event"
backend. It pre-dates the semantic recall index (GEP-58) and is a pure keyword
scan, not a vector search.

### Contract

- **Sources (merged + ranked together):** task titles / IDs / `schedule:` tags
  under `projects/*/tasks/*.md` (ETS-cached by `(path, mtime)`), and the current
  month's `audit/YYYY-MM.jsonl` rows (matched on `actor`, `action`, `target`).
- Each result carries `kind` (`"task"` | `"audit"`), a human `label`, and an
  `href` to navigate to.
- **Route:** `GET /api/search?co=<slug>&q=<prefix>`, behind the
  `:dashboard_api` pipeline — it fetches the browser session and runs
  `GlorboWeb.DirectorAuth`, so it is **session-gated** like the rest of the
  dashboard. A bearer token alone is redirected to `/login`
  (`SearchControllerTest`); this is not a token-authenticated or
  unauthenticated surface, and CLI/MCP callers cannot reach it without a
  director session.
- The `schedule:` value is searchable as a substring, so `daily` surfaces every
  daily-scheduled task without grepping audit.

### Relationship to GEP-58

This is the **phase-0 keyword baseline**. GEP-58's semantic recall is an
optional, default-OFF *addition*, not a replacement; the palette keyword path
is always on and needs no opt-in or embeddings.

## B. systemd-unit lifecycle (`Glorbo.CLI.Install`, `glorbo install|uninstall`)

### Problem

Operators want the orchestrator to survive logout / reboot without a manual
`glorbo up`. On Linux this is a user-level systemd unit.

### Contract

- **Linux-only.** `glorbo install` writes `~/.config/systemd/user/glorbo.service`,
  runs `systemctl --user daemon-reload`, then `systemctl --user enable --now`.
  `glorbo uninstall` runs `disable --now` and removes the unit.
- The unit invokes `<self> serve` as `Type=simple` with `Restart=on-failure` —
  the same in-foreground flow as `glorbo serve`, so systemd owns supervision and
  the `up`/`down` pidfile dance is bypassed entirely.
- This is the one Glorbo write **outside `~/.glorbo/`** (into
  `~/.config/systemd/user/`); `uninstall` removes exactly what `install` wrote.

## Decisions

- **D1. Keyword search stays separate from semantic recall.** Always-on, no
  opt-in, no embeddings — the palette must work on a fresh `glorbo init`.
- **D2. systemd unit runs `serve`, not a bespoke daemon.** One process model
  (`serve`); systemd's `Restart=on-failure` replaces the pidfile supervision
  rather than layering a second mechanism.

## Related

- **GEP-30 / GEP-20** — the Ctrl+K palette that consumes `/api/search`.
- **GEP-48** — dashboard auth; `/api/search` rides the `:dashboard_api`
  session pipeline (`DirectorAuth`), not the bearer-token path.
- **GEP-58** — semantic recall (the optional layer above this keyword baseline).
- `lib/glorbo/search.ex`, `lib/glorbo_web/controllers/search_controller.ex`,
  `lib/glorbo/cli/install.ex`.
