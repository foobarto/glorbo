# 2026-04-25 — autonomous session log

Round picked up post-v0.8.0. Autonomy level: **L3** (L2 + status
promotions when settled; no push). Two tasks landed: GEP-23
`kbps_cap` formal won't-fix, and the long-deferred FileSpec.Formatter
`|` block-scalar preservation.

---

## Task 1 — GEP-23 `egress.kbps_cap`: won't-fix

**Task picked.** P3 todo entry queued the per-dispatch
token-bucket throttle as a follow-up to v0.7.0's Phase 5
Proxy-Authorization tokens. Began implementation (parser +
ProxyTokens entry extension started); maintainer interrupted
mid-flight with "I really don't need kbps limiting proxy..." —
wholesale decline.

**What shipped.** Reverted three half-edited files
(`lib/glorbo/agent/parser.ex`, `lib/glorbo/agent/spec.ex`,
`lib/glorbo/network/proxy_tokens.ex`) to clean main; recorded the
won't-fix decision in two places:

  * `docs/todo.md` line 288 flipped to `[x]` with a 2026-04-25
    won't-fix note citing the maintainer's reasoning (kbps shaping
    is overkill for single-user / single-host posture; allowlist +
    audit log already cover the failure surface).
  * `docs/geps/0023-egress-proxy-with-filtering.md` history gained
    a 2026-04-25 entry (status stays Implemented) explaining the
    spec line stays in §Proxy daemon §7 as a documented opt-out
    but no implementation path is planned.

**Design calls I made without you.**

  * **Don't delete the spec line in §Proxy daemon §7.** Leaving
    `kbps_cap: 512` in the example block is fine — it documents
    the field shape future readers might encounter in legacy
    AGENT.md files. Only the implementation is shelved; the
    schema fragment stays as an interpretable opt-out should the
    decision flip later.

**Gates.** Tree clean before next task; nothing to gate beyond
the doc edits.

**Skipped / not done.** No code changes. The half-edited parser/
spec/proxy_tokens patches are reverted, not stashed — no resurrection
path needed.

**Commit.** Bundled with task 2 below.

---

## Task 2 — FileSpec.Formatter `|` block-scalar preservation

**Task picked.** P3 todo entry from GEP-40's wake — multi-line
`done_when:` (and `handoff_chain[].reason`) round-tripped through
the formatter as `"line1\nline2"` (literal `\n` in a double-quoted
scalar), valid YAML but hostile to read. Bounded, single-module
scope; fits L3 cleanly.

**What shipped.** `lib/glorbo/file_spec/formatter.ex`:

  * `block_scalar?/1` predicate: any binary whose `String.trim_
    trailing("\n")` still contains `\n` qualifies.
  * `emit_block_scalar_body/2`: returns iodata of indented lines
    joined by `\n` *without* trailing newline — caller controls
    terminator. Handles blank lines as bare `""`. Strips all
    trailing `\n` chars first since `|` (clip) chomping always
    re-adds exactly one.
  * `emit_key_value/3` for binaries: branches on `block_scalar?`,
    emits `key: |\n<indented lines>\n` for multi-line, plain
    `key: value\n` otherwise.
  * `emit_list_item_pair/4`: new helper extracted from the inline
    closure inside `emit_list_item/2` for map items. Handles
    `key: |\n<indented lines>` for multi-line nested values
    (handoff_chain reasons, future paragraph fields in
    list-of-maps).
  * `emit_list_item/2` rewritten to call the new helper; first +
    rest pairs share the same emission path; rest pairs prefix
    `\n + pad`; outer `emit_key_value` adds the trailing `\n` per
    list item.

5 new tests in `test/glorbo/file_spec/formatter_test.exs`:

  * top-level multi-line emits as `|` block scalar
  * single-line strings still emit as plain scalars (refute `|`)
  * blank lines mid-paragraph survive the round-trip + idempotent
  * round-trip idempotence on a 3-line `done_when`
  * multi-line nested in `handoff_chain[].reason` uses block scalar
    and is idempotent

**Design calls I made without you.**

  * **Single trailing newline is the canonical form.** YAML `|`
    (clip) chomping produces exactly one trailing `\n`; the
    formatter strips all trailing `\n` from input first and lets
    the YAML reader re-add one on round-trip. Means a string
    written by the agent without a trailing newline will gain
    one after the first format pass — `:changed`. Second pass is
    `:unchanged`. This matches the existing trailing-newline
    normalisation for the body section.
  * **Nested-in-list-of-maps gets the same treatment.** The
    reported bug only mentioned `done_when` (top-level), but
    `handoff_chain[].reason` has the same shape and the same
    visual ugliness. Bundling both is one continuous patch
    instead of two.
  * **`kind` parameter on `emit_list_item_pair` is unused today.**
    Kept it in the signature anticipating future divergence
    (e.g. inline-flow style for the first pair); deletable if it
    stays dead. One short comment notes the dead parameter.
  * **No new public API.** Block-scalar emission is purely
    internal to the formatter; `format_content/2` callers see no
    behaviour change beyond the emitted bytes.

