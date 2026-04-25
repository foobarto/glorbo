---
gep: 33
title: Git History Layer for Glorbo Home
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-04-23
requires: [2, 3, 5, 7]
see-also: [11, 19, 21, 25, 27, 32]
history:
  - date: 2026-04-23
    status: Draft
    note: Initial draft after wave-6 security work, grounded in a decision-log review of GEPs 2, 3, 5, 7, 11, 19, and 27.
  - date: 2026-04-25
    status: Draft
    note: |
      Phase 1 partial — `Glorbo.HomeHistory` module landed with
      `init/1` (bootstrap + .gitignore + initial commit),
      `status/1` (porcelain wrap), `log/1` (record-separator
      pretty format), and `tracked?/2` predicate mirroring the
      §3 policy. CLI subcommands `glorbo history {init, status,
      log [--limit N]}` are wired through `Glorbo.CLI.dispatch/1`
      to a new `:history` verb. 19 unit tests
      (`home_history_test.exs` + dispatch coverage).

      Out of scope this round: `show`, `diff`, `restore` (rest of
      §8.1); marked-commit pipeline from host-side write surfaces
      (Phase 2); watcher fallback for manual edits (Phase 3); the
      `Glorbo Kernel <kernel@glorbo.local>` committer + per-actor
      author identity (§4.2). Initial commits use the daemon's
      git env identity for now — Phase 2 wires the kernel/author
      split. `glorbo init` does **not** auto-init history; it
      stays opt-in per §Migration / rollout.

      GEP-33 stays Draft — Phase 1 alone doesn't satisfy the
      design's marked-commit + watcher-fallback core. Status
      flips to Implemented when Phases 2 + 3 land.
  - date: 2026-04-25
    status: Draft
    note: |
      Phase 2a-1 — synchronous commit primitive landed.
      `Glorbo.HomeHistory.commit_marked/3` stages an explicit
      list of paths, applies the §3 tracked-scope filter (drops
      `config.md` / `glorbo.db*` / runtime / cache / agent
      transport paths into a `:skipped` field rather than into a
      commit), writes one commit with `Glorbo Kernel` committer
      + actor-aware author per §4.2, and emits the canonical §4.3
      trailers (`Glorbo-Actor`, `-Action`, `-Target`, `-Source`,
      `-Paths`, `-Tx`).

      Sanitization layer for §12.2: the public
      `HomeHistory.sanitize_trailer/2` strips control chars,
      bounds length, and is the only path trailer values can
      reach git through. Newline-injection round-trip test runs
      `git interpret-trailers --parse` on the output to confirm
      a forged `Glorbo-Actor: attacker` in `target` cannot
      become a real trailer line.

      No-op semantics: an all-skipped path list or a tracked
      list whose contents already match HEAD returns
      `{:ok, %{sha: "", committed: 0}}` — no empty commit.

      Out of scope still: the `begin/mark/flush` GenServer that
      will buffer multi-file logical operations into one commit
      under the §6.1 debounce window (Phase 2b); wiring into
      Router / Actions / scaffolders / restore (Phase 2c); the
      watcher-fallback `External` commit pipeline (Phase 3).
      `glorbo init` still does not auto-init history; this Phase
      adds zero new caller-visible behaviour to the running app —
      it's foundation for Phase 2b. 12 new unit tests added to
      `home_history_test.exs` (31 total in that file).
  - date: 2026-04-25
    status: Draft
    note: |
      Phase 2b — `Glorbo.HomeHistory.Tx` GenServer landed.
      Wraps the Phase 2a-1 `commit_marked/3` primitive with the
      §6.1 debounce coalescer so a multi-file logical operation
      (task approval = task file + audit append, channel send =
      chat log + audit append) lands as one commit instead of
      one per inode event.

      API: `Tx.begin(meta) → {:ok, tx_id}`, `Tx.mark_path(tx_id,
      path)`, `Tx.flush(tx_id) → {:ok, commit_result}`,
      `Tx.cancel(tx_id)`. `start_link/1` accepts `:debounce_ms`
      / `:hard_cap_ms` overrides for tests.

      Debounce semantics: 500 ms inactivity timer (reset on each
      `mark_path`), 2 s hard cap from `begin`. Auto-flush is
      fire-and-forget — failures log a warning and drop the tx;
      caller's authoritative file write already succeeded so the
      working tree stays correct (§12.3). Explicit `flush/1`
      returns the underlying `{:error, _}`.

      "History disabled" path: when `.git/` is absent, `Tx.flush`
      translates the `commit_marked` `{:error, :not_initialised}`
      into `{:ok, %{sha: "", committed: 0, skipped: <paths>}}`
      so Phase 2c callers can ignore the result without
      distinguishing "feature off" from "actually nothing
      changed." Auto-flush in disabled mode logs nothing.

      Wired into `Glorbo.Application` between `ProxyTokens` and
      `CompanySupervisor`. Safe to start with no `.git/`. 12
      tests in `test/glorbo/home_history/tx_test.exs` covering:
      explicit flush happy paths, multi-mark coalescing, debounce
      auto-flush, hard-cap auto-flush under continuous mark
      activity, cancel idempotence, concurrent transactions, the
      history-disabled translation, explicit tx_id preservation,
      and unknown-tx error/silent-drop cases.

      Out of scope still: Phase 2c caller wiring (Router, Actions,
      scaffolders, restore), Phase 3 watcher fallback, Phase 4
      restore UX. The Tx GenServer runs in production but is
      currently unused — only tests exercise it. Phase 2c lands
      next, one writer at a time.
  - date: 2026-04-25
    status: Draft
    note: |
      Phase 2c-0 + 2c-1 — `with_tx/3` convenience helper + first
      writer wired. `Tx.with_tx(meta, fn tx_id -> ... end)` opens a
      tx, runs the body, cancels-on-error, leaves debounce running
      on success. Resilient to a missing Tx server: catches
      `:exit, :noproc` at begin time and runs the body with a
      sentinel id; subsequent `mark_path` calls become silent
      no-ops. Matches §12.3 — a missing history layer must not
      turn writer success into writer failure.

      First writer wired: `Glorbo.Actions.Companies.update/3`.
      Now wraps its `with`-chain in `with_tx`, marks the
      `company.md` write + the current month's audit jsonl path,
      and lets the §6.1 debounce fire one commit covering both.
      Validation failures cancel the tx without committing.

      `commit_marked/3` gained an existence filter: paths that
      are tracked-scope-OK but missing on disk at commit time get
      dropped into `:skipped` rather than failing the whole `git
      add`. Audit jsonls written async by the AuditLog GenServer
      are the motivating case — the writer marks the path
      optimistically; if the audit append hasn't landed yet
      (FakeAudit in tests, or a slow disk in prod), only the
      audit's history-coupling for THIS commit is missed; the
      working-tree audit append itself still succeeds.

      Production gate: under `mix test`, the application supervisor
      skips the canonical Tx server (config :glorbo,
      :start_home_history_tx, false) so each test can pin its own
      Tx instance to a tmp base + claim the canonical name.

      Test surface: 4 `with_tx/3` tests added (happy + error +
      raise + non-tagged-return) + 2 Companies.update integration
      tests (successful update produces a kernel-committed history
      commit with full Glorbo-* trailers; validation failure does
      NOT). 2193 tests across the suite, 0 failures.

      Out of scope still: Phase 2c-2..N — Tasks, Channels, Goals,
      Skills, Projects, Proposals, Agents writers (one PR each).
      Phase 3 watcher fallback. Phase 4 restore UX.
  - date: 2026-04-25
    status: Draft
    note: |
      Phase 2c-2 — shared helpers extracted + 3 more writers
      wired. `HomeHistory.actor_from_string/1` translates
      free-form actor labels into the §4.2 actor variants;
      `HomeHistory.audit_jsonl_path/2` returns the canonical
      current-month audit file path. Both are public API now —
      every Phase 2c writer uses them.

      Writers wired this round (each gets a `task.X` /
      `channel.X` history commit covering the durable file
      write + the audit jsonl path):

        * `Glorbo.Actions.Tasks.create/4`
          (`task.create: companies/<co>/projects/<p>/tasks`)
        * `Glorbo.Actions.Channels.create/3`
          (`channel.create: companies/<co>/channels/<slug>.md`)
        * `Glorbo.Actions.Channels.archive/3`
          (`channel.archive: companies/<co>/channels/<slug>.md`,
          captures both the src and dst paths in `Glorbo-Paths`)

      Companies.update was retrofitted to use the shared helpers
      (drops the now-redundant inline `history_actor/1` +
      audit-path computation).

      Test surface: 6 new integration tests across
      `tasks_test.exs` + `channels_test.exs` asserting:
      kernel-committed history commit lands with the right
      author + trailers; Glorbo-Paths captures the writer's
      surface; validation failures cancel the tx without
      committing.

      Out of scope still: Phase 2c-N for Goals, Skills,
      Projects, Proposals, Agents, Tasks.{trash, archive,
      reassign, record_peer_review_verdict}, plus the Router
      wires (proposal create / decide, memory write). Phase 3
      watcher fallback. Phase 4 restore UX.
  - date: 2026-04-25
    status: Draft
    note: |
      Phase 2c-3 — Projects + Tasks-mutation surface wired.
      Four more writers go through `with_tx`:

        * `Projects.ensure_stub/3` — `project.create:
          companies/<co>/projects/<p>/project.md`. Marks the
          stub + audit jsonl. Returns `:exists` (no-op) when
          the project.md is already on disk; the Tx
          auto-flushes empty.
        * `Projects.update/4` — `project.update: ...`. Marks
          the project.md + audit jsonl.
        * `Tasks.trash/3` — `task.trash: companies/<co>/<rel>`.
          Marks both src (now removed) + dst (timestamped
          trash dest) + audit jsonl.
        * `Tasks.archive_to_history/3` — `task.archive: ...`.
          Marks src + history dest + audit jsonl.

      Refactored `Projects.ensure_stub/3` body into a
      `create_or_skip_stub/7` helper to flatten nesting (credo
      "function body too deep" warning).

      Out of scope still: `Tasks.reassign/4`, `Tasks.
      record_peer_review_verdict/5`, Goals, Skills, Proposals,
      Agents, Inbox writers (the latter mostly write to
      excluded `inbox/` paths per §3.2 so wiring them is a
      no-op). Router-level proposal + memory writes still
      blind. Phase 3 watcher fallback. Phase 4 restore UX.
  - date: 2026-04-25
    status: Draft
    note: |
      Phase 2c-4 — remaining Tasks-mutation surface wired.

        * `Tasks.reassign/4` — `task.reassign`. Marks the
          task md (handoff_chain + assigned_to flip) + audit
          jsonl.
        * `Tasks.record_peer_review_verdict/5` —
          `task.peer_review.<verdict>` (approve / revise /
          block). Marks the task md (verdict frontmatter
          flip) + audit jsonl. Reviewer slug becomes the
          author identity (`{:agent, reviewer_slug}` →
          §4.2). The inbox/state side-effects
          (`clear_request_sentinel`,
          `maybe_send_revise_feedback`) write to excluded
          scope paths so they don't get marked.

      Both functions extracted post-`with` bodies into
      helpers (`do_reassign_write/8`,
      `do_verdict_write/8`) to keep credo's
      nesting-depth check happy after the with_tx layer —
      same refactor pattern as Phase 2c-3's
      `Projects.create_or_skip_stub/7`.

      Out of scope still: Goals, Skills, Proposals, Agents
      writers. Router-level proposal + memory paths. Phase
      3 watcher fallback. Phase 4 restore UX.
  - date: 2026-04-25
    status: Draft
    note: |
      Phase 2c-5 — `Glorbo.Company.Goals.add_goal/3` wired.
      The first non-`Glorbo.Actions.*` writer to receive a
      `with_tx` wrapper. Splices a new goal into
      `company.md` frontmatter atomically (textual splice
      + tmp + rename) and history-commits the change. No
      audit emission is added in this round — Goals.add_goal
      historically didn't audit and conflating the two
      concerns would balloon scope.

      Optional `:actor` opt added (default `"director"`,
      the only legitimate caller today). Future MCP / agent
      flows pass `:actor` explicitly. `do_add_goal_write/5`
      private helper extracted to flatten nesting.

      Out of scope still: Skills + Brain dump LiveView write
      surfaces. Router-level proposal + memory paths. Phase
      3 watcher fallback. Phase 4 restore UX.
  - date: 2026-04-25
    status: Draft
    note: |
      Phase 2c-6 — `Glorbo.Company.Proposals.flip/4` wired.
      Director-side approve/deny flow for GEP-28 proposals.
      Action subjects: `proposal.approved` / `proposal.denied`.
      Marks the proposal md + audit jsonl.

      `do_flip_write/8` extracted from the body to flatten
      nesting after the `with_tx` wrapper.

      Out of scope still: Skills + Brain dump LV write paths.
      Router-side agent-initiated proposal CREATE flow (this
      round only covered the Director-side decision flow).
      Phase 3 watcher fallback. Phase 4 restore UX.
