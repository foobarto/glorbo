# Example Publishing Co (EXA) — Glorbo UAT Benchmark

Reference dataset for validating Glorbo's agent-company runtime
against a real Paperclip company that produced substantial deliverables
over ~10 days on a local machine.

- **Source instance:** local Paperclip, `http://localhost:3100`
- **Company id:** `fd740b88-1c18-4cb4-8687-cb2208667856`
- **Issue prefix:** `EXA`
- **Snapshot date:** 2026-04-23
- **Workspace on disk:** `<paperclip-workspace>`

Use this document as the oracle when running Glorbo through the same
scenarios: the expected agent mix, the expected interaction patterns,
and the expected *shape* of artifacts that should land on disk.

---

## 1. Company profile

- **Name:** Example Publishing Co
- **Mission (goal 2fa4a3d1):** "A sci-fi and fantasy book publishing
  company. The goal is to hire and evolve talented writers and publish
  their books."
- **Board approval for new agents:** required
- **Projects:**
  - `Onboarding` (in_progress) — goal-linked seed project
  - `Books` (planned) — canonical writers' output project
- **Primary workspace:** `<paperclip-workspace>`
- **Snapshot counts:**
  - 416 issues total (`issueCounter`)
  - 351 done, 57 open, 1 in_progress, 9 blocked
  - 33 currently pending human attention (24 `in_review`, 9 `blocked`);
    18 of those assigned directly to `local-board`
  - 13 approvals total: 9 hire, 2 ceo-strategy, 1 request_board_approval,
    1 budget_override. 10 approved, 2 rejected, 1 pending.

### Agent roster (9 total, 8 active)

Reporting chain — the CEO is root:

```
CEO (codex_local, xhigh)
├── CMO                — Chief Marketing Officer
│   ├── SciFiWriter    — Resident Sci-Fi & Fantasy Writer (opencode_local, qwen3.6-35b)
│   ├── FantasyWriter    — Resident Progression Fantasy Writer (opencode_local)
│   └── CritiqueOps    — Speculative Fiction QA & Critique Reader
├── CTO (codex_local, high)
│   └── AudioOps       — Audiobook Production Engineer
├── PeopleOps          — Head of People Operations
└── UXDesigner        — Book Cover & Visual Design Lead
```

**Adapter mix:** 5 `codex_local` (governance / engineering / ops),
3 `opencode_local` (creative), 1 TBD. Every agent has a managed
`AGENTS.md` instruction bundle under the Paperclip instance data dir;
heartbeat interval 3600s, wake-on-demand enabled, 1 concurrent run
(except CTO with 4).

---

## 2. Workspace topology

Canonical on-disk layout — the benchmark cares about this because it's
what Glorbo has to reproduce on a writer-company workload:

```
exampleco/
├── README.md                       # shared-doc root conventions
├── executive-decisions.md          # board/CEO/CTO durable governance
├── technical-decisions.md          # tooling/workflow/production stack
├── books/                          # per-book canonical per-chapter markdown
│   ├── book-a/             # 271 chapter*.md files
│   ├── book-b/          # 126 chapter*.md files
│   ├── book-a-alt/             # 130 chapter*.md files
│   └── audiobooks/                 # legacy path, superseded by releases/
├── deliverables/                   # 137 per-issue folders (EXA-16, EXA-42, ...)
│   └── EXA-<N>/                    # task-local artifacts, keyed by issue id
│       └── {memo,handoff,manuscript}*.md
├── publishing-status/
│   ├── registry.json               # source of truth for what's published
│   ├── notifier-state.json         # idempotent board-notification ledger
│   └── manuscript-structures/
├── releases/
│   ├── books/<slug>/{candidates,finals}/<build-slug>/
│   └── audiobooks/<slug>/{candidates,finals}/<build-slug>/
├── tools/                          # python scripts for TTS, packaging, sync
│   ├── sync_book_chapters.py
│   ├── notify_board.py
│   └── render_*.py / build_*.py (audio pipelines)
└── tests/                          # pytest sanity tests for tooling
```

**Load-bearing conventions encoded by board-directed governance issues
(EXA-96, EXA-98, EXA-99, EXA-101, EXA-235, EXA-319):**

