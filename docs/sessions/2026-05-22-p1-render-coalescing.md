# 2026-05-22 — P1 render-stability fixes (agent_status coalescing)

## Task picked

`/goal fix all P1 issues` — the two open P1 punch-list items, both
render-stability bugs driven by `:agent_status` PubSub churn:

1. Agent-detail page re-render thrash while working (reported 2026-05-21,
   NOT reproduced).
2. Modal click-drop under rapid `agent_status` churn (CompanyLive).

## What shipped

**Root cause (both):** `handle_info({:agent_status, …})` re-rendered
**synchronously on every flip** — `CompanyLive` rebuilt the roster +
stat counts, `AgentLive` rebuilt the whole detail panel via
`load_agent_detail`. The `:file_event` storm was already coalesced
(2026-05-21); `:agent_status` had neither coalescing nor a modal guard.
A looping agent flips status several times/sec → repeated DOM patches →
toolbar/modal click-drop (item 2) + detail-panel thrash (item 1).

**Fix:**
- `LiveHelpers.schedule_coalesced_reload/4` + `clear_reload_pending/2`
  gained a `latch_key` param (default `:reload_pending?`) so two
  independent coalesced streams don't share one pending flag.
- `CompanyLive`: `:agent_status` → durable `working_on_by_slug` map
  (unrendered → empty diff → no DOM patch) + coalesced light reload on
  `:agent_reload_pending?`, deferred while a modal is open (re-arm on
  close), `load_agents` only (not full `load_company_data`).
- `AgentLive`: viewed-agent `:agent_status` → coalesced
  `:coalesced_detail_reload` on `:detail_reload_pending?`; other agents'
  status is now a true no-op (was a pointless `_agent_status_tick`).
- **Durable working-on overlay** applied by *both* the `:file_event`
  (`load_company_data`) and `:agent_status` (`load_agents`) reload paths
  via `apply_working_on/2` — a busy agent's "working on …" line no
  longer vanishes on a filesystem-driven reload.

7 new tests (4 CompanyLive, 2 AgentLive, 1 LiveHelpers) incl. a
regression test (verified to fail without the fix) for the working-on /
file_event interaction.

## Design calls I made without you

- **Coalescing + modal-defer over stable-DOM-ids.** The prior todo note
  offered two options for item 2; I took coalescing because it mirrors
  the already-shipped `:file_event` fix and addresses the same root
  cause (high-frequency re-render). Kept the reload *light* + on its own
  latch — that's why it avoids the "naive full-coalesce regressed
  modal-open" trap (full-coalesce re-rendered the whole page incl. the
  toolbar holding the modal-trigger buttons).
- **Fixed item 1 despite "NOT REPRODUCED".** The reported scrollHeight
  oscillation wasn't reproduced, but the same un-coalesced re-render
  anti-pattern was demonstrably present in `AgentLive`. Shipped the
  principled coalescing fix and left an honest note: if the symptom
  persists it's a different (CSS/viewport) cause needing operator repro.
- **Durable `working_on_by_slug` over per-window pending.** Codex review
  caught that a `:file_event` reload would erase the working-on stamp
  (pre-existing latent bug). Promoted the transient pending map to
  durable per-slug state re-applied by both reload paths.

## Gates

- `mix compile --warnings-as-errors` clean.
- `mix precommit` — 2733 tests, 0 failures, exit 0.
- `mix credo --strict` — 0 issues, exit 0 (full repo).
- Codex review pre-commit: one must-fix (working-on/file_event erase) →
  fixed; re-review confirmed resolved, no new must-fix.
- Regression test verified to fail without the file_event overlay.

## Skipped / not done

- Did **not** convert `AgentLive`'s history panel (audit `prepend`,
  full-list reassign) to a LiveView stream, nor add fixed-height scroll
  CSS — those were the *other* suspects for item 1's symptom but are
  unconfirmed; out of scope without repro.
- No push (commit local only, per standing instruction).

## Commit(s)

- (pending) `fix(dashboard): coalesce :agent_status re-renders to stop
  click-drop + detail thrash`

## Things I'd like your review

1. The coalescing window is 250 ms (matches `:file_event`). Pills +
   "working on" now lag up to 250 ms behind a status flip. Acceptable?
2. Item 1 ("agent-detail thrash") is marked `[x]` on the basis of the
   re-render mechanism being removed, not the original symptom being
   reproduced+fixed. If you still see thrash, it's a separate cause —
   OK to close it this way, or keep it open pending your repro?
