# 2026-06-14 — Web UI full E2E UAT sweep

Goal: full browser E2E test of the dashboard; find any missing /
incomplete / broken features, fix them, update docs.

## Environment

- Isolated dev server: `mix phx.server` on **:4001**, `GLORBO_HOME=/var/tmp/glorbo-uat-0614`
  (canonical `/var` path — the `/home→/var/home` symlink trips SymlinkGuard),
  `glorbo_dev.db`, seeded `acme` (ceo + #general + q3 goal) + a `demo` project
  with 5 tasks across statuses. Live :4000 release untouched.
- Browser: both browser MCPs (`claude-in-chrome`, `playwright`,
  `chrome-devtools-mcp`) want `/opt/google/chrome` which doesn't exist on this
  atomic-Fedora host. Drove Playwright from a Node script using its **bundled
  chromium** instead. Recorded the recipe in `notes.md`.

---

## Task picked: broad route sweep (read-level)

**What shipped:** swept all 20 dashboard routes for `acme`. **19/20 render 200
with zero server errors, zero console errors.** The one "404" (`/search`) was
my test-path mistake — the real endpoint is `/api/search` (Ctrl+K palette JSON,
`scope "/api"`), which works (ranked + fuzzy). Clean baseline.

**Gates:** n/a (read-only).

## Task picked: interaction tests (mutations + file side-effects)

**What shipped:** verified end-to-end, each writing the correct on-disk file:
chat post (append-only channel file), brain-dump capture (daily log + audit),
inbox approval (sentinel → inbox → **approve** flips task to `approved` + audit),
and all four create-modals (new project / task / agent — files created). Search,
audit feed, kanban render all good.

**Found while testing:** the inbox approval queue is fed by
`agents/*/state/awaiting-approval-*.md` **file** globs, while the Gate grants by
a `tasks_approval_state` **DB row** — a hand-made sentinel (no DB row) shows an
approve button but the grant audits `approval.spurious` and never clears the
sentinel. In the real flow `Gate.request_approval` writes both, so this is a
test artifact, not a confirmed product bug — but the file-glob-vs-DB-row split is
worth a hardening pass (logged below, not fixed this session).

**Design calls I made without you:** treated the sentinel-cleanup observation as
a test artifact (my hand-made sentinel bypassed `Gate.request_approval`, so it
lacked the DB row the grant path requires) rather than chasing it as a bug.

## Task picked: static defect discovery (4-agent workflow)

**What shipped:** parallel scan of the web layer. Result: **all 82 LiveView
events have handlers** (no crash-on-click), **all 9 create/mutation flows
complete**, **no dead links**. Two real incomplete features surfaced (below).

## Task picked: FIX — slug `pattern=` crashes in modern Chrome

**What shipped:** all five "new" modals (company/agent/project/channel/goal)
carried `pattern="…[-…]…"`; Chrome compiles `pattern` with the RegExp `v` flag,
under which an unescaped hyphen in a char class is a `SyntaxError` — an uncaught
console error on every modal open **and** silently-disabled client validation.
Escaped the hyphen (`\-`) in all five (verified the `v`-safe form in node).
Browser-verified: 0 pattern errors on all five modals.

**Gates:** compile (warnings-as-errors) ✓; goals/channel/overview/company
LiveView suites 78 passed ✓; browser-verified ✓.

## Task picked: FIX — TaskLive dropped body edits + bypassed the approval gate

**What shipped:** `/companies/:co/tasks/:id`'s `save_task` (a) silently discarded
prompt-body edits (body editing was Kanban-only) and (b) lacked the approval-gate
guard the Kanban shelf got in PR #37 (could flip a `requires_approval: director`
task straight to `done`). Both stem from the two `save_task` handlers having
drifted. Extracted the guards into a shared **`GlorboWeb.TaskApprovalGuard`**
(Kanban now delegates), and wired body writes into TaskLive — with a
`maybe_write_body/2` that **preserves** the body on a body-less submit (a plain
`write_body("")` would blank it). Browser-verified: body persists; gated→done is
refused and stays `todo`.

**Gates:** compile (warnings-as-errors) ✓; `mix format` ✓; task_live +
kanban_live 79 passed (+3 new regression tests: body persists, body-less save
preserves, gated→done refused) ✓; browser-verified all three ✓.

**Design calls I made without you:**
- Extracted a shared guard module rather than copy-pasting the guards into
  TaskLive — the drift between the two copies is exactly what caused the bug.
- Kept Kanban's call sites unchanged (thin private delegations) to minimise risk
  to the working kanban.
- Made TaskLive's body write conditional on the form carrying the field (safer
  than Kanban's unconditional `Map.get(params,"body","")`, which blanks on absent).

---

## Skipped / not done (deliberate)

- **Chat drawer only tails `#general`** (channel switch is `#TBD` in
  `chat_drawer.ex`). This is a documented deferral, not broken — the full chat
  view at `/companies/:co/channels/:channel` does switch channels. Left as a
  known limitation, not a bug fix.
- **Approval source divergence** (file-glob inbox vs DB-row Gate). Logged in
  `docs/todo.md`; needs a focused hardening pass with the real
  `Gate.request_approval` flow, out of scope for this UAT.
- **`docs/testing/uat.md`** had uncommitted operator edits — left untouched to
  avoid clobbering in-progress work.

## Commit(s)

- (pending) one commit on a feature branch: the 5 pattern fixes + the
  TaskApprovalGuard extraction + TaskLive body/gate fix + 3 regression tests +
  CHANGELOG + notes.md + this journal.

---

## Things I'd like your review

1. **Approve the approach on the two fixes** — shared `TaskApprovalGuard` +
   conditional body write. Any objection to TaskLive now refusing gated→done
   (it previously wrote it and relied on the Gate watcher to revert)?
2. **Chat-drawer channel switching** — want it built (small feature, GEP-less),
   or leave as the documented #general-only tail?
3. **The approval file-glob vs DB-row divergence** — worth a hardening GEP, or
   acceptable since the real `request_approval` writes both?