- Task-local artifacts live under `deliverables/<ISSUE-ID>/`; never
  repeat the ticket id in filenames inside.
- Cross-ticket durable decisions promote *up* to root-level
  `*-decisions.md` domain files — `executive-`, `technical-`, or
  `deliverables/EXA-97/creative-decisions.md`.
- Per-chapter markdown under `books/<slug>/chapterN.md` is *generated*
  via `tools/sync_book_chapters.py` from registry-tracked manuscripts —
  not hand-edited.
- Shippable builds go under `releases/`; `books/` keeps compatibility
  symlinks for legacy consumers.

---

## 3. Governance model

### 3.1 Approvals the board owns

| Type                          | Count | Notes                                                          |
|-------------------------------|-------|----------------------------------------------------------------|
| `hire_agent`                  | 9     | Every new direct-report hire; 2 rejected, 7 approved           |
| `approve_ceo_strategy`        | 2     | Strategic pivots (e.g. portfolio scope)                        |
| `request_board_approval`      | 1     | Generic board-decision surface                                 |
| `budget_override_required`    | 1     | Triggered when a budget threshold would be crossed             |

All decided by user id `board` (10) or `local-board` (2); 1 still
pending.

### 3.2 Board-originated steering tickets

13 issues in the done set were created by the human user
`local-board`. These are the *human directive surface*. Representative
examples — Glorbo must be able to accept identical prompts and route
them equivalently:

- **Hiring steering** — EXA-2 "Hire PeopleOps/HR", EXA-7 "Create a
  new agent"
- **Workflow policy** — EXA-56 "When a book or new chapter is drafted
  or released notify human board", EXA-216 "When wanting to get CMO
  involved in a task reassign it to him and move task to TODO state"
- **Product direction** — EXA-60 "Feasibility study into creating
  Audiobooks with help of AI", EXA-235 "Create a full manuscript for
  Book A (Book 1)", EXA-308 "Brainstorm with writers
  importance of good villain", EXA-314 "Transition Book A to a
  trilogy", EXA-358 "Use finalized version of Book A trilogy as
  canon"
- **Release gating** — EXA-318 "Create releases/ folder and make sure
  to drop each book/audiobook release candidates and finals", EXA-339
  "Book A RC4 to final version"
- **Tech-stack research** — EXA-283 "Create POC of audiobook using
  Chatterbox (Resemble)", EXA-324 "Research options for local TTS
  audiobook generation that could compete with ElevenLabs"

### 3.3 Shared-doc decision log

Three canonical domain files under the project root (not inside
`deliverables/`):

- `executive-decisions.md` — durable operating-governance rules
  with `Sources:` back-links to the deciding issues.
- `technical-decisions.md` — canonical per-chapter book copies,
  artifact layout, compiled full-manuscript packaging rules, release
  artifact layout, TTS path selection.
- `deliverables/EXA-97/creative-decisions.md` — creative line
  direction (exception: lives under the seeding issue).

Append-only with a `## Decision History Notes` section; each decision
block carries a `Sources:` bullet list of `[EXA-NNN](/EXA/issues/EXA-NNN)`
links.

---

## 4. Canonical interaction patterns (6 flows to replay)

These are the load-bearing patterns Glorbo should be able to drive an
equivalent company through. Each has a reference ticket chain.

### Flow A — Board → CEO steering (EXA-56)

1. Human (`local-board`) creates an issue assigned to CEO with a
   policy ask (here: "notify me when chapters ship").
2. CEO drops a `## Delegated` comment, creates child `EXA-57` routed
   to CTO.
3. CEO heartbeats post recurring `## Monitoring` comments summarising
   child-task state; no escalation required.
4. Once CTO ships, CEO posts `## Status` then `## Update` closing
   the oversight ticket with `done` + deliverable links.

**Invariants to test:** CEO never checks out a child, only monitors;
monitoring comments are idempotent/low-noise; oversight closes cleanly
once execution lands.

### Flow B — Hire approval loop (EXA-1)

1. CEO creates `hire_agent` approval + pending direct-report agent
   shell (e.g. CMO at `9a8c8af3-...`).
2. Approval is surfaced to the board.
3. On board approve, Paperclip wakes CEO with `PAPERCLIP_APPROVAL_ID`.
4. CEO delegates first tasks (hiring plan EXA-3, recruiting EXA-18,
   terms EXA-19) under the new CMO.