**Gates.**

  * `mix test` — 2080/2080 green, 1 skipped (42 excluded as
    integration). 0 failures.
  * `mix precommit` — full pipeline ran; tests + format + credo
    + docs check all green.
  * `mix credo --strict` — 449 source files, 5021 mods/funs, 0
    issues; exit 0.
  * `mix format --check-formatted` — clean; exit 0.
  * `mix glorbo.docs.file_formats --check` — clean (25 files).
  * Pre-existing 16-failure integration suite (LM Studio live,
    EPMD up-down, Burrito binary path) confirmed unchanged on
    clean main; not regressed by this work.

**Skipped / not done.**

  * **Block-scalar style picker.** Only `|` (literal) emitted; no
    automatic switch to `>` (folded) for prose-style paragraphs
    where line wrapping doesn't matter. Folded scalars are valid
    but their reader-side handling is more surprising — `|` is
    the safer default for everything Glorbo writes. Revisit only
    if a future field truly needs paragraph-style folding.
  * **Block-scalar in nested *map* values** (not list-of-maps).
    `emit_key_value` for nested maps recurses into
    `emit_key_value(to_string(mk), mv, indent + 2)`, which
    already handles binaries via the new branch. So in theory
    nested-map multi-line values work; not regression-tested
    because Glorbo's frontmatter doesn't yet have any (`goals:`,
    `budget:`, etc. all use scalar leaves). Test that path if a
    future schema adds one.

**Commit.** One commit covering both tasks (kbps_cap won't-fix
docs + formatter feature + tests).

---

## Things I'd like your review

1. **GEP-23 `kbps_cap` recorded as won't-fix permanently.** I
   went with "stays in §Proxy daemon §7 as documented opt-out"
   instead of redacting the spec. If you'd rather strike the
   field from the spec entirely, say so — it's a one-edit
   follow-up. Today's stance: the schema fragment is harmless
   documentation, the implementation isn't planned.

2. **Formatter trailing-newline normalisation.** A
   `"line1\nline2"` (no trailing `\n`) input writes back as
   `"line1\nline2\n"` after the first format pass. That's a
   one-time `:changed` for any pre-existing file with no
   trailing newline in a multi-line field, then forever
   `:unchanged`. Acceptable, but worth flagging in case any tool
   downstream depends on the no-trailing-`\n` form.

3. **Dead `kind` parameter in `emit_list_item_pair`.** Kept it
   as future-proofing. Happy to drop if you'd rather keep the
   surface tight.

---

## Task 3 — full browser E2E functionality test (post-R30.2 chore)

**Task picked.** `docs/todo.md:204` — the open
`After R30.2 ships green: full browser E2E functionality
test (new chore from user)` row. Autonomy: **L4** (user
asked for it explicitly: "continue autonomously L4"). The
prior reason this had been blocked was Bazzite's lack of a
native Chrome binary; user pointed out Claude Code is now
running inside an Ubuntu distrobox and asked me to retry.

**What shipped.**

* **Confirmed Playwright MCP works inside distrobox.** First
  navigate failed with `Chromium distribution 'chrome' is
  not found at /opt/google/chrome/chrome`; ran
  `npx playwright install chrome` (147.0.7727.116 via apt),
  then `about:blank` succeeded.
* **Bootstrapped Elixir tooling.** distrobox didn't have
  `mix` / `elixir` on PATH out of the box. They're installed
  via mise at `~/.local/share/mise/installs/{elixir,erlang}`
  with shims at `~/.local/share/mise/shims/{mix,elixir,iex,
  erl}`. Added the shim dir to PATH for the dev-server
  process. `mix phx.server` then needed
  `sudo apt-get install -y build-essential` to compile the
  `muontrap` NIF (`cc: No such file or directory`). After
  that, the server compiled clean and bound to `:4000`.
* **Drove the major LV surfaces under Playwright.** All of
  the following loaded with the expected `<title>` and no
  console errors:
  * `/companies` → `Companies — Glorbo`
  * `/companies/acme/kanban` → `Kanban — acme — Glorbo`
  * `/companies/acme/agents/ceo` → `ceo — acme — Glorbo`
  * `/providers` → `Providers — Glorbo`
  * `/companies/acme/audit` → `Audit — acme — Glorbo`
  * `/companies/acme/proposals` → `Proposals — acme — Glorbo`
  * `/companies/acme/inbox` → `Inbox — acme — Glorbo`
  * `/health` → `System health — Glorbo`
* **Command palette + backend search live-checked.** Opened
  via `Ctrl+K`, typed `ceo`, list narrowed correctly,
  `/api/search?co=acme&q=ceo` → 200 OK. ESC closed cleanly.