---

# GEP-33: Git History Layer for Glorbo Home

## Problem

Glorbo already has two strong persistence properties:

1. **The filesystem is authoritative** (GEP-3). Tasks, channels,
   proposals, memories, approvals, and audit logs are plain files
   under `~/.glorbo/`.
2. **SQLite is derived** (GEP-7). Reindex reconstructs dashboard
   views from disk; the DB is not the archive.

What Glorbo does **not** have is a first-party history layer for that
filesystem.

Today, when a Director asks:

- "What changed in this task between yesterday and now?"
- "Which exact lines did the agent rewrite in `company.md`?"
- "Can I undo this proposal flip without hand-editing YAML?"
- "What did the tree look like before this approval wave?"

the answers are fragmented:

- The audit log says **that** something happened, but not the full
  diff.
- The current file tree shows **what exists now**, but not the prior
  version.
- A user can manually `git init ~/.glorbo/companies/acme`, but that is
  outside the product, actor metadata is lost, root-level files are not
  covered, and manual discipline is not a system invariant.

This leaves a gap between "filesystem as source of truth" and
"filesystem as durable history." The source-of-truth tree is
human-readable, but it is still only the latest state.

The proposal here is to add a **git-backed, product-managed history
layer** under `~/.glorbo/.git/` so durable Glorbo state gains:

- a native diff/log/restore story,
- stable change identity (`commit SHA`),
- a timeline that spans multiple files in one logical operation,
- and a first-party path for Director archaeology and undo.

The key constraint is that this layer must not break the existing
invariants:

- Git must **not** become a second source of truth.
- Git must **not** weaken GEP-5's kernel-enforced sandbox boundary.
- Git must **not** replace append-only audit JSONL.
- Git must **not** drag runtime noise (`glorbo.db`, logs, pidfiles,
  sockets, scratch dirs) into a commit storm.

## Goals

- Add a first-party, product-managed git repository rooted at
  `~/.glorbo/.git/`.
- Record **durable state changes** as git commits with actor metadata
  attached.
- Cover both:
  - writes that flow through Glorbo's host-side write surfaces
    (`Router`, `Actions`, scaffolders, config writers, restore), and
  - manual/out-of-band filesystem edits detected by the watcher.
- Keep the history layer **derivative**:
  - no runtime path may depend on git for correctness,
  - `glorbo reindex` must continue to rebuild from working-tree files
    alone,
  - disabling history must not break the product.
- Provide safe Director UX for:
  - status,
  - log,
  - show,
  - diff,
  - and path/subtree restore.
- Preserve actor provenance:
  - Director,
  - agent slug,
  - MCP client,
  - system,
  - or external/manual edit.