5. CEO posts sequential `## Update` comments narrating the unblock
   ("blocker resolved → hiring plan → CEO approval → terms").

**Invariants to test:** rejected approval path (2 rejected hires
exist); pending-agent shell cleanup on rejection; CEO wake fires
exactly once per resolution.

### Flow C — Writer ⇄ Critique revision loop (EXA-202 → EXA-205)

A single book chapter takes a multi-ticket dance:

```
SciFiWriter drafts manuscript tranche (EXA-202)
   └─ deliverables/EXA-202/<manuscript>.md
      ↓ hand off to CritiqueOps
CritiqueOps runs developmental critique (EXA-205)
   └─ deliverables/EXA-205/<critique-memo>.md
   └─ deliverables/EXA-205/<cmo-handoff-note>.md
      ↓ recommendation: advance | pause
         advance → next draft tranche (EXA-208...)
         pause  → revision back to writer
         stalled (N non-improving cycles) → escalate to CMO, status=todo
```

The EXA-205 ancestor chain is 17 issues deep
(EXA-42→43→44→49→70→83→94→...→202→205) — this is how a full novel is
built. `Book B` has 126 registry-tracked chapters this
way; `Book A` has 271.

**Invariants to test:** severity-tagged critique output
(must-fix/should-fix/optional); CMO-escalation rule after repeated
non-improving loops (EXA-216 governance rule); deliverable folder
keyed by issue id only, never by ticket prefix in filenames.

### Flow D — CTO notifier → board review queue (EXA-57 pipeline)

1. CTO ships notification workflow (`tools/notify_board.py` +
   `publishing-status/registry.json` + scheduled routine).
2. On each new drafted/released entity, notifier creates a
   `Board review: <Book> Chapter <N>: <Title> ready for review` issue
   assigned to `local-board`, status `in_review`, description with
   linked source / oversight / registry / artifact paths.
3. `publishing-status/notifier-state.json` is the idempotent ledger;
   running the notifier twice does *not* double-post.
4. Human board clicks through, decisions are recorded as comments
   (not as approvals).

**Invariants to test:** at snapshot there were 18 such issues
currently assigned to `local-board`; re-running the notifier must not
create dupes; the description format is machine-readable (entity_type,
book, chapter, source issue, oversight issue, registry path, artifact
list).

### Flow E — Audio POC → QA → release (EXA-67 → EXA-283 → EXA-291)

Longest-running technical flow, crossing the CTO branch:

1. Board asks "research audiobook feasibility" (EXA-60).
2. CTO scopes (EXA-61) and creates AudioOps agent.
3. AudioOps POC pipelines for each provider: ElevenLabs (EXA-239,
   EXA-266), Chatterbox/Resemble (EXA-283), Voxtral/Mistral (EXA-284),
   Higgs Audio (EXA-322), Kokoro (EXA-282/282-multi), Qwen3-TTS
   (EXA-336).
4. Each POC produces `releases/audiobooks/book-a/candidates/EXA-NNN/`
   output (mp3/wav/m4b).