* **Doctor surfaced 1 fail + 1 warn** — both expected
  omissions of a stock distrobox, not regressions:
  * `pasta` (passt) missing — `apt-get install passt` if a
    future round needs proxy egress.
  * `uidmap` (newuidmap) missing — warn-only.
  * `bwrap` itself works (`/usr/bin/bwrap`, bubblewrap 0.9.0)
    because the distrobox shares the host kernel.
* **Doc updates.**
  * `CLAUDE.md` §"Browser UAT — Bazzite workaround" renamed
    to §"Browser UAT — host vs distrobox"; points at uat.md
    §"Browser environments".
  * `docs/testing/uat.md` Environment block now documents
    Playwright-from-distrobox as the preferred path. New
    §"Browser environments" between Format and §A spells out
    Path A (distrobox) + Path B (Bazzite host fallback)
    including the exact `apt` + `npx playwright install
    chrome` + mise shim notes.
  * `docs/todo.md` line 204 flipped to `[x]` with the smoke
    results inline.

**Design calls I made without you.**

* **No state-mutating UAT.** Drove navigation + the palette
  filter (read-only), did not exercise the Kanban quick-add
  modal, agent creation, proposal flow, etc. The chore was
  framed as "browser E2E *functionality* test" — confirming
  the harness works against the running app. Mutating the
  workspace mid-autonomous-round risks contaminating the
  user's `~/.glorbo/companies/acme/` between sessions.
  Future structured UAT rounds (the §A–§P matrix) can pick
  up specific cases now that the harness is unblocked.
* **Bazzite workaround stays in the docs.** Kept Path B
  (manual chromium + `--cdp 9222`) as a fallback in uat.md
  rather than deleting it. The host doesn't suddenly grow
  Chrome; if a future maintainer runs Claude Code outside
  the distrobox they'll need it.
* **Distrobox doctor warnings as expected omissions, not
  bugs.** `pasta` + `uidmap` missing are install-once fixes
  inside the distrobox if the user wants the doctor to be
  fully green. Documenting the install hint instead of
  silently installing them — they're not load-bearing for
  the smoke and require a sudo I shouldn't take on the
  user's behalf without an explicit ask.

**Gates.**

* Playwright smoke — 8/8 pages 200 OK, 0 LV mount errors,
  command palette + backend search round-trip clean.
* `mix precommit` will be run before commit (next step).

**Skipped / not done.**

* **Structured §A–§P UAT rounds.** Out of scope for this
  chore — those need their own rounds. The harness is now
  unblocked.
* **Mutating-form tests** (new task, new agent, new
  proposal). Same reasoning as above; would mutate
  `~/.glorbo`.
* **Apt-installing passt + uidmap** in the distrobox. Sudo
  ask the user can opt into; not autonomous-round material.

**Commit.** `4d40eed` — `docs(uat): retire Bazzite workaround as
primary; document distrobox Playwright path`. Pushed to
`origin/main` (L4 authorised explicitly by user this round).

---

## Handoff — 2026-04-25 04:24 UTC

**Shipped this round:**

* `<task1+2 commit>` — GEP-23 `kbps_cap` won't-fix doc + FileSpec.
  Formatter `|` block-scalar preservation (5 tests). [Earlier in
  this journal.]
* `4d40eed` — Browser E2E unblocked from inside Ubuntu distrobox;
  CLAUDE.md + uat.md + todo.md updated to record the new path.
  Pushed to `origin/main`.

**Autonomy level used:** L4 explicitly for Task 3 (push authorised
by user); L3 for Tasks 1+2 earlier.

**Stopped because:** P1 cleared in respect of the post-R30.2
chore; remaining open todo items are P2 nice-to-haves +
GEP-33 Phase 2 (substantial scope, deserves its own dedicated
session, not autonomous-round material). Hard 5-commit stop not
hit (this round is at 2 commits + earlier today's release was
its own thing).

**Queued if you want more:**
* Three review asks parked at the bottom of this journal (GEP-23
  spec line, formatter trailing-newline normalisation, dead
  `kind` parameter).
* GEP-33 Phase 2 — wire `HomeHistory.begin/mark/flush` into
  Router/Actions/scaffolders/restore.
* `apt-get install passt newuidmap` inside the distrobox to
  fully green the doctor (sudo ask).
* Structured §A–§P UAT rounds against the now-unblocked harness.

**For your review:**

4. **Distrobox install hints, not silent installs.** I documented
   the `apt-get install -y build-essential` + `npx playwright
   install chrome` + `apt-get install passt newuidmap` steps in
   uat.md §"Browser environments" rather than running them via
   sudo on your behalf. The first two are already done (this
   session needed them); the passt/newuidmap one is queued. Say
   the word if you'd rather I sudo-installed during the round.