- Exclude secrets, runtime scratch, and derived churn from the tracked
  set by default.

## Non-goals

- **Git as authority.** The working tree remains authoritative. Git is
  a history mirror of selected files, not a state source the app reads
  during normal operation.
- **Replacing audit JSONL.** Audit remains append-only and structured.
  Git is for diff/undo/archeology, not forensics-grade event logging.
- **Tracking every byte under `~/.glorbo/`.** The repo lives at the
  home root, but the tracked set is narrower than the raw directory
  tree.
- **Tracking secrets in v1.** Raw `config.md` is excluded because
  secret history is harder to rotate than secret files.
- **Tracking ephemeral runtime paths.** `glorbo.db`, `logs/`,
  `runtime/`, `run/`, CLI scratch, and similar churn stay untracked.
- **Live whole-tree time travel.** `glorbo checkout <sha>` against the
  live home directory is too destructive for v1.
- **Remote sync / push / pull.** This GEP defines local history. It
  does not turn Glorbo into a Git remote manager.
- **Commit signing, branch workflows, or merge conflict UX.** Single
  local linear history only.

## Design

### 1. Positioning

The shape is:

- **Filesystem working tree** = source of truth.
- **Git repo under `.git/`** = derivative history of a curated tracked
  subset of that tree.
- **Audit JSONL** = structured append-only record of actions.

Those three surfaces answer different questions:

- Filesystem: "what is true right now?"
- Audit: "who did what, when, to which target?"
- Git: "what changed between A and B, and how do I restore an older
  version?"

Git therefore **coexists** with audit, not replaces it.

This follows GEP-11 directly:

> Archaeology is best served with git, not a parallel tree of stale
> docs.

The "parallel tree" warning is important. The history layer must not
become a hidden authoritative shadow state. The commit graph exists to
describe past working-tree states, not to supersede the working tree.

### 2. Repository location and shape

The repository root is the Glorbo home itself:

```text
~/.glorbo/
├── .git/                    # NEW: managed by HomeHistory
├── .gitignore               # NEW: tracked scope mirror
├── companies/               # tracked subset (durable state only)
├── config.md                # excluded in v1
├── glorbo.db                # ignored
├── logs/                    # ignored
├── runtime/                 # ignored
├── run/                     # ignored
└── cache/                   # ignored in v1
```

Why a single home-root repo instead of per-company repos:

- some user-visible operations span multiple companies or root-level
  files,
- the Director thinks in terms of "Glorbo home," not "14 unrelated git
  repos,"
- and the audit/history story should not fragment when a single action
  mutates both an authoritative file and the matching monthly audit log.

Per-company repos were considered and rejected because they would:

- miss root-level state,
- make global operations multi-repo transactions,
- and create awkward UX for `glorbo history log` / `restore`.

### 3. Tracked scope

This GEP does **not** literally track every path under `~/.glorbo/`.
It tracks the durable, user-meaningful subset.

#### 3.1 Included in v1

- `companies/<co>/company.md`
- `companies/<co>/projects/**`
- `companies/<co>/channels/*.md`
- `companies/<co>/proposals/*.md`
- `companies/<co>/audit/*.jsonl`
- `companies/<co>/goals/*.md`
- `companies/<co>/skills/*.md`
- `companies/<co>/agents/<slug>/AGENT.md`
- `companies/<co>/agents/<slug>/agent.md` (legacy)
- `companies/<co>/agents/<slug>/SOUL.md`
- `companies/<co>/agents/<slug>/HEARTBEAT.md`
- `companies/<co>/agents/<slug>/memory/**`
- `companies/<co>/agents/<slug>/history/**` when the archived file is a
  durable markdown artifact rather than runtime scratch
- `.gitignore`

The intended rule is "track durable files that a Director would
reasonably want to diff or restore."

#### 3.2 Excluded in v1

- `.git/**`
- `config.md`
- `glorbo.db`, `glorbo.db-shm`, `glorbo.db-wal`
- `logs/**`
- `runtime/**`
- `run/**`
- `cache/**` including `cache/providers/**`
- `companies/<co>/agents/<slug>/stdout.log`
- `companies/<co>/agents/<slug>/workspace/**`
- `companies/<co>/agents/<slug>/inbox/**`
- `companies/<co>/agents/<slug>/outbox/**`
- `companies/<co>/agents/<slug>/state/**`

Why each excluded family stays out:

- **`config.md`** contains secret-bearing fields (`secret_key_base`,
  dashboard token, Erlang cookie). Git history would preserve old
  values after rotation. Trackability can be revisited only after
  secrets are split out of the file.
- **`glorbo.db*`, logs, runtime, run** are derived or ephemeral and
  would create high-churn, low-signal commits.
- **`cache/providers/**`** is generated state. Useful for rebuilds, but
  not durable user intent. Re-fetching model lists is the right repair
  path; history noise is not.
