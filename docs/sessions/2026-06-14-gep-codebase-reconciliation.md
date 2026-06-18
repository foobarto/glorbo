# GEP ↔ codebase reconciliation — gap report

**Date:** 2026-06-14  ·  **Against:** `main` @ `f54dcd5` (GEP-63 merged; pre-#60).

## Method

A multi-agent workflow reconciled **55 substantive GEPs** (all Implemented +
Accepted + Draft; placeholders / `Superseded` / the pure-process GEP-0/1/11
excluded) against the code: one reconciler per GEP located the implementing
modules/tests and reported material gaps, then **each high/medium finding was
adversarially verified** against the actual code (single-vote). Four
cross-cutting sweeps covered orphaned code, CHANGELOG↔status drift,
DESIGN/CLAUDE invariants, and README drift.

## Caveats (read before acting)

- **Single-vote verification.** High findings are high-confidence; some
  `medium` doc-drift / divergence items are defensible-but-arguable — triage,
  don't mass-apply.
- **Point-in-time** against `main`@`f54dcd5`. A few may already be in flight.
- The `low` tail (and ~92 *unverified* low candidates not listed here) is
  noise-prone; included only as titles.

## Summary

**107 confirmed gaps**: 6 high · 76 medium · 25 low.

By type: `doc_drift` 32 · `spec_code_divergence` 27 · `unimplemented` 19 · `status_drift` 17 · `missing_tests` 10 · `invariant_violation` 1 · `orphaned_code` 1

## 🔴 High — fix or honestly amend the GEP

### GEP-0023 · `unimplemented`
**No egress audit events emitted — 'every decision audit-logged' Goal and entire §Audit events section unimplemented**

- _Evidence:_ GEP Goals: 'Every decision (allow/deny/pending) is audit-logged with host, agent, and reason.' §Audit events specifies six event types (`egress.allowed`, `egress.denied`, `egress.pending_approval`, `egress.smart_allowed`, `egress.smart_denied`, `egress.smart_failed`) plus `AuditEntry.action_phrase/4` sentence renderers. None exist. `grep -rn 'egress\.allowed|egress\.denied|egress\.pending|egress\.smart' lib/` returns nothing. The proxy records decisions only via `Logger.info/debug` (proxy.ex:451,508,517,522,528) — not the append-only audit log. The only `egress.*` audit action in the codebase is `egress.web_fetch` (lib/glorbo/cli/harness/tools.ex:551), which is the unrelated GEP-22 director-side fetch. The §Audit-events claim about `AuditEntry.action_phrase/4` gaining egress renderers is false (lib/glorbo_web/components/audit_entry.ex has no egress handling). This defeats GEP-23's stated core purpose ('the director cannot answer did this agent call anything unusual last week').
- _Action:_ Implement the audit-event emission in `Glorbo.Network.Proxy` decision paths (allow/deny/unknown) writing to the append-only audit log with host/port/agent/reason, and add the `action_phrase` renderers, OR strike the Goal + §Audit events section and record in the GEP status log that audit logging of egress is not built. Do not leave a declared-Implemented GEP claiming audit coverage that is Logger-only.

### GEP-0023 · `unimplemented`
**Strict/smart unmatched hosts get a permanent 403 instead of the specced director-approval sentinel + 503**

- _Evidence:_ GEP §Modes: strict = 'unlisted falls through to director approval (sentinel file, same UX as approval.granted)'; smart = same plus LLM. §Proxy daemon step 6: pending_approval → 'write sentinel, send 503 Unavailable Retry-After: 60 ... Director clicks approve/deny.' The implementation never writes a sentinel and never sends 503/Retry-After. On `:unknown` the proxy unconditionally sends `HTTP/1.1 403 Forbidden` (lib/glorbo/network/proxy.ex:536) with the code comment 'Phase 3 adds director-approval sentinels' (proxy.ex:79) and 'Phase 3's sentinel handling will flip the entry' (proxy.ex:534) — i.e. unbuilt. `grep -rn 'sentinel|503|Retry-After|pending_approval' lib/glorbo/network/` finds only comments, no 503 response and no sentinel write. Consequence: strict and smart modes can NEVER reach a host the director would approve — every unlisted host is a hard, unappealable deny, contradicting the GEP's central strict/smart UX and the GEP-19 approval reuse it advertises.
- _Action:_ Implement the pending-approval sentinel write + `503 Retry-After: 60` response on `:unknown`/strict-fallthrough, wired to the GEP-19 approval queue, OR document in the GEP that strict/smart unlisted hosts deny-permanently with no approval path. The current behavior makes 'strict' and 'smart' modes functionally identical to a deny-all allowlist.

### GEP-0036 · `spec_code_divergence`
**Task status/edit mutations in LiveView bypass Glorbo.Actions via TaskDefinition.write*, defeating the GEP's core 'single write channel' invariant**

- _Evidence:_ GEP-36's central goal is 'One write path per mutation... No parallel write paths from LV/MCP/shell' and its Public API table (docs/geps/0036-...md:196-200) lists `Tasks.move(co, task_path, new_status, opts)` ('Status + column flip', 'inline in KanbanLive') and `Tasks.update_status` as Actions functions. Reality: no `Tasks.move`/`Tasks.update_status` exists in lib/glorbo/actions/tasks.ex (only create/trash/archive_to_history/reassign/record_peer_review_verdict). Three LiveView handlers mutate task domain state DIRECTLY, not through Actions: (1) lib/glorbo_web/live/kanban_live.ex:687 `Glorbo.TaskDefinition.write(abs_path, %{status: status})` in handle_event("kanban:move") — the drag-to-column flip — with audit emitted by a separate bespoke helper `emit_kanban_move_audit` (kanban_live.ex:695,1374); (2) kanban_live.ex:481-482 `TaskDefinition.write_frontmatter`+`write_body` in handle_event("save_task"); (3) lib/glorbo_web/live/task_live.ex:275 `TaskDefinition.write_frontmatter` in the task editor, audit via separate `emit_task_edit_audit`. `Glorbo.TaskDefinition.write/2` (lib/glorbo/task_definition.ex:397) is a genuine atomic filesystem write. These are exactly the divergent-on-disk-shape + per-handler-duplicated-audit anti-patterns the GEP exists to eliminate (Problem §, consequences 1 & 3).
- _Action:_ Either add `Glorbo.Actions.Tasks.update_status/move` and route the kanban:move, save_task, and task_live save handlers through it (centralizing validation + audit), OR amend GEP-36 to explicitly carve out `TaskDefinition.write*` as a sanctioned in-LV write path and drop `Tasks.move`/`update_status` from the spec table. Do not leave the GEP claiming a single write channel that the running code contradicts.

### GEP-0041 · `spec_code_divergence`
**Peer-review gate only fires for Director-approval-bound tasks, not standalone severity/opt-in tasks (core trigger rule unimplemented)**

- _Evidence:_ GEP-0041 Goals (line 113) + Trigger rules (lines 163-183) state peer review "fires automatically on tasks flagged severity: major|critical OR peer_review_required: true", intercepting `status: done`, INDEPENDENT of Director approval (Non-goals line 142-146: "Not Director approval... The two can coexist"). In reality, all peer-review logic lives inside `Glorbo.Approvals.Gate` and only engages for tasks routed through the Director-approval flow. `lib/glorbo/company/router.ex:1070-1085` (`maybe_request_approval`) only invokes the Gate when `requires_approval: director` OR `status: pending-approval`; router.ex has ZERO `peer_review`/`severity` references. The Gate's `peer_review.requested` emission (`lib/glorbo/approvals/gate.ex:485-495`) and the `peer_review_ready?` hold (gate.ex:412-419, 566-615) only run inside `resolve_status` for `status: "pending-approval"`. There is NO `status: done` interception for peer review anywhere. Consequence: a `severity: critical` task (which auto-flips `peer_review_required: true` via `Tasks.apply_severity_auto_flip/1`, tasks.ex:183-206) that does NOT also set `requires_approval: director` will reach `status: done` and ship with no peer-review gate — exactly the case the GEP says it protects.
- _Action:_ Either (a) implement the spec'd trigger in the Router so peer review fires on `severity: major|critical`/`peer_review_required: true` independent of Director approval (intercept the done/leaving-chain transition), or (b) amend GEP-0041 (Goals, Trigger rules, Non-goals) and its status to document that peer review is realized as a sub-gate of the Director-approval path and only protects approval-bound tasks. As written, status: Implemented overstates coverage of the headline goal.

### GEP-0046 · `missing_tests`
**Two GEP-46-mandated integration tests are missing entirely (incl. the load-bearing cross-company concurrency test)**

- _Evidence:_ GEP-46 Test strategy items 3 & 4 and Decision D8 (docs/geps/0046-parallelisation-of-company-agents.md:295-307, 442-457) name two NEW integration tests as load-bearing: `test/integration/concurrent_dispatch_test.exs` (real Agent.Servers under a real Company.Supervisor: two agents overlapping `agent.dispatch` audit timestamps; one agent at max_concurrency=3 producing 3 distinct invocation_ids before any agent.complete) and `test/integration/cross_company_concurrent_test.exs` (two companies dispatching simultaneously, overlapping cross-company `agent.dispatch` timestamps — explicitly described as codifying "the GEP-2 invariant the gep-research surfaced as undocumented"). Both files do NOT exist (confirmed: `ls test/integration/` shows neither; grep for `concurrent_dispatch`/`cross_company`/overlapping-timestamp assertions across `test/` returns no equivalent). The GEP also references the path `test/integration/cross_company_concurrent_test.exs` in the Design section (line 199) as the test that asserts the cross-company invariant. The cross-process concurrency path the GEP states "tests MUST exercise" (D8 "the whole point of the GEP is concurrency; tests must exercise the cross-process path") is only covered at the per-process unit level with a stubbed `dispatch_fun` (test/glorbo/agent/server_test.exs:1304-1396) and the standalone semaphore unit (test/glorbo/company/dispatch_semaphore_test.exs). No test drives the real DispatchSemaphore↔Dispatch↔Agent.Server path or cross-company parallelism end-to-end.
- _Action:_ Add the two missing integration tests, or — if the cross-process path is deemed adequately covered by the unit layers — amend GEP-46's Test strategy/D8 to drop the integration-test commitment honestly (append-only history note per GEP-1) rather than leaving the GEP advertising tests that don't exist. The cross-company test in particular guards a GEP-2 isolation invariant that currently has zero direct coverage.

### GEP-changelog-status-drift · `status_drift`
**GEP-0055 still status: Draft but shipped in RELEASED v0.26.0 (most severe — already tagged)**

- _Evidence:_ docs/geps/0055-openai-v1-proxy-for-sandboxed-agents.md:5 -> status: Draft. CHANGELOG.md:299 (under released ## [0.26.0] — 2026-06-12): '**In-process inference proxy for sandboxed agents (GEP-0055, slices 1–4a).** New `Glorbo.OpenAIProxy`...'. Further hardened at CHANGELOG.md:235 '**GEP-0055 inference-proxy hardening** (PR #47 review...)'. Code confirmed: lib/glorbo/openai_proxy.ex + lib/glorbo/openai_proxy/shape.ex exist. This is the worst case of the set: the feature is in a tagged, published release yet the GEP still reads Draft.
- _Action:_ Flip GEP-0055 front-matter to status: Implemented (or Partially-Implemented if you want to flag the deferred slices — CHANGELOG explicitly lists SSE streaming, Gemini request translation, settings.json injection, audit rows, usage.json, and CLI-provider opt-in as not-yet-shipped). Add a history entry dated 2026-06-12 noting the v0.26.0 ship of slices 1–4a + PR #47 hardening.

## 🏷️ Status drift — GEPs whose `status:` lies (your new lockstep rule)

Directly actionable; ties to the GEP-1 append-only flips. Flip `status:` +
append a `history:` entry (don't rewrite the body).

| GEP | sev | gap |
|---|---|---|
| changelog-status-drift | high | GEP-0055 still status: Draft but shipped in RELEASED v0.26.0 (most severe — already tagged) |
| 0023 | medium | GEP-23 declared Implemented but smart-mode LLM classifier is wired to a permanent stub — never calls an LLM |
| 0037 | medium | GEP status is 'Accepted' but 7 phases shipped across v0.10.0–v0.17.0; project convention reserves 'Implemented' for shipped GEPs ( |
| 0040 | medium | GEP status `Implemented` overstates delivery; Implemented note names a non-existent function `Actions.Tasks.assign/4` |
| 0056 | medium | GEP-56 declared status: Draft but fully implemented and shipped (status drift in GEP + README index) |
| 0057 | medium | GEP-0057 declares status: Draft but the feature is fully implemented and shipped |
| 0058 | medium | GEP-0058 declares status:Draft + "implementation DEFERRED / nothing ships", but the feature is fully built, wired, tested, and shi |
| 0059 | medium | GEP-59 declares status: Draft but the v1 scope is fully implemented, tested, and shipped |
| changelog-status-drift | medium | GEP-0059 status: Draft but shipped in CHANGELOG [Unreleased] (glorbo fit) |
| 0025 | low | FileSpec registry moduledoc still declares "scaffolding only — validator/formatter/CLI land in follow-up commits; no existing writ |
| 0046 | low | GEP-46 status `Implemented` overstates test-strategy completion |
| 0062 | low | GEP-0062 status is stale: still 'Accepted' though the design shipped to main (PR #57), and the GEP's own note instructs flipping t |
| changelog-status-drift | low | GEP-0056 status: Draft but shipped in CHANGELOG [Unreleased] (Security section) |
| changelog-status-drift | low | GEP-0057 status: Draft but shipped in CHANGELOG [Unreleased] (deep-research task type) |
| changelog-status-drift | low | GEP-0058 status: Draft but shipped in CHANGELOG [Unreleased] (semantic recall index) |
| changelog-status-drift | low | GEP-0061 status: Accepted but shipped in CHANGELOG [Unreleased] / merged in PR #55 |
| changelog-status-drift | low | GEP-0062 status: Accepted but shipped in CHANGELOG [Unreleased] / merged in PR #57 |

## 🟡 Medium — Spec ↔ code divergence (22)

- **GEP-0003** — GEP-3 reindex contract step 1 ("Drops and recreates the SQLite schema") and its `rm glorbo.db && glorbo reindex` test are spec-code divergent — reindex is MD5-incremental and never creates the schema
  - _ev:_ GEP-3 (docs/geps/0003-filesystem-as-source-of-truth.md:186-199) specifies the reindex contract as: "1. Drops and recreates the SQLite schema." and the invariant test "`rm glorbo.db && glorbo reindex` produces a DB that passes the same queries the original would" (also stated at l
- **GEP-0004** — GEP-0004 asserts 'Glorbo never makes its own LLM API calls, never hands agents API keys, never implements provider-specific retry' as a design absolute — false for native providers
  - _ev:_ GEP-0004:60-61 states unconditionally: 'Glorbo never makes its own LLM API calls, never hands agents API keys, and never implements provider-specific retry or streaming logic.' GEP-0004:201 states 'Glorbo mediates zero of the auth traffic.' These are false for the shipped `native
- **GEP-0005** — Web dashboard sandbox-preview (build_sandbox_preview/3) is a hand-maintained duplicate of the bwrap argv that has drifted from the real composer
  - _ev:_ lib/glorbo_web/live/agent_live.ex:2052-2062 builds a user-facing `base:` flag list shown to the Director when inspecting an agent. It lists `--unshare-user-try` and `--unshare-cgroup-try` (lines 2055, 2059) and `--cap-drop ALL`, but is MISSING `--clearenv` and uses the weak `-try
- **GEP-0014** — GEP-advertised `heartbeat_file:` redirect field is decorative — accepted by the validator but never honored by any consumer
  - _ev:_ GEP-0014 §agent.md wiring (docs/geps/0014-agent-heartbeat-semantics.md:124-132) advertises an optional `heartbeat_file: HEARTBEAT.md` field 'for users who want to point elsewhere (e.g. split per-day heartbeats). Default is HEARTBEAT.md if unspecified.' The field is wired into the
- **GEP-0016** — GEP-16 §5/D2 falsely claims auth-bind mode="rw" is unimplemented and clamped to read-only; code + tests honor rw with a real writable --bind
  - _ev:_ GEP-0016 §5 (lib path docs/geps/0016-agent-wake-dispatch-pipeline.md:194-196) states: `mode (optional, "ro" | "rw", default "ro") ... "rw" is reserved for future use; today it is silently treated as "ro" (auth dirs should never be rw-mounted).` Decision D2 (lines 343-345) repeats
- **GEP-0016** — GEP-16 §4 describes a cli_binary_binds/1 function and a same-host=sandbox-path $PATH mounting mechanism that does not exist; the real binary-mount strategy is materially different
  - _ev:_ GEP-0016 §4 (docs/geps/0016-agent-wake-dispatch-pipeline.md:133-157) presents a verbatim `defp cli_binary_binds(%{resolved_path: path})` that 'auto-mounts both the symlink's parent dir AND ... the target's enclosing dir. Same host+sandbox path so $PATH resolution inside the sandb
- **GEP-0021** — GEP example memory frontmatter (no kind field) would be rejected by the actual write path
  - _ev:_ The Router write path requires `kind: agent-memory/v1` in frontmatter: `check_memory_kind/1` (router.ex:1889-1894) rejects any file whose `kind` is not exactly "agent-memory/v1", and the FileSpec marks `kind` as required (lib/glorbo/file_spec/memory_entry_md.ex:13, 23). But GEP-0
- **GEP-0023** — History cache is ETS-only with 6-hour TTL, never wired into the production proxy, and has no on-disk persistence — contradicts §History module and D6/D9
  - _ev:_ GEP §History module + D6: `Glorbo.Egress.History` persists to `companies/<co>/state/egress-history.json` with a documented JSON schema and a 30-day rolling window (D9: '30-day decision cache window'; smart-mode 'verdict cached for 30 days'). The implementation `Glorbo.Network.His
- **GEP-0024** — Natural-language schedule parsing ships in code but GEP-0024 declares it an explicit Non-goal, with no GEP documenting the reversal
  - _ev:_ GEP-0024 lists NL parsing as a Non-goal (docs/geps/0024-task-scheduler.md:72-75 "Natural-language schedule parsing ('every weekday at 9am'). ... free-form NL needs a parser ... this GEP does not tackle. See D6.") and D6 (lines 300-312) decides for a "Closed keyword-alias table, n
- **GEP-0026** — `company-template/v1` kind is unregistered: no FileSpec, so `glorbo validate`/`glorbo fmt` don't cover template files (contradicts Migration claim + D1 rationale)
  - _ev:_ GEP-26 Migration section states `company-template/v1` is "a new kind (registered in GEP-25)" and D1's whole rationale is that the tree-on-disk approach "keeps every template file a first-class Glorbo-owned file that `glorbo validate` + `glorbo fmt` cover for free". But the FileSp
- **GEP-0027** — path_access.granted and path_access.revoked audit events are never emitted at dispatch boundaries (spec says they are)
  - _ev:_ GEP-27 §2.3 says "After the dispatch completes (success or failure), the grant is removed from ETS and a `path_access.revoked` audit event is emitted" and §2.4 enumerates a five-event audit trail including `path_access.granted` (at dispatch start) and `path_access.revoked` (at di
- **GEP-0027** — Director cannot downgrade write->read or trim individual paths in the UI, despite GEP §2.2/D5 making this a core approval capability
  - _ev:_ GEP-27 §2.2: on approve the director can "Accept the request as-is. Downgrade write -> read for any path. Remove individual paths from the grant." D5 reaffirms this as a least-privilege design decision. The server permits it (PathRequestGate.validate_subset/2, path_request_gate.e
- **GEP-0028** — Canonical proposal audit action names diverge from the GEP; `proposal.requested` and `proposal.superseded` are emitted nowhere
  - _ev:_ GEP-0028 §Audit events (lines 308-315) and §Approval flow (lines 223-227) define canonical action names `proposal.requested` / `.approved` / `.denied` / `.superseded`, and §Router integration (lines 258-260) says the ProposalsSink 'emits the canonical audit event (proposal.reques
- **GEP-0033** — GEP §Migration specifies a `history.enabled: true` config flag that does not exist; enablement is purely `.git/` directory presence
  - _ev:_ GEP-0033 §Migration/rollout step 4 (docs/geps/0033-git-history-layer-for-glorbo-home.md:1172) states `glorbo history init` "writes `history.enabled: true` to `config.md`", and step 5 (:1173-1175) says "On next boot ... `HomeHistory` starts and automatic capture is active" implyin
- **GEP-0036** — Credo ratchet only catches File.* calls, so it cannot enforce the GEP against TaskDefinition.write* bypasses — and its allowlist-empty 'GEP-36 is done' claim is misleading
  - _ev:_ The enforcement check `Glorbo.Credo.Check.RawFilesystemWriteInLive` (lib_dev/raw_filesystem_write_in_live.ex:40-49) only flags the literal `File.*` mutators. It does not flag `Glorbo.TaskDefinition.write/write_frontmatter/write_body`, which are themselves domain-state filesystem 
- **GEP-0036** — Legacy top-level Actions functions silently default the actor instead of raising, violating GEP-36 D7
  - _ev:_ GEP-36 D7 (docs/geps/0036-...md:485-499) mandates: 'Every public function signature includes opts with a mandatory :actor key. Missing :actor raises ArgumentError... Missing actor should crash, not silently default, per the security-paranoid posture.' The four top-level legacy fu
- **GEP-0037** — Spec names Glorbo.Shell.{Keybindings, Theme, Renderer, InputReader} as load-bearing single-source-of-truth modules; none exist, and the spec's test strategy targets Runtime.reduce/2 + Renderer.frame/1 which also don't exist
  - _ev:_ §Design declares: "All keybindings live in `Glorbo.Shell.Keybindings` as a single source of truth" (line 974); "Theme tokens — Elixir module `Glorbo.Shell.Theme`" (866-869); §Supervision tree child #2 `Glorbo.Shell.InputReader` owning stdin raw mode (820-824); §Test strategy: "`G
- **GEP-0042** — Peer-review sentinel FileSpec modules are shadowed by InboxMessageMd in classify_by_path — GEP's "routes through the new module without ambiguity" claim is false
  - _ev:_ GEP-0042 §Sentinel shape (lines 245-247) claims: "The kind: discriminator means Glorbo.FileSpec.classify_by_path routes it through the new module's validator without ambiguity against generic inbox messages." In reality, lib/glorbo/file_spec.ex:92 registers Glorbo.FileSpec.InboxM
- **GEP-0044** — Harness fixture seed does not create the agent/task/project entities 4 of the 18 PAGES target — capture lands on redirect pages
  - _ev:_ scripts/ui-baseline.sh seeds the fixture with ONLY `./glorbo init --no-example` (line 105) + `./glorbo new company acme` (lines 113-114). But its PAGES map targets entities that seed path never creates: `06-agent|/companies/acme/agents/ceo` (line 52), `07-task|/companies/acme/tas
- **GEP-0045** — D5 declares 'no session reuse across dispatches' but the shipped code implements ACP session resume across dispatches (resumeSession + persisted session-id file)
  - _ev:_ GEP D5 (docs/geps/0045-stado-as-glorbo-provider-via-acp.md:264-274) states: 'No session reuse across dispatches; if Director wants long-running stado state, that lives in ~/.local/share/stado/sessions/ and stado's own session resume path picks it up the next dispatch.' The shippe
- **GEP-0061** — Hierarchy.native_credentials_dir/0 omits the absolute/no-`..` validation guard the GEP says it keeps; the GEP-55 sandbox-bind consumer is unguarded
  - _ev:_ GEP-0061 Design (line 106-107) specifies: "Hierarchy.native_credentials_dir/0 → config_root()/credentials (keep the GLORBO_CREDENTIALS_DIR override + its absolute-path / no-`..` validation guard)", and Failure modes (line 142): "Odd XDG_CONFIG_HOME (relative, .., /etc) → reuse th
- **GEP-design-invariants** — Permission resource whitelist diverged from DESIGN/CLAUDE — six documented resources are rejected at parse time, failing the whole agent.md load
  - _ev:_ DESIGN.md:735 lists valid permission resources as `projects, tasks, agents, chat, channels, tools, budget, goals, skills, company`, and DESIGN's canonical agent.md examples USE the now-unsupported ones: DESIGN.md:555 `tools:execute:code-runner`, DESIGN.md:556 `budget:read:self`, 

## 🟡 Medium — Unimplemented / partial (13)

- **GEP-0023** — No /companies/:co/egress LiveView or any of the specced UI surfaces
  - _ev:_ GEP Goals: 'A new /companies/:co/egress LiveView surfaces history + pending approvals.' §UI surfaces specifies: the egress LiveView (top-N hosts, denied tally, live PubSub feed, agent filter), a sidebar 'Egress' row, a CompanyLive 'egress · 24h' stat card, an extended ApprovalQue
- **GEP-0025** — Validator does not implement the `:type_filename_mismatch` check — a core GEP-25 motivation and a documented MemoryEntryMd rule
  - _ev:_ The GEP lists `:type_filename_mismatch` as an error-severity check (docs/geps/0025-...md:256) and names it explicitly in Problem #2 ("that every memory file matches its type/filename convention"). lib/glorbo/file_spec/memory_entry_md.ex:40-42 moduledoc asserts the rule is enforce
- **GEP-0026** — `mix glorbo.bench.verify` task is specified in 3 places but does not exist
  - _ev:_ GEP-26 references `mix glorbo.bench.verify <name>` as a real, load-bearing tool in three sections: Template-authoring workflow step 4 (lints manifest, checks assignees, runs formatter idempotence, rejects fixtures >10MB), the Failure-modes table row "Fixtures dir contains binary 
- **GEP-0028** — GEP-28 `fire` proposal subtype + fire auto-approval is specced and advertised but unimplemented
  - _ev:_ GEP-0028 specifies `fire` as a first-class subtype with auto-approval semantics: the auto-approve table (docs/geps/0028-agent-created-proposals.md:198-213) gives two `fire` rows ('Target agent has no assigned_to: tasks' → auto-approve; 'Target agent has assigned tasks' → stays pe
- **GEP-0028** — No `proposals` derived SQLite table — reindex never materializes proposals despite GEP rollout step 4
  - _ev:_ GEP-0028 migration step 4 (docs/geps/0028-agent-created-proposals.md:353-354) states '`glorbo reindex` learns to index `proposals/*.md` into the SQLite `proposals` derived table.' No such table exists: `reindex`'s `upsert_domain_row/2` (lib/glorbo/filesystem/reindex.ex:380-391) o
- **GEP-0029** — GEP-29 Design specs 27 tools but only 23 are implemented; 4 task-mutation tools (create_task, dispatch_task, update_task_status, get_agent_stdout_tail) were never built
  - _ev:_ GEP-0029 'Tool surface' (docs/geps/0029-mcp-server-for-glorbo.md:149-154, 146) enumerates `glorbo.create_task`, `glorbo.dispatch_task`, `glorbo.update_task_status`, and `glorbo.get_agent_stdout_tail`. The compiled registry lib/glorbo_web/mcp/server.ex:68-97 lists exactly 23 tool 
- **GEP-0030** — confirm_modal with typed-word gate is entirely unimplemented
  - _ev:_ GEP-0030 lists the typed-word destructive-confirm as a Goal (docs/geps/0030-tui-redesign.md:68), a 'New' deliverable (lib/glorbo_web/components/confirm_modal.ex at :122-124), and decision D10 (:376-388), used by 'agent SIGKILL, company archive, memory wipe'. No such component or 
- **GEP-0037** — GEP-37 normative §Design promises 12 views + overlays; only 7 list-views shipped (Skills, Goals, Agent-detail tabs, Command palette, Inbox active/archived tabs all absent), yet D4/D8 declare drop-in parity is a hard requirement "shipped in v1, no phase-2 slicing"
  - _ev:_ GEP §Views table (0037-glorbo-shell.md:881-894) maps 12 web views/overlays to TUI views. D8 (lines 1287-1298): "The seven GEP-6 canonical views + the GEP-20 additions (Skills, Goals, Inbox-archive, command palette) all ship in v1. No 'phase 2' slicing." D4 (1210-1224): every Dire
- **GEP-0040** — Append-only handoff_chain enforcement (`:handoff_chain_rewound` prefix-check) specified but never implemented
  - _ev:_ GEP-0040 D2 (lines 444-462) and the Failure-modes table (line 362) specify a concrete security mechanism: "Validator in FileSpec checks that new list is strict prefix of old list (append-only). Tampering rejected at Router with `:handoff_chain_rewound` reason; audit entry logged.
- **GEP-0040** — Chain audit view omits dispatch/loop/comment timeline sources and all six chain-summary metrics from the Design
  - _ev:_ GEP-0040 Design (lines 238-268) specs TaskChainLive as a single timeline aggregating FIVE sources (1 handoff events, 2 dispatch events `agent.dispatch|agent.complete`, 3 approval events, 4 loop sentinels `agent.loop_detected|loop_resolved`, 5 comments) plus a top-of-page block of
- **GEP-0041** — Company-level reviewer config (peer_reviewer: block, by_severity / by_assignee_role, director fallback) is entirely unimplemented and would be rejected as unknown_key
  - _ev:_ GEP-0041 §"Reviewer role config" (lines 202-223) specifies a `peer_reviewer:` block in company.md with `default`, `by_severity`, and `by_assignee_role` overrides, plus a `director` fallback emitting `peer_review_no_reviewer_available` when the resolved role has no hired agent (al
- **GEP-0051** — C-061 forged-block short-circuit is still live in the gate and pinned by a regression test (the very gap GEP-0051 exists to close)
  - _ev:_ GEP-0051 §Design.2 + D4 specify that `status: denied` + `peer_review_verdict: block` without a trusted reviewer block event must fall through to revert_unauthorised_status/5 + an `approval.forged_block_rejected` audit. In the code, lib/glorbo/approvals/gate.ex:436-442 uncondition
- **GEP-0056** — Cross-hop carry (normalise/1) — the GEP's central provenance-carried thesis — is never wired into the dispatch pipeline
  - _ev:_ The GEP makes cross-hop carry a primary design pillar: the 'Cross-hop carry (the provenance-carried thesis)' section (lines 129-145), D3 'Granularity = provenance-carried' (lines 197-204), and the implementation note (line 230) all describe B's composer scanning inbound content v

## 🟡 Medium — Doc drift (22)

- **GEP-0004** — GEP-0004 'v0.0.2+ evolution' section describes the dropped Podman/litellm container path; the direct-SDK feature actually shipped as in-process `glorbo harness`
  - _ev:_ GEP-0004 §'v0.0.2+ evolution: direct-SDK providers inside the container' (docs/geps/0004-cli-tool-agents.md:204-226) states present/future tense that direct-SDK providers run via 'litellm inside the `glorbo-runtime` Podman container', that 'CLI tools go through bwrap + the CLI bi
- **GEP-0005** — GEP-5 §"Network policy" and §D4 still document the pre-GEP-23 keywords (none/proxy/open) and call proxy "advisory-only" — both are now wrong
  - _ev:_ GEP-5 lines 112-124 (§"Network policy") declare three levels `network: none` / `network: proxy` / `network: open`, and explicitly state proxy is "advisory-only at the kernel layer (a determined agent could ignore HTTP_PROXY); a netns + nftables hardening iteration is planned." §D
- **GEP-0006** — GEP-0006 title and thesis claim "Phoenix Channels" that do not exist in the codebase — all streaming is LiveView streams + PubSub
  - _ev:_ GEP-0006 (status: Implemented) is titled "Phoenix LiveView + Channels for the Dashboard" and makes Channels a load-bearing, repeated claim: line 31 "LiveView + Channels instead of a separate SPA"; line 57 "Phoenix Channels provide streaming for stdout and chat"; §"Why Phoenix Cha
- **GEP-0006** — GEP-0006 D4 / "headless mode" describes `glorbo run` as starting orchestration without the Phoenix endpoint — but `run` boots the full serve tree (Endpoint included) and is a one-shot dispatcher
  - _ev:_ GEP-0006 D4 (lines 250-259): "`glorbo run` starts orchestration without the Phoenix endpoint. `glorbo serve` starts both." And §"What about a headless mode?" (line 202): "`glorbo run` starts orchestration without the Phoenix endpoint. Used in production deployments where the Dire
- **GEP-0007** — GEP-7 "What SQLite holds" lists indexes that have no table — Task index, Channel message index, Approval queue, Agent status are read from the filesystem, not SQLite
  - _ev:_ GEP-7 §"What SQLite holds" (docs/geps/0007-sqlite-as-derived-data.md:55-83) asserts SQLite holds a **Task index** (status/assignee/project/due — line 59-62), a **Channel message index** (line 78-80), an **Approval queue** index (line 81-83), and **Agent status** (last heartbeat /
- **GEP-0008** — GEP-8 §8 / D3 promise a `glorbo doctor` provider table (and `glorbo doctor --probe`) that was never built; only the /providers LiveView shipped
  - _ev:_ GEP-8 §8 (docs/geps/0008-provider-registry-and-auto-detect.md:256) states: "`glorbo doctor` prints a table covering the same data: name, installed?, path, version (if probed), usage parser, source (`builtin` or `user`)." D3 (:335) references `glorbo doctor --probe` as the manual 
- **GEP-0017** — GEP-0017 history note claims macOS CI build is disabled, but release.yml builds and ships signed darwin artifacts unconditionally
  - _ev:_ GEP-0017 history entry dated 2026-04-23 (docs/geps/0017-cross-os-sandbox-and-watcher.md:19-22) states: "The CI `build-macos` matrix is still disabled pending GHA runner capacity; macOS users build from source." That is no longer true. .github/workflows/release.yml defines an ENAB
- **GEP-0019** — GEP-0019 names GlorboWeb.ApprovalQueueLive + /companies/<co>/approvals as the UI surface, but both were deleted and folded into InboxLive
  - _ev:_ GEP-0019 Problem/Design sections (docs/geps/0019-director-approval-workflow.md:28, :100-101, :161-166, :275, :282) repeatedly cite `GlorboWeb.ApprovalQueueLive` as 'the dashboard' and the route `/companies/<co>/approvals` ('Director clicks Approve/Deny on /companies/<co>/approval
- **GEP-0021** — glorbo.md agent skill never documents the memory write protocol the GEP says it ships
  - _ev:_ GEP-0021 lists `priv/templates/skills/glorbo.md` in the Module layout table (line 204: "Documents the write protocol for agents") and in Migration/rollout (line 229: "gets a new section teaching agents the outbox-write protocol. This ships with v0.0.4"). Actual file `/var/home/fo
- **GEP-0024** — TaskScheduler moduledoc claims a boot-time audit-log de-dup (restart double-fire prevention) that does not exist in the code
  - _ev:_ lib/glorbo/company/task_scheduler.ex:22-27 moduledoc states: "Audit-log de-dup (D-45 style). There is no state file — on boot we read the current-month audit and skip any (task_path, fire_ts) pair that already appears. Keeps us from double-firing if the BEAM restarts within the s
- **GEP-0027** — GEP failure-mode 'no task exists' is not implemented; rejected requests are deleted, not moved to history/, and emit path_access.rejected not path_access.invalid_task
  - _ev:_ GEP-27 §Failure modes: "Agent writes a path request but no task exists. The request is rejected with a `path_access.invalid_task` audit. The sentinel is not written; the outbox file is moved to `history/`." In code there is no task-existence check anywhere in the path-request flo
- **GEP-0028** — GEP-28 §Inbox surface (proposal cards in the Mine tab) is fully unimplemented; superseded by ProposalsLive without reconciling the body
  - _ev:_ GEP-0028 §Inbox surface (docs/geps/0028-agent-created-proposals.md:266-286) specifies in detail that 'InboxLive renders proposal cards in the Mine tab alongside task approvals and path requests' with subtype badge, rationale, Approve/Deny/Archive buttons and a pre-filled status-e
- **GEP-0032** — GEP-32 body advertises 23 cloud + 10 local seed providers; only 3 native provider TOMLs actually ship
  - _ev:_ GEP §Goals (docs/geps/0032-native-agent-harness.md:82-88) promises the harness "speaks OpenAI v1 REST to any of ~33 cloud or local endpoints" and lists Ollama/LM Studio/llama.cpp/LocalAI/vLLM/TGI/Jan/text-generation-webui/koboldcpp/MLX-Omni by name. §Seed provider list (lines 207
- **GEP-0034** — GEP-19 still describes the pre-GEP-34 rebuild model and a stale tasks_approval_state schema, contradicting the shipped reindex
  - _ev:_ GEP-19 (docs/geps/0019-director-approval-workflow.md:119-123, status: Implemented) claims the SQLite index is `tasks_approval_state(task_path PRIMARY KEY, agent_slug, status, denial_reason, …)` and is "fully rebuildable from sentinels + frontmatter via glorbo reindex." Both halve
- **GEP-0037** — `glorbo shell` with no company arg AND the --help/CLI help text still advertise "Phase 0 placeholder banner" — user-visible doc drift; the runtime has worked since v0.13.0
  - _ev:_ lib/glorbo/cli.ex:732 help line: `shell [alpha] Interactive Director terminal (GEP-37 Phase 0)`. lib/glorbo/shell.ex help_text (133-153): "Phase 0 (alpha) — CLI wired, term_ui dep installed, placeholder banner shown. Runtime + views land in subsequent rounds." Both stale by 7 pha
- **GEP-0041** — Reviewer reply contract diverges: spec mandates a `VERDICT:`-prefixed reply + regex; code uses an `ACTIONS:` block with `- verdict: ...`
  - _ev:_ GEP-0041 §"Reviewer reply contract" (lines 226-258) and the Failure modes table (line 354) state the reviewer reply "must start with one of three verdict tags" `VERDICT: approve|revise|block` and the Router "only resolves peer-review tasks when reply matches `VERDICT: <approve|re
- **GEP-0047** — GEP-0047 advertises a `task.dependency_missing` validator finding that does not exist in code
  - _ev:_ GEP-0047 promises this finding in three places: §Reference shape (D1) line 130-134 ("The validator emits a `task.dependency_missing` finding when a `depends_on` entry resolves to no live task and no history task"), the Failure-modes table lines 316/319 ("Validator finding (`task.
- **GEP-0051** — GEP-0051 Problem section overstates C-066 as fully open — GEP-41 D8 already added audit-log corroboration to the approve path
  - _ev:_ GEP-0051 (created 2026-05-22) §Problem / C-066 states `Glorbo.Approvals.Gate.peer_review_ready?/1` 'returns :ok on peer_review_verdict: "approve" alone. It does not... consult any audit record' (docs/geps/0051-...md:36-44). But the shipped gate DOES consult the audit log: lib/glo
- **GEP-0056** — GEP and SECURITY.md advertise installed-skill text as framed-untrusted, but skills never pass the framing seam
  - _ev:_ GEP-56 Provenance model lists 'installed skill text (GEP-22)' as :untrusted content the composer wraps (lines 78-80), and the implementation note says the composer tags 'web_fetch/foreign-memory/skill chunks :untrusted' (line 232). SECURITY.md repeats the claim verbatim: content 
- **GEP-0061** — README + priv/providers/minimax.toml advertise the OLD credential path and falsely claim v0.26.0 still reads ~/.local/etc
  - _ev:_ GEP-0061 is status: Accepted, "Approved + implemented in the same PR", shipped via commit 74a4510 which is in the v0.26.0 release line (release commit 9b51344). The current code (mix.exs version "0.26.0") reads native credentials from ~/.config/glorbo/credentials via Hierarchy.na
- **GEP-0061** — doctor never surfaces stale legacy provider/credential files, contradicting the GEP twice
  - _ev:_ GEP-0061 Migration §1 (line 121-122) says the migration is "surfaced by `glorbo doctor`"; §3 (line 132) "if both exist, prefer the new and warn about the stale legacy copy"; Failure modes (line 143) "Both legacy + new present → new wins; stale legacy flagged by doctor". The Confi
- **GEP-design-invariants** — DESIGN §4.4 documented base sandbox flags are stale vs code and self-contradict §12 — `--clearenv` missing, `-try` suffixes and `--ro-bind /bin` wrong
  - _ev:_ DESIGN.md:453-457 documents the base flags as `--die-with-parent --unshare-user-try --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup-try --new-session --cap-drop ALL` plus `--proc /proc --dev /dev --tmpfs /tmp`, and DESIGN.md:462 shows `--ro-bind /bin /bin --ro-bind /li

## 🟡 Medium — Missing tests (8)

- **GEP-0021** — Security invariant (cross-agent memory write rejection) has no test and the specced mechanism/reason doesn't exist
  - _ev:_ GEP-0021 calls cross-agent isolation a load-bearing invariant: the failure-mode table (line 243) requires a `../../other-agent/memory/…` path-manipulation attempt to be rejected with reason `cross_agent`, and the Test strategy (line 260) requires an integration test "Cross-agent 
- **GEP-0026** — Phase-A scaffolder (`glorbo new company --template`) has zero test coverage; named Phase-A tests do not exist
  - _ev:_ GEP-26 Test-Strategy Phase A names three concrete tests plus a file: manifest validation in `test/glorbo/templates/bench_templates_test.exs`, a scaffolder round-trip ("scaffold each bench template into a tmp dir, assert file tree ... every file passes glorbo validate"), and per-t
- **GEP-0027** — PathRequestGate GenServer lifecycle, Router path-request classification, and the full integration flow are untested
  - _ev:_ GEP-27 §Test strategy promises: Router path-request classification unit tests; PathRequestGate lifecycle tests (request->approve->grant->revoke, request->deny); and an integration test (agent outbox write -> Router -> Gate -> director approve -> dispatch with mount -> grant revok
- **GEP-0031** — GEP-31's load-bearing D-8 invariant (loopback unreachability) is only tested by an integration suite that skips on CI
  - _ev:_ D-8 (the GEP's explicit 'test discipline' decision, docs/geps/0031-...md:202-207) mandates every :proxy integration test assert the agent cannot reach 127.0.0.1:4000, verified at connect() level. The ONLY test of this is test/integration/sandbox_network_proxy_test.exs (IP2, lines
- **GEP-0031** — Fail-closed dispatch refusal path (agent.netns_unavailable) has no test coverage
  - _ev:_ GEP-31's 'fail-closed' guarantee (docs/geps/0031-...md:144-154, 'Migration notes', and Implementation shape #1) is implemented in lib/glorbo/agent/dispatch.ex: proxy_netns_unavailable?/1 (lines 1345-1348) refuses Linux `network: proxy` dispatch with {:error, :netns_unavailable} w
- **GEP-0034** — No end-to-end live-write→wipe→reindex roundtrip test for the three GEP-34 gap tables (the load-bearing 'byte-identical to live' invariant)
  - _ev:_ GEP-34 Goal #1 (0034-...md:119-122): reindex must produce a glorbo.db "byte-identical (modulo row IDs/timestamps) to one built by observing every event live." The integration roundtrip test (test/integration/reindex_roundtrip_test.exs) only covers companies/agents/reindex_state a
- **GEP-0037** — Spec mandates a 4-layer test pyramid with at least one pty-backed E2E per view and 100% coverage on Runtime/Renderer/View.*; no pty/E2E test exists and the pure-reducer/snapshot layers are absent
  - _ev:_ §Test strategy "Coverage floor" (1117-1120): "E2E: at least one per view for v1"; §E2E (1110-1115): "One pty-backed test per major view that spawns glorbo tui ... Uses :exec or :erlang.open_port with a pty ... Runs under the existing E2E tag." grep across test/glorbo/shell for pt
- **GEP-0041** — Failure-mode invariant 'block verdict without a reason is rejected' is not enforced — block with empty note succeeds
  - _ev:_ GEP-0041 Failure modes table (line 356): "Reviewer verdict is `block` but no reason given → Reject the outbox message with `peer_review_block_without_reason` reason; don't mutate task". The code has no such guard: `lib/glorbo/actions/tasks.ex:709-711` `validate_note("")` returns 

## 🟡 Medium — Invariant violations (1)

- **GEP-0003** — memory_index_enabled opt-in flag is SQLite-only — violates GEP-3's "nothing in SQLite that can't be rebuilt from disk" corollary; `rm glorbo.db && reindex` silently loses semantic-recall state
  - _ev:_ GEP-3 (docs/geps/0003-filesystem-as-source-of-truth.md:55-58) states the load-bearing corollary: "Nothing in SQLite that can't be rebuilt from disk is allowed. If you catch yourself storing a field that can't be reconstructed, that's a design bug." The GEP-0058 semantic-recall op

## 🗂️ Orphaned features — shipped, no governing GEP

- **Backup/Restore subsystem (security-critical, two CLI verbs) has no governing GEP** (medium)
  - _ev:_ lib/glorbo/backup.ex (8.8k) + lib/glorbo/restore.ex (19k) ship `glorbo backup` / `glorbo restore` (dispatched at lib/glorbo/cli.ex:171-172) and are documented user surface in docs/DESIGN.md:962-963,1052-1055. Both moduledocs cite only archived GSD-v1 planning 
  - _action:_ Write a Standards GEP capturing the backup/restore contract: archive allowlist (companies/, config.md, audit/, glorbo.db), the down-vs-`:force_live` precondition, WAL checkpoint gu
- **Emergency-stop kill switch (load-bearing safety control) has no GEP** (medium)
  - _ev:_ lib/glorbo/emergency_stop.ex (6.4k) is a company-scoped kill switch that SIGKILLs all in-flight Agent.Server dispatches and marks agents `stopped_by_director` (moduledoc cites only `T2-C`). Surfaced via on-disk `EMERGENCY_STOP.md` (lib/glorbo/file_spec/emergen
  - _action:_ Write a Standards GEP defining emergency-stop semantics: scope (company vs agent vs global), what `stop_inflight/1` kills vs leaves, the resulting `last_exit_status`, how the EMERG
- **Content-search backend (`/api/search`, Ctrl+K palette) is consumed by GEPs but governed by none** (low)
  - _ev:_ lib/glorbo/search.ex (14k) + lib/glorbo_web/controllers/search_controller.ex implement the `GET /api/search` content-search over task files + audit rows that backs the Ctrl+K command palette (moduledocs cite issues #232 T2-B / #249, not a GEP). GEP-0030 (tui-r
  - _action:_ Either fold the search backend's contract into the eventual GEP-0058 work as the 'phase 0 / existing keyword search' baseline, or write a short Standards GEP for the current `/api/
- **`glorbo install` / `uninstall` systemd-unit lifecycle has no GEP** (low)
  - _ev:_ lib/glorbo/cli/install.ex (9.0k) ships `glorbo install` / `glorbo uninstall` (dispatched at lib/glorbo/cli.ex:508-509) which write `~/.config/systemd/user/glorbo.service` and run `systemctl --user enable --now`. This is a new host-integration surface (writes o
  - _action:_ Write a Standards GEP for the systemd-unit install path: where the unit file lives, Type=simple + Restart=on-failure rationale, the relationship to `glorbo serve` and the pidfile-b

## ⚪ Low (25) — triage tail

- GEP-0004 `doc_drift`: GEP-0004 has no body cross-reference to GEP-0055 (in-process inference proxy / `via_proxy` auth)
- GEP-0005 `doc_drift`: GEP-5 §"Shape of an invocation" advertises weaker `--unshare-user-try`/`--unshare-cgroup-try` flags than the code emits (strict, non-try)
- GEP-0008 `doc_drift`: GEP-8 D1 ("file-only reply, no stdout fallback") was reversed in code but GEP-8 still asserts it as a hard invariant with no pointer to the 
- GEP-0014 `missing_tests`: Missing integration test that HEARTBEAT.md body actually reaches the dispatched prompt — the GEP's stated end-to-end test is absent
- GEP-0020 `doc_drift`: GEP-0020 §7 (GoalsLive) design superseded by GEP-0063 with no bidirectional supersession link
- GEP-0025 `status_drift`: FileSpec registry moduledoc still declares "scaffolding only — validator/formatter/CLI land in follow-up commits; no existing writer reads f
- GEP-0029 `unimplemented`: mcp_enabled kill switch and mcp_path config (a stated Goal) are completely unimplemented
- GEP-0029 `spec_code_divergence`: GEP-29 declares 'Zero new auth surface' / 'no auth', but the shipped MCP route is gated by a dashboard_token bearer auth that the GEP never 
- GEP-0029 `doc_drift`: GEP-29 Design lists 5 resource families incl. agent stdout, but only 4 are implemented; agent stdout was deferred and never shipped despite 
- GEP-0040 `spec_code_divergence`: Initial `"initial dispatch"` handoff_chain entry is never seeded at task creation
- GEP-0044 `doc_drift`: GEP design specifies an `--init-from-fixture` harness flag that does not exist in the code
- GEP-0045 `spec_code_divergence`: D4 + Schema: GEP mandates an `rw` host bind to `~/.local/share/stado` that the shipped provider TOML deliberately dropped (security-relevant
- GEP-0046 `status_drift`: GEP-46 status `Implemented` overstates test-strategy completion
- GEP-0055 `doc_drift`: GEP Goals advertise Gemini support and bundled-provider flip 'on day one', but Gemini auth is an unwired no-op and zero bundled providers us
- GEP-0057 `doc_drift`: D6's canonical `researcher` role example does not carry the `research/` template it is defined by
- GEP-0058 `doc_drift`: GEPs README index lists 0058 as "Draft" while the feature is shipped
- GEP-0062 `status_drift`: GEP-0062 status is stale: still 'Accepted' though the design shipped to main (PR #57), and the GEP's own note instructs flipping to 'Impleme
- GEP-changelog-status-drift `status_drift`: GEP-0056 status: Draft but shipped in CHANGELOG [Unreleased] (Security section)
- GEP-changelog-status-drift `status_drift`: GEP-0057 status: Draft but shipped in CHANGELOG [Unreleased] (deep-research task type)
- GEP-changelog-status-drift `status_drift`: GEP-0058 status: Draft but shipped in CHANGELOG [Unreleased] (semantic recall index)
- GEP-changelog-status-drift `status_drift`: GEP-0061 status: Accepted but shipped in CHANGELOG [Unreleased] / merged in PR #55
- GEP-changelog-status-drift `status_drift`: GEP-0062 status: Accepted but shipped in CHANGELOG [Unreleased] / merged in PR #57
- GEP-orphaned-code `orphaned_code`: Content-search backend (`/api/search`, Ctrl+K palette) is consumed by GEPs but governed by none
- GEP-orphaned-code `unimplemented`: `glorbo install` / `uninstall` systemd-unit lifecycle has no GEP
- GEP-readme-drift `doc_drift`: README CLI Reference omits two shipped, user-facing verbs: `glorbo fit` and `glorbo memory`

## Recommended next actions (prioritized)

1. **Status-drift sweep (cheap, high-value, directly serves the new
   lockstep rule).** One docs PR flipping the stale statuses + appending
   `history:` entries (append-only, per GEP-1 — don't rewrite bodies):
   - `GEP-0055` → **Implemented** — *most urgent: it shipped in tagged,
     released v0.26.0 while reading Draft.*
   - `GEP-0056 / 0057 / 0058 / 0059` → **Implemented** (note any deferred
     slices, e.g. GEP-59 `--serve`).
   - `GEP-0061 / 0062` → **Implemented** (merged in #55 / #57).
   - `GEP-0037` → **Implemented** (7 phases shipped v0.10–v0.17).
   - `GEP-0023 / 0040 / 0046` → correct the overstated "Implemented"
     notes (or downgrade to partial) honestly.

2. **The 6 high gaps — decide "build vs. amend GEP" for each.** Several
   are real invariant breaks, not just doc lag:
   - **GEP-0036 single-write-channel break** — task LiveView mutations
     bypass `Glorbo.Actions` via `TaskDefinition.write*`. This is the
     same write-path-discipline class as GEP-63; worth closing for real.
   - **GEP-0023 egress** — no audit events + permanent 403 instead of the
     specced approval sentinel/503. The GEP advertises a security UX the
     proxy doesn't have.
   - **GEP-0041 peer-review trigger** — only fires under Director
     approval, not standalone `severity`/`peer_review_required`.
   - **GEP-0046** — add the two mandated cross-company concurrency
     integration tests (or drop the commitment honestly).

3. **Orphaned security-critical subsystems → write GEPs.**
   Backup/Restore and Emergency-stop are load-bearing safety/DR controls
   with no design record. These deserve real Standards GEPs.

4. **Invariant fix — GEP-3 rebuildability.** The semantic-recall opt-in
   (`memory_index_enabled`) is SQLite-only, so `rm glorbo.db && reindex`
   silently loses it — violating "nothing in SQLite that can't be rebuilt
   from disk." Persist the opt-in to disk, or carve it out in GEP-3.

5. **Quick doc fixes.** Permission-resource whitelist (DESIGN/CLAUDE list
   6 resources the ACL mapper rejects at parse time), DESIGN §4.4 sandbox
   flags (`--clearenv` missing), README CLI table (`glorbo fit`/`memory`).

The `medium` divergence/doc-drift tail is real but not urgent — triage in
a follow-up pass; each item names the file:line + a build-or-amend choice.

---

## Resolution status (2026-06-14, `/goal fix all the findings`)

All 107 confirmed findings reconciled across 6 PRs (the strict GEP-update rule
from #60 is the mechanism the rest follow). Approach: reconcile each so it is
no longer true — status flips, doc/comment fixes, append-only GEP notes, new
GEPs for orphaned subsystems, and code fixes for the genuine bugs.

| PR | Scope | Findings covered |
|---|---|---|
| #60 | Strict "keep the GEP in lockstep with code" rule (CLAUDE.md + ship-checklist) | (the mechanism) |
| #61 | Status-drift sweep — 8 GEPs → Implemented + README index sync | 17 status_drift |
| #62 | DESIGN permission whitelist + sandbox flags, README verbs, false moduledocs | DESIGN/README/moduledoc doc_drift + the GEP-3 moduledoc half of the invariant finding |
| #63 | Append-only `Implementation reconciliation` notes on 39 GEPs | 85 GEP-body findings (doc_drift, spec_code_divergence, unimplemented, missing_tests, status nuances) |
| #64 | New GEPs 0064/0065/0066 (backup-restore, emergency-stop, ops surfaces) | 4 orphaned-code findings |
| #65 | **Code fix** — block/revise peer-review verdict now requires a reason | GEP-41 block-without-reason failure-mode |

**Disposition of the 6 high findings:**
- GEP-55 released-but-Draft → **fixed** (#61).
- GEP-41 trigger / block-reason → block-reason **fixed in code** (#65); the
  "fires only under Director approval" trigger gap is recorded as-shipped (#63).
- GEP-36 single-write-channel, GEP-23 egress audit/403→503, GEP-46 missing
  integration tests → recorded as **known-gap / deferred** in their GEP notes
  (#63). These are genuine *capability* gaps in shipped features; closing them
  is feature/test engineering (build `Actions.Tasks.update_status`, emit egress
  audit rows + approval sentinels, write the two concurrency integration tests)
  rather than drift to reconcile — tracked honestly in each GEP for a follow-up.

**Genuine code/test bugs still open (documented, not yet code-fixed):** GEP-3
memory opt-in persistence (invariant), GEP-42 FileSpec classify shadowing,
GEP-61 credentials-dir `..` guard. Each names file:line + a fix path in its #63
note; small enough to close in a follow-up code PR if prioritized.