5. `CritiqueOps` runs listening QA (per technical-decisions.md release
   gate: "Do not ship or swap an outward-facing sample on model-side
   evaluation alone. Require at least one human listening QA pass").
6. Winning path documented in `technical-decisions.md` with
   `Sources:` citing the comparison tickets.

**Invariants to test:** each provider gets its own virtualenv
(`.venv-bla282`, `.venv-chatterbox`, `.venv-qwen3tts`) — no shared
Python state; decisions in `technical-decisions.md` cite EXA-77 /
EXA-78 / EXA-90 / EXA-95 / EXA-91 / EXA-143; blocked tickets
(EXA-284, EXA-322) have explicit blocker comments.

### Flow F — CMO escalation unsticking (EXA-210 → EXA-211 → EXA-216)

When the writer ↔ critique loop stalls: the rule (established by
board in EXA-216) is that CritiqueOps reassigns to CMO, moves status
to `todo`, and posts a concise handoff comment explaining what
stalled. This was codified in CritiqueOps' `AGENTS.md`, `HEARTBEAT.md`,
and `TOOLS.md` after the rule was set.

**Invariants to test:** rule propagation — changing an escalation
rule on the board creates both a decision-log entry AND an update
to the affected agent's instruction bundle in the same ticket.

---

## 5. Deliverable inventory

Aggregates a Glorbo run should at least approach for parity:

### 5.1 Issues
- **416 issues** total, 84% done
- Distribution of done work by agent branch (rough, from the
  first 200 done): CritiqueOps, SciFiWriter, FantasyWriter,
  AudioOps each carry 15-30+ done tickets; PeopleOps owns the
  weekly-review cadence; CTO owns the tooling scaffolds.

### 5.2 Creative output
- **2 tracked books in `publishing-status/registry.json`:**
  - *Book B* — sci-fi, 126 chapters drafted
  - *Book A* — fantasy, 271 chapters drafted
- **1 promoted trilogy release:**
  - `releases/books/book-a-trilogy/finals/`
    - `BOOK 1_ BOOK A (Volume 1 subtitle) - (author redacted).epub`
    - `BOOK 2_ BOOK A (Book A, Volume 2) - Example Publishing Co.epub`
    - `BOOK 3_ BOOK A, VOLUME 3 - (author redacted).epub`
  - Pre-promotion candidate: `candidates/trilogy-rc4/` (matching EPUBs)
  - Historical candidates: `trilogy-reset-rc2/`, `trilogy-reset-rc3/`,
    `legacy-two-volume-split/` (kept for traceability)
- **137 per-issue deliverable folders** under `deliverables/`

### 5.3 Audio output
- 5 audiobook candidate bundles under
  `releases/audiobooks/book-a/candidates/`:
  EXA-266 (ElevenLabs act-i), EXA-282 (Kokoro bm-george),
  EXA-282-multi (Kokoro multi-voice), EXA-283 (Chatterbox turbo),
  EXA-291 (ElevenLabs multi-voice chapter 3, 8 per-speaker clips)
- No promoted audio finals yet (CritiqueOps QA gate holds them)

### 5.4 Tooling (CTO/AudioOps-owned scripts under `tools/`)
- `sync_book_chapters.py` — registry → per-chapter markdown
- `notify_board.py` — idempotent chapter-ready notifier
- `build_full_manuscript.py`, `build_book_release_candidate.py`
- 10+ `render_*` / `benchmark_*` TTS pipeline scripts per provider

---

## 6. UAT success criteria (what a Glorbo rerun must produce)

When Glorbo is asked to drive the same seed ("publish sci-fi and
fantasy books, board approves hires, notify me on new chapters"),
the UAT should grade on these:

### 6.1 Structural parity
- [ ] CEO exists from day 0, does not take execution, uses monitoring
      comments only
- [ ] Board-approval gate blocks `hire_agent` creation; approved
      agents materialise as assignable identities; rejected agents
      do not
- [ ] Every agent has a managed `AGENTS.md` instruction bundle in the
      canonical managed path; edits to those files persist across
      restarts
- [ ] Project workspace mapped to a local folder; writer-assigned
      tickets produce artifacts under `deliverables/<ISSUE-ID>/` with
      the required naming conventions (no ticket prefix inside)

### 6.2 Interaction parity
- [ ] Board-created issue triggers a CEO heartbeat; CEO creates a
      child and delegates, does not touch execution
- [ ] Writer → CritiqueOps handoff via reassignment + comment; memo
      deliverable carries must-fix/should-fix/optional buckets
- [ ] CMO-escalation rule fires after N non-improving review loops
      and updates both `executive-decisions.md` and the agent's
      instruction bundle
- [ ] Notifier-style scheduled routine produces idempotent
      `in_review` / `local-board` tickets with the canonical
      description schema (entity_type, book, chapter, source issue,
      oversight issue, registry path, artifact list)

### 6.3 Governance parity
- [ ] Durable decisions get promoted from issue comments to
      `executive-decisions.md` / `technical-decisions.md` with
      `Sources:` back-links
- [ ] Shared decision docs stay in one canonical root file per domain;
      no per-ticket decision-log files are created
- [ ] `publishing-status/registry.json` is the single source of truth
      for what is published; per-chapter markdown is generated from
      it, not hand-edited

### 6.4 Output parity (relaxed — quality not exact)
- [ ] At least one compiled EPUB promoted to `releases/books/<slug>/finals/`
      after a human board review comment
- [ ] At least one audiobook candidate under
      `releases/audiobooks/<slug>/candidates/EXA-NNN/` with an mp3/wav
      output, gated on a CritiqueOps listening-QA ticket before
      promotion to `finals/`
- [ ] Every finals promotion leaves a compatibility symlink or
      explicit decision entry for any legacy path

### 6.5 Anti-patterns (must NOT reproduce)
- [ ] CEO never checks out implementation tickets
- [ ] No duplicate notifier issues for the same
      `(book, chapter, artifactPaths)` tuple
- [ ] Agents never delete or edit another agent's deliverable folder
- [ ] No cross-company state leakage (company isolation must remain
      absolute — Glorbo invariant)

---

## 7. Known special cases to probe

These are gnarly edge cases EXA hit, worth replicating in UAT:

- **Stale heartbeat lock** (EXA-38, EXA-231). A run crashed with the
  execution lock set; follow-up tickets exist to clear it. Glorbo UAT
  should verify `glorbo.lock` / execution-lock cleanup on crash.
- **Voice sample regression** (EXA-91, EXA-143 vs EXA-90). A newer
  render evaluated-well on model metrics but failed human QA; the
  release-gate decision was later promoted as policy. Glorbo should
  let a reviewer revert a model-approved artifact.
- **Portfolio pivot** (EXA-314 → EXA-358). Board decided mid-flight to
  split the two-volume book into a trilogy. Existing candidates under
  `legacy-two-volume-split/` remain on disk for traceability.
- **Stalled loop escalation** (EXA-210/211/216). The very existence
  of these tickets means the primary writer/critique loop can stall;
  the governance rule to break it out to CMO is itself a UAT scenario.
- **Blocked-but-not-cancelled** (EXA-284 Voxtral POC, EXA-322 Higgs
  Audio POC). These never made it — Glorbo UAT should support leaving
  work in `blocked` indefinitely with explicit blocker comments
  rather than force-cancelling.

---

## 8. Replaying EXA on Glorbo (UAT procedure)

1. **Init** — `glorbo` CLI, new company slug `exa-benchmark`,
   board-approval-for-hires ON, primary workspace a fresh temp dir.
2. **Seed board ticket set** — submit the 13 `local-board`-style
   prompts listed in §3.2 as if typed by a human (start with EXA-2,
   EXA-56, EXA-60; add the rest after the CMO branch exists).
3. **Run heartbeats** — 24h simulated wall-time, wake-on-demand
   enabled, 10-second cooldown (matches EXA runtimeConfig).
4. **Grade** — walk the §6 checklist against the workspace + SQLite
   state at cutoff. Any `[ ]` left unticked is a UAT regression.
5. **Collect diffs** — any novel file paths or conventions Glorbo
   chose that *diverge from* §2/§3 are bug reports unless board
   direction made them mandatory.

Grading bar for v1.0: §6.1 + §6.2 + §6.3 must be 100%; §6.4 can be
50% (quality of generated prose is out of scope for Glorbo UAT).

---

## Appendix — load-bearing issue IDs

Fast-index for tooling that wants to replay specific flows:

| Flow | Key IDs |
|------|---------|
| Board → CEO steering | EXA-56, EXA-60, EXA-216, EXA-235, EXA-314 |
| Hire approval        | EXA-1, EXA-2, EXA-5, EXA-7, EXA-19, approval 95ce7610 |
| Writer ↔ Critique    | EXA-42, EXA-49, EXA-70, EXA-83, EXA-94, EXA-202, EXA-205, EXA-208 |
| CTO notifier         | EXA-56, EXA-57, EXA-69 (oversight), EXA-154-EXA-158 (sample output) |
| Audio POC            | EXA-60, EXA-67, EXA-239, EXA-266, EXA-283, EXA-291, EXA-322, EXA-336 |
| CMO escalation       | EXA-210, EXA-211, EXA-216 |
| Release packaging    | EXA-235, EXA-318, EXA-319, EXA-339, EXA-358 |
| Decision logs        | EXA-96, EXA-98, EXA-99, EXA-101, EXA-319 |