- **agent inbox/outbox/state/workspace/stdout** are transport or
  scratch. They matter operationally, but not as long-lived source of
  truth.

The repo living at the home root is therefore **not** equivalent to
"everything in the tree is tracked."

### 4. Ownership and actor identity

#### 4.1 Who commits

The **kernel commits**. Concretely:

- a new host-side `Glorbo.HomeHistory` service owns the repo,
- it runs with the same OS user and privileges the daemon already has,
- and it is the only code that invokes git for product-managed history.

Rejected alternatives:

- **per-sandbox user commits** — an agent-owned git process is a design
  bug; it would let the untrusted side influence repo metadata and
  bypass the Router boundary.
- **per-writer ad hoc commits** — too much duplicated logic and no
  coherent batching.
- **user-managed git only** — does not satisfy the product goal of
  first-party history.

#### 4.2 Author vs committer

Each commit stores two identities:

- **Committer:** always `Glorbo Kernel <kernel@glorbo.local>`
- **Author:** logical actor:
  - `Director <director@glorbo.local>`
  - `Agent <agent+<slug>@glorbo.local>`
  - `MCP <mcp+<client>@glorbo.local>`
  - `System <system@glorbo.local>`
  - `External <external@glorbo.local>` for manual/out-of-band edits

The committer answers "who wrote the git object?" The author answers
"whose action does this logical change represent?"

This split matters for correctness:

- host-side code writes the commit,
- but the Director still wants to see "this approval was authored by
  director" rather than "kernel, kernel, kernel" forever.

#### 4.3 Structured trailers

Commit messages carry trailers so metadata does not depend on parsing
the subject line:

```text
task.approve: projects/acme/tasks/fix-ci.md

Glorbo-Actor: director
Glorbo-Action: task.approve
Glorbo-Target: companies/acme/projects/fix-ci/tasks/fix-ci.md
Glorbo-Source: actions.set_approval
Glorbo-Paths: companies/acme/projects/fix-ci/tasks/fix-ci.md, companies/acme/audit/2026-04.jsonl
Glorbo-Tx: history-01JV...
```

Trailer values are sanitized to single-line YAML-safe identifier/scalar
shapes before being handed to git.

### 5. Change capture model

The history layer must cover two classes of edits:

1. **Known product writes** where Glorbo already knows actor/action.
2. **Unknown external edits** made with an editor or shell.

One mechanism does not solve both cleanly, so v1 uses a hybrid.

#### 5.1 Marked write transactions

Host-side write surfaces mark logical transactions with:

```elixir
HomeHistory.begin(tx_meta)
HomeHistory.mark_path(tx_id, path)
HomeHistory.flush(tx_id)
```

`tx_meta` includes:

- actor,
- action,
- target,
- source module/function,
- and an internal transaction token.

Writers do **not** hand-build git commands. They only declare:

- "I am about to mutate durable path X as actor Y for reason Z."

Primary callers:

- `Glorbo.Company.Router`
- `GlorboWeb.Actions`
- scaffolders
- config writers (for the future, once config becomes trackable)
- restore/import commands
- any other host-owned file mutation surface

This gives the history layer a stable notion of "one logical Glorbo
operation."

#### 5.2 Watcher fallback

Marked transactions are not enough because Glorbo explicitly allows
manual filesystem edits (GEP-3). Therefore the existing watcher acts as
fallback capture for tracked paths.

If a tracked path changes and no transaction metadata matches it inside
the short TTL window:

- the change is still committed,
- author becomes `External`,
- source becomes `watcher`,
- and the subject uses a generic shape:

```text
external.edit: companies/acme/projects/roadmap/task-42.md
```

This is a feature, not a compromise. It means:

- hand-editing `company.md` in Vim is a first-class change,
- and the history layer stays faithful to the filesystem-as-truth
  philosophy rather than only mirroring app-mediated writes.

#### 5.3 Transaction matching

`HomeHistory` keeps a short-lived map from path → transaction metadata.

Flow:

1. write surface marks path(s),
2. filesystem event arrives,
3. watcher asks `HomeHistory` whether a mark exists,
4. matching paths join the marked transaction,
5. unmatched paths become `External` transactions.

This is the same "short-lived metadata bridge over watcher-delivered
events" pattern already used elsewhere in the codebase (for example
Approvals.Gate's director-mark flow).

### 6. Coalescing and commit frequency

The user requirement is "every change tracked with commit," not
"every file event tracked with commit."

That distinction matters because one logical action often mutates more
than one file:

- task approval writes the task and appends audit,
- channel send appends the channel and appends audit,
- proposal flip writes the proposal and appends audit,
- restore writes a large tree and then runs reindex/fixer side effects.

v1 therefore commits **per logical change group**, not per inode event.

#### 6.1 Coalesce window

Each transaction remains open until one of:

- explicit `flush/1`,
- 500 ms of inactivity after the last marked path,
- or a 2 s hard cap.

Why these numbers:

- small enough that the history looks immediate,
- long enough to gather the task file + audit append + related writes
  into one commit,
- and bounded enough to avoid long-lived "half open" groups.

The watcher fallback uses the same 500 ms debounce for unknown edits so
manual save bursts become one commit instead of three.

#### 6.2 Mixed-actor bursts

