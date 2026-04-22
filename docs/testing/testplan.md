# Glorbo — End-User Test Plan

**Scope:** Manual, browser-driven acceptance testing of the Glorbo
dashboard + CLI from the perspective of a first-time user trying to
decide if the product is usable.

**Environment:** Linux dev host with `bwrap` + `inotify-tools` + a
working `claude`/`gemini`/`codex` CLI in PATH. Tests assume
`mix phx.server` running on `http://localhost:4000`.

**Pass/fail philosophy:** a step fails if anything looks broken,
misleading, or confusing — not just if it crashes. Use
`agent-browser` or any Chromium dev tools to inspect the DOM. If a
step reveals a bug, capture a screenshot + the PID/log path and move
on.

---

## 0 · Prerequisites

- [ ] `mix compile --warnings-as-errors` is clean.
- [ ] `mix test` is green.
- [ ] `mix phx.server` boots and binds port 4000.
- [ ] `bwrap --version` works (host AppArmor won't block userns).
- [ ] `~/.glorbo/` doesn't exist yet — we want a first-run scenario
      OR you've moved it aside (`mv ~/.glorbo ~/.glorbo.bak`).

---

## 1 · First-run CLI bootstrap

Goal: a user with no prior Glorbo state installs, runs `glorbo init`,
gets a working filesystem tree, and can start the server without
reading the docs.

- [ ] **1.1 Binary runs with no args** — `./burrito_out/glorbo-linux-x86_64`
      prints a helpful USAGE block and exits 0. No stacktraces.
- [ ] **1.2 Unknown verb is rejected** — `glorbo bogus` exits 1 with a
      clear error naming `bogus`.
- [ ] **1.3 `glorbo init` is idempotent** — run twice; the second run
      says "already materialised" and doesn't overwrite user data.
- [ ] **1.4 `glorbo doctor` is honest** — exit 0 on a healthy tree;
      exit 2 with a numbered checklist when something's missing
      (simulate: `rm ~/.glorbo/companies/acme/company.md` between two
      `doctor` runs).
- [ ] **1.5 `glorbo up` starts the server** — daemonises, writes
      `~/.glorbo/run/glorbo.pid`, prints the dashboard URL.
- [ ] **1.6 `glorbo status` finds the running server** — not by
      `pgrep`, by the pidfile.
- [ ] **1.7 `glorbo down` stops cleanly** — removes the pidfile, port
      4000 is free afterwards.

---

## 2 · Dashboard first impressions

Goal: a user opens `http://localhost:4000/` and can navigate without
guessing.

- [ ] **2.1 `/` redirects to `/companies`** — no 404, no flash of
      wrong content.
- [ ] **2.2 Empty state is helpful** — if no companies exist, the
      page explains how to create one (not a blank table).
- [ ] **2.3 Seeded `acme` company renders a card** — after `glorbo
      init`, the card shows agent count, in-progress tasks, spend (may
      be $0), alerts, and a green health dot. **No lying zeros** —
      values are derived from disk, not hardcoded.
- [ ] **2.4 Sidebar is informative** — agent list, company switcher,
      Doctor-backed health badge at the bottom. The badge is NOT
      always "all systems operational" — it reflects reality.
- [ ] **2.5 Keyboard shortcuts work** — press `?` to open the
      cheatsheet, `Cmd+K` opens the command palette, `g c` jumps to
      companies. ESC closes modals.
- [ ] **2.6 Tab active state persists** — navigating Kanban ↔ Chat ↔
      Approvals ↔ Audit on the same company always highlights the
      correct tab.

---

## 3 · Company detail view

Goal: a user clicks into `acme` and can scan its state at a glance.

- [ ] **3.1 Header + path crumb match the mockup** — company name,
      `~/.glorbo/companies/acme/company.md` path, quote line.
- [ ] **3.2 Stat row shows 4 cards** — agents alive, open tasks,
      budget, invocations. Sparklines render.
- [ ] **3.3 Agents roster is clickable** — row click navigates to
      `/companies/acme/agents/<slug>`.
- [ ] **3.4 Budget bar renders when tracked** — if an agent has no
      budget cap, no bar shows (NOT a bar at 0%).
- [ ] **3.5 Sub-tabs render** — click "kanban" / "chat" / "approvals"
      / "audit" — each page loads without error, and the correct
      sidebar link stays highlighted.
- [ ] **3.6 Reindex button works** — click "↻ reindex" triggers a
      flash + the agent list refreshes from disk.

---

## 4 · Agent detail view

Goal: a user opens an agent page and can understand its state,
stream its stdout, and wake it up.

- [ ] **4.1 Three-column layout** — identity/workspace left, tabbed
      center, config/budget/permissions right.
- [ ] **4.2 Workspace file tree is correct** — lists files under
      `agents/<slug>/workspace/`; clicking a file opens an editor.
- [ ] **4.3 "NOT MOUNTED" list surfaces** — sibling agents + other
      companies appear as NOT-MOUNTED (kernel-guard visibility).
- [ ] **4.4 Tabs: STDOUT / SANDBOX / INBOX / HISTORY** — each shows
      real data. STDOUT replays last ~32 KiB of `stdout.log`; no
      blank/whitespace rows; ANSI escapes stripped.
- [ ] **4.5 STDOUT persists across reloads** — kill the tab, re-open;
      history replay + backfill works.
- [ ] **4.6 Multiple tabs = no duplicate lines** — open the same
      agent in 2 tabs; STDOUT doesn't show each line twice.
- [ ] **4.7 Permissions list is accurate** — each row tagged "mount"
      or "router" based on `PermissionMapper` output.
- [ ] **4.8 Budget meter has a threshold line at 80%** — verify
      visually; color shifts to amber/rose when appropriate.
- [ ] **4.9 Wake action works** — click "wake now", pick a reason,
      see a flash; `agents/<slug>/state/wake-request.md` appears on
      disk; streamer shows a new dispatch within seconds.
- [ ] **4.10 Stop / edit / DM buttons** — disabled placeholders
      don't LOOK clickable (no hover affordance, tooltip explains why).

---

## 5 · Kanban board

Goal: a user manages tasks without opening a text editor.

- [ ] **5.1 Three columns render** — todo / in progress / done,
      lowercase labels match mockup.
- [ ] **5.2 Seeded tasks appear** — create `acme/projects/demo/tasks/
      t-01.md` with frontmatter; it appears within 1s (inotify or
      polling fallback).
- [ ] **5.3 Drag-and-drop between columns** — drag t-01 from todo to
      done; the frontmatter `status:` is rewritten on disk; the board
      re-renders.
- [ ] **5.4 Click a card → task detail** — edit title, status,
      assigned_to, priority, requires_approval, body. Save writes
      frontmatter + body.
- [ ] **5.5 Autocomplete on assigned_to** — typing "eng" suggests
      existing agent slugs.
- [ ] **5.6 Assigning a task to an agent wakes that agent** — check
      `agents/<slug>/stdout.log` for a new dispatch after save.
- [ ] **5.7 Project filter from URL** — `?project=demo` filters the
      board; deep link works.
- [ ] **5.8 Comment field appends to body** — posting a comment
      preserves prior content and adds the new one.

---

## 6 · Channels & DMs

Goal: a user chats with agents in real time.

- [ ] **6.1 Channel list renders** — sidebar shows `#general`, etc.
- [ ] **6.2 Post a message** — compose form rejects empty, rejects
      >10 KB, succeeds otherwise. No flash of stale content.
- [ ] **6.3 Incoming message renders within 1s** — write `## <ts> |
      <author>\n<body>` to the channel file externally; view
      updates via inotify.
- [ ] **6.4 DMs** — `/dms/<agent>` thread view renders director ↔
      agent messages distinctly.
- [ ] **6.5 Mention → wake** — a message containing `@engineer`
      drops a mention file into `agents/engineer/inbox/mentions/`
      and wakes the agent.
- [ ] **6.6 Markdown renders safely** — bold/italic/code work; raw
      HTML is sanitized (no `<script>` escapes).

---

## 7 · Approval queue

Goal: the director approves or denies agent write actions.

- [ ] **7.1 Sentinels render as pending rows** — an agent writes
      `state/awaiting-approval-t-01.md`; the row appears.
- [ ] **7.2 Click "approve"** — sentinel is deleted, a follow-up
      audit event is written, the agent is woken.
- [ ] **7.3 Click "deny" with reason** — denial reason is persisted
      in the audit log, agent is NOT woken again by the denial (no
      self-loop — #130 regression check).
- [ ] **7.4 Batch approve** — multiple sentinels can be selected and
      approved at once.
- [ ] **7.5 Empty state** — when nothing is awaiting approval, the
      page says so clearly (not a misleading "0 pending" badge).

---

## 8 · Audit log

- [ ] **8.1 Current-month tail renders** — last 500 entries from
      `audit/YYYY-MM.jsonl`.
- [ ] **8.2 Filters work** — actor, action, free-text search all
      filter client-side without reloading.
- [ ] **8.3 Realtime append** — trigger a wake; the new audit event
      appears within 1s (PubSub, not 15s poll).
- [ ] **8.4 Load older** — "Load 500 older" prepends; reaching the
      file start replaces the button with "— beginning of log —".
- [ ] **8.5 Row expansion is stable** — expanding row 5 then
      filtering keeps row 5 expanded (not row 5's new neighbour).

---

## 9 · Providers & tweaks

- [ ] **9.1 `/providers` lists each adapter** — claude-code, gemini,
      codex; installed ones show a green status badge, missing ones
      show an install hint.
- [ ] **9.2 TOML snippet per provider** — copy-to-clipboard button
      works.
- [ ] **9.3 `/tweaks` drawer** — density + vocab toggles persist to
      localStorage; UI reflects the toggle immediately.

---

## 10 · Health view

- [ ] **10.1 `/health` lists Doctor probes** — each with pass/fail.
- [ ] **10.2 Supervisors section shows slugs, not PIDs** —
      `acme` + child_count, not `#PID<0.123.0>` (#133 regression).
- [ ] **10.3 Failing probe surfaces in the sidebar footer badge** —
      delete `~/.glorbo/glorbo.db` and reload; badge changes from
      green.

---

## 11 · End-to-end agent flow

Goal: the full round-trip that matters.

- [ ] **11.1 Create a task assigned to `engineer`** — via Kanban UI.
- [ ] **11.2 Agent picks it up** — STDOUT tab shows a dispatch;
      audit log shows `agent.dispatch`.
- [ ] **11.3 Agent responds in a channel** — a `#general` message
      from `engineer` appears within 5s of the dispatch finishing.
- [ ] **11.4 Agent's budget ticks** — the company + agent budget
      bars advance by the invoked cost.
- [ ] **11.5 Agent hits an approval gate** — with a task marked
      `requires_approval: director`, the agent writes a sentinel
      instead of the actual side effect; UI surfaces the pending
      approval.
- [ ] **11.6 Crash isolation** — `kill -9 $(pidof-engineer)`; only
      the engineer restarts. Other agents + the dashboard keep
      serving; no cascading failure.
- [ ] **11.7 Cross-company isolation** — add a second company
      `beta`; an `acme` agent cannot see `beta/`'s files (run
      `ls /companies/beta` from inside the sandbox — should be
      denied at the bwrap layer, not just the Router).

---

## 12 · Error handling & recovery

Goal: the product degrades gracefully, not catastrophically.

- [ ] **12.1 Kill the BEAM mid-dispatch** — `kill -9 $(cat
      ~/.glorbo/run/glorbo.pid)`; agents don't leave orphan
      subprocesses; `glorbo up` restarts cleanly.
- [ ] **12.2 Corrupt an agent.md** — mid-YAML syntax error; the UI
      shows that specific agent as "broken" with a parse_error,
      others keep working.
- [ ] **12.3 SQLite locked** — open the DB in `sqlite3` shell with
      `BEGIN EXCLUSIVE`; dashboard reads still work (journal_mode
      WAL), writes get a clear flash, nothing crashes.
- [ ] **12.4 Disk full** — `fallocate` the partition to near-full;
      audit appends either succeed or fail with a clear error. No
      silent data loss.
- [ ] **12.5 Network down** — pull the Ethernet cable; dashboard
      still renders, provider status shows "unreachable" not an
      uncaught exception.

---

## 13 · Accessibility & polish

Subjective but load-bearing for whether a user *likes* the app.

- [ ] **13.1 Keyboard-only navigation works end-to-end** — Tab, Enter,
      Space, Escape everywhere; no mouse-only affordances.
- [ ] **13.2 Screen-reader labels** — filters + buttons have ARIA
      labels; BudgetRing + HealthDot are distinguishable without
      color.
- [ ] **13.3 Color contrast** — error flash vs info flash are
      distinguishable by more than hue (icon + shape too).
- [ ] **13.4 Relative timestamps** — audit + channels use "3m ago"
      / "2h ago" not raw ISO8601.
- [ ] **13.5 Responsive within reason** — at 1280×720 the layout
      doesn't overflow; no horizontal scrollbar.
- [ ] **13.6 First-paint under 500ms on localhost** — no spinner for
      a full second before the dashboard appears.

---

## 14 · Upgrade & portability

- [ ] **14.1 `glorbo backup`** — produces a single tarball of
      `~/.glorbo/` minus derived SQLite.
- [ ] **14.2 `glorbo restore` on a fresh host** — untar, run
      `glorbo restore <file>`, `glorbo up`: the dashboard returns
      identical companies/agents/tasks/audit.
- [ ] **14.3 `glorbo reindex` is lossless** — delete
      `~/.glorbo/glorbo.db`; reindex; all counts match pre-delete.
- [ ] **14.4 Version mismatch** — downgrade the binary to v0.0.2,
      boot against v0.0.3 data: either upgrade migration runs or
      the CLI refuses cleanly (no silent corruption).

---

## 15 · Security checks (light)

- [ ] **15.1 Cross-company leak** — agent A reads `ls
      /companies/B/agents/` → denied by kernel (EACCES), not just
      the Router.
- [ ] **15.2 Directory traversal in the Kanban open_file** — try
      `path=../../../../etc/passwd`; the server rejects.
- [ ] **15.3 XSS in channel markdown** — post `<img
      src=x onerror=alert(1)>`; renders as literal text.
- [ ] **15.4 Session token not logged** — grep audit + stdout logs
      for `erl_cookie`; no match.
- [ ] **15.5 Sandboxed agent can't reach localhost:4000** — from
      inside the bwrap, `curl localhost:4000` fails (network
      namespace).

---

## Sign-off

- [ ] All sections above marked pass, or each failure has a
      corresponding issue + screenshot under `.reports/`.
- [ ] No regressions from the latest `CHANGELOG.md` entry.
- [ ] A new user, given only `README.md`, can complete sections 1–5
      without asking for help.