If one debounce window contains unrelated unmatched edits, the history
layer does **not** invent provenance. It creates one `external.batch`
commit with:

- author `External`,
- source `watcher`,
- and all changed paths in the trailer list.

The rule is:

- preserve correct provenance when known,
- degrade to truthful "external batch" when not known,
- never guess.

### 7. Staging rules

The history layer stages only paths that pass `tracked_path?/1`.

Implementation rule:

- never run `git add -A`,
- always stage explicit paths,
- and never stage `.git/`, ignored runtime paths, or secret-bearing
  excluded files.

This is important for both safety and performance:

- safety, because repo metadata and secret exclusions must never slip in
  by accident,
- performance, because staging the whole home directory on every task
  mutation is the exact hot-path penalty this design is meant to avoid.

### 8. User experience

v1 adds a dedicated history verb family rather than overloading raw
`git` commands into Director UX.

#### 8.1 Commands

```text
glorbo history init
glorbo history status
glorbo history log [<path>] [--limit N]
glorbo history show <rev> [--path <path>]
glorbo history diff <rev> [<rev2>] [--path <path>]
glorbo history restore <rev> <path>
```

Semantics:

- `init` — create repo, write `.gitignore`, import the current tracked
  tree as the root commit, enable history in config.
- `status` — enabled/disabled, repo health, last commit, pending dirty
  tracked paths.
- `log` — compact commit list, optionally path-filtered.
- `show` — commit metadata + patch.
- `diff` — two-rev or rev-vs-working-tree diff.
- `restore` — restore one file or subtree from an old revision into the
  live working tree, then create a new commit describing the restore.

#### 8.2 No whole-tree checkout in v1

`glorbo checkout <sha>` is explicitly **not** part of v1.

Why:

- checking out the entire home tree can clobber files while the system
  is running,
- the runtime tree contains ignored-but-live state,
- and "replace the whole home with a prior commit" is closer to restore
  than to day-to-day Director UX.

The safe v1 verb is `history restore <rev> <path>`, which is:

- explicit,
- path-scoped,
- auditable,
- and append-only from the repo's perspective because restore itself
  creates a new commit.

Read-only inspection of an old full-tree snapshot can be added later via
temporary worktrees if it proves necessary.

### 9. Relationship to audit log

Audit JSONL remains the canonical structured log.

Reasons git does not replace it:

- audit has strong append-only semantics,
- audit stores structured detail maps, not just diffs,
- audit rows can exist for rejected operations that never produced a
  durable file change,
- and git history is locally mutable in ways audit deliberately is not
  (rebase, filter-branch, object pruning, repo deletion).

The layering is:

- audit answers "what action did the system accept or reject?"
- git answers "what durable file diff followed from that action?"

Whenever one logical operation touches both a durable file and the
matching audit JSONL, both paths are included in the same history
transaction.

### 10. Relationship to backup, restore, and clone

#### 10.1 Backup remains a separate primitive

`git clone` does **not** replace backup.

Reasons:

- ignored files are intentionally absent,
- secret-bearing `config.md` is intentionally absent,
- derived state like provider cache is absent,
- and operators may want a filesystem snapshot even when history is
  disabled or broken.

`glorbo backup` therefore remains the disaster-recovery primitive.

#### 10.2 Backup excludes `.git/` by default

Once GEP-33 ships, `glorbo backup` must exclude `.git/` unless an
explicit future `--include-history` flag says otherwise.

Why:

- `.git/` is derivative,
- it can be large,
- and disaster-recovery backups should prioritize current state over
  local archaeology.

This preserves GEP-3's "backup the directory, reindex later" story
without forcing every archive to carry commit objects.

#### 10.3 Restore does not replay history

`glorbo restore` continues to restore working-tree files, not git
objects. If `.git/` is absent after restore, the history layer is
simply disabled until the Director re-initializes it.

### 11. Relationship to GEP-7 and reindex

SQLite remains derived from the **current working tree only**.

`glorbo reindex`:

- ignores `.git/`,
- ignores commit history,
- and does not need git to reconstruct dashboard state.

Git history still helps reindex indirectly:

- it gives a human a timeline of why a file changed,
- it makes bug archaeology easier,
- and it creates a safe path for "restore this old version, then
  reindex."

But reindex must never require walking the commit graph.

That is the load-bearing constraint protecting GEP-7.

### 12. Security constraints

#### 12.1 `.git/` is never exposed to agents

The history repo is host-only metadata. Therefore:

- no bwrap permission mapping may mount `.git/`,
- no Glorbo path request may target `.git/` or any path beneath it,
- and dashboard surfaces that browse files treat `.git/` as reserved.

If a future feature needs read-only history access from an agent, it
must do so through a narrow host-mediated command, not a filesystem
mount.

#### 12.2 Author and trailer values are sanitized

Actor, action, target, and source values all flow into commit metadata.
They must be sanitized to:

- one line,
- bounded length,
- no control characters,
- no raw newlines,
- no `:`-smuggling where a parser expects `key: value`.

This is the same class of defense-in-depth already used for YAML
frontmatter scalar handling elsewhere in the codebase.

#### 12.3 Git is best-effort, not write-critical

If a commit fails:

- the authoritative file write still succeeds,
- the system emits an audit/log warning,
- and the repo is left dirty for a later retry.

Glorbo must not turn "git is temporarily broken" into "task approval
does not work." That would invert the derivative-state hierarchy.

### 13. Existing user-managed repos

GEP-3 explicitly blesses user-managed git in a company subtree.
GEP-33 does not revoke that.

v1 behaviour:

- nested `.git/` directories under `companies/**` are ignored as repo
  metadata,
- the root history layer still tracks the underlying working-tree files
  if they are in scope,
- and Glorbo does not attempt to synchronize branch state with any
  nested user repo.

This is intentionally boring. The product-managed root repo and a
user-managed nested repo may coexist, but no submodule or gitlink
semantics are promised.

### 14. Implementation phases

#### Phase 1 — bootstrap + read-only UX

- add `glorbo history init/status/log/show/diff`
- repo bootstrap
- `.gitignore`
- tracked-path matcher
- no automatic commits yet

This phase proves:

- repo shape,
- command ergonomics,
- and scope decisions.

#### Phase 2 — marked commits from host-side write surfaces

- integrate `HomeHistory.begin/mark/flush` into Router, Actions,
  scaffolders, restore, and other durable writers
- actor-aware commits for in-app writes

This phase proves:

- provenance quality,
- coalescing,
- and hot-path cost.

#### Phase 3 — watcher fallback for manual edits

- bridge watcher events to `HomeHistory`
- commit unmatched tracked-path edits as `External`

This phase is what makes the feature truly "filesystem-shaped" rather
than "only app-shaped."

#### Phase 4 — restore UX

- `glorbo history restore <rev> <path>`
- audit integration for restore operations
- safety rails around restoring directories and live files

## Migration / rollout

This feature is **opt-in** in v1.

Enablement path:

1. Director runs `glorbo history init`.
2. Glorbo creates `~/.glorbo/.git/` and `.gitignore`.
3. Glorbo stages the current tracked tree and writes the initial commit.
4. Glorbo writes `history.enabled: true` to `config.md`.
5. On next boot (or immediately if supported), `HomeHistory` starts and
   automatic capture is active.

Why opt-in:

- it changes local disk usage,
- it adds a hard dependency on `git` for one feature surface,
- it needs real-world performance feedback before being enabled by
  default,
- and it lets cautious Directors evaluate the tracked scope before
  committing to it.

Existing homes that never opt in see no behavioural change.

## Failure modes

### Git binary missing

If `history.enabled: true` but `git` is not on `$PATH`:

- `glorbo history status` fails loudly,
- doctor emits a warning,
- automatic capture is suspended,
- and no user write is blocked.

### Repo lock or commit failure

If git returns non-zero because of:

- lock contention,
- disk full,
- corrupt repo metadata,
- or permission issues,

then:

- the working-tree write remains authoritative and succeeds,
- a warning is appended to audit/logs,
- and `status` reports the repo as dirty/unhealthy.

### Watcher storm

If many tracked paths change rapidly and no actor metadata exists:

- the watcher coalesces them,
- one `external.batch` commit is written,
- and no attempt is made to guess fine-grained authorship.

### Restore of an old subtree conflicts with newer files

`history restore` may overwrite current files in the selected subtree.
That is intentional, but the command:

- prints the path list first,
- requires explicit confirmation unless `--yes`,
- and creates a new commit describing the restore, so undo remains one
  step away.

## Test strategy

- Unit tests for `tracked_path?/1` include/exclude decisions.
- Unit tests for commit-author/committer and trailer sanitization.
- Unit tests for transaction coalescing and watcher fallback matching.
- Integration test: Router-mediated task/proposal/channel mutation
  produces one commit containing both the durable file and the audit
  append.
- Integration test: manual edit to a tracked file with no transaction
  metadata produces an `External` commit.
- Integration test: excluded paths (`glorbo.db`, `runtime/`, `config.md`)
  do not dirty the repo.
- Integration test: `history restore <rev> <path>` writes a new working
  tree version and then creates a new commit.
- Security tests:
  - `.git/` denied in path requests,
  - `.git/` never appears in sandbox mounts,
  - commit metadata rejects newline/control-char injection.
- Performance tests:
  - audit append storms,
  - chat rotation bursts,
  - large tracked tree init.

## Open questions

- **Should `config.md` become trackable once secrets are split out?**
  Probably yes, but that is blocked on a separate config-shape GEP.
- **Should `cache/providers/**` become optionally snapshot-able?**
  Local-model operators may want it for reproducible offline catalogs,
  but default tracking still looks too noisy.
- **When should this default to on?**
  After one release cycle of opt-in performance data and repo-growth
  feedback.

## Decision log

### D1. Use git at the home root, not per-company repos

- **Decided:** one repo rooted at `~/.glorbo/`.
- **Alternatives:** per-company repos; a bare repo elsewhere plus a
  worktree; no product-managed repo.
- **Why:** the user mental model is one Glorbo home, some operations
  span more than one file family, and root-level history commands are
  dramatically simpler with one repo.

### D2. Git is derivative, never authoritative

- **Decided:** the working tree remains the source of truth; git is a
  history mirror.
- **Alternatives:** rebuild state from commits; treat commits as the
  canonical change stream.
- **Why:** GEP-3 and GEP-7 already settled the authority hierarchy.
  Reversing it would create a second state machine and break reindex's
  design.

### D3. Kernel-owned commits, logical actor as author

- **Decided:** `HomeHistory` writes commits; committer is always the
  kernel; author is logical actor identity.
- **Alternatives:** same actor for author+committer; agent-owned commits;
  user-only commits.
- **Why:** the host owns the repo and must remain the only code that
  mutates it, but user-facing provenance should still say who caused the
  change.

### D4. Track durable state, not raw whole-home bytes

- **Decided:** use a tracked-path allowlist for durable files.
- **Alternatives:** literal `git add -A` whole-home tracking; only track
  `companies/`; only track explicit Router outputs.
- **Why:** whole-home tracking drags secrets and runtime noise into the
  history stream. Tracking only Router outputs would miss manual edits.
  Durable-file allowlist is the least-wrong middle.

### D5. Exclude `config.md` in v1

- **Decided:** raw `config.md` is out of scope for tracking.
- **Alternatives:** track it as-is; redact it on commit; split the file
  in this GEP.
- **Why:** secret rotation and git history do not mix. A redaction layer
  in the same working tree is fragile. Secret/file splitting is valuable
  but is separate work.

### D6. Exclude generated and runtime churn

- **Decided:** `glorbo.db*`, `logs/`, `runtime/`, `run/`, `cache/`, and
  agent scratch/transport paths are ignored.
- **Alternatives:** track everything for completeness; track runtime but
  squash it aggressively.
- **Why:** those paths are not durable intent and would dominate repo
  churn for little user value.

### D7. Combine marked write metadata with watcher fallback

- **Decided:** use explicit transaction marks for known writes and the
  watcher for unknown/manual edits.
- **Alternatives:** watcher only; marks only.
- **Why:** watcher-only loses actor identity; marks-only loses manual
  edit capture. Both are required to stay faithful to Glorbo's
  filesystem model.

### D8. Commit per logical change group, not per inode event

- **Decided:** coalesce related writes into one commit with a bounded
  debounce window.
- **Alternatives:** one commit per file event; manual "savepoint"
  batching.
- **Why:** logical operations routinely touch multiple files. One commit
  per event would be noisy and misleading.

### D9. Store structured provenance in commit trailers

- **Decided:** trailers carry actor/action/target/source/path metadata.
- **Alternatives:** encode everything in the subject line; sidecar JSON
  metadata file; git notes.
- **Why:** trailers are readable, grep-able, and survive ordinary git
  workflows without introducing another storage layer.

### D10. Audit log coexists; it is not replaced

- **Decided:** audit JSONL stays authoritative for structured action
  history.
- **Alternatives:** replace audit with commit history; derive audit from
  commits.
- **Why:** rejected actions and structured detail maps do not map cleanly
  to git. Append-only audit semantics are stronger than local git
  history semantics.

### D11. No live whole-tree checkout in v1

- **Decided:** v1 offers path/subtree restore, not global checkout.
- **Alternatives:** `glorbo checkout <sha>` directly on the live tree.
- **Why:** the destructive blast radius is too large for a first cut,
  especially with runtime state and concurrent processes in play.

### D12. Backup and clone are different tools

- **Decided:** backup remains separate and excludes `.git/` by default.
- **Alternatives:** treat clone as backup; always include `.git/` in
  backup archives.
- **Why:** clone omits intentionally untracked state; backup should
  prioritize recoverable current state over local archaeology.

### D13. Reindex stays blind to history

- **Decided:** `glorbo reindex` reads only current working-tree files.
- **Alternatives:** optional "reindex from commit" mode in the same
  feature; consulting history during routine rebuilds.
- **Why:** GEP-7 must stay simple and stable. History-aware replay can
  exist later as explicit tooling.

### D14. `.git/` is a reserved host-only path

- **Decided:** sandbox mounts, path requests, and file-browsing surfaces
  must all treat `.git/` as reserved and inaccessible.
- **Alternatives:** allow read-only history mounts into the sandbox.
- **Why:** repo metadata is not product data, and exposing it would add a
  new side channel into the host state.

### D15. Ship opt-in first

- **Decided:** feature is enabled explicitly with `glorbo history init`
  and a config flag.
- **Alternatives:** default-on immediately; experimental env var only.
- **Why:** repo growth, hot-path cost, and tracked-scope ergonomics need
  one cycle of production feedback before they become default behaviour.

### D16. Preserve boring coexistence with user-managed nested repos

- **Decided:** nested company repos remain allowed; Glorbo ignores their
  metadata and makes no attempt to coordinate histories.
- **Alternatives:** forbid nested repos; try to model them as submodules.
- **Why:** forbidding them would contradict GEP-3's portability story,
  and submodule semantics would be complexity far beyond the value here.

### D17. Use the system `git` CLI, not libgit2

- **Decided:** invoke `git` as a subprocess.
- **Alternatives:** libgit2 binding; custom object-writing code.
- **Why:** this follows the existing Glorbo preference for boring,
  observable subprocesses over new in-process dependency stacks. It also
  keeps history debugging straightforward for contributors.
