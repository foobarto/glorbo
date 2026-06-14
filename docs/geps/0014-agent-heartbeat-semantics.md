---
gep: 0014
title: Agent heartbeat semantics and HEARTBEAT.md
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-17
updated: 2026-04-17
history:
  - date: 2026-04-17
    status: Draft
    note: Initial draft — HEARTBEAT.md contract + scheduler reuse.
  - date: 2026-04-17
    status: Implemented
    note: >-
      Scheduler reads HEARTBEAT.md on wake; missing/blank/oversize
      → `agent.heartbeat_skipped`; present → existing `agent.wake`
      path. Scaffolders drop a default stub. Sandbox bind-mount
      (open question #1) deferred to the CLI-adapter wiring phase.
---

# GEP-14: Agent heartbeat semantics and HEARTBEAT.md

## Problem

`Glorbo.Company.Scheduler` already exists (AGT-02) and wakes agents
on a cron expression read from `agent.md`'s `heartbeat:` field. But
a "wake" today is just an event — the agent process spins up and
the CLI is invoked, but there's no *instruction* attached to the
wake. The agent has nothing to *do* with the tick.

What's needed: every heartbeat wake should deliver a pointer to
an agent-authored `HEARTBEAT.md` file that tells the CLI what to
check, what to proactively report, and when to trigger downstream
actions. Think "cron job but agent-authored in natural language."

Concrete requested flow:

1. Agent `ceo` has `heartbeat: "*/30 * * * *"` in `agent.md`.
2. Every 30 minutes, the scheduler fires a wake event.
3. The agent gets invoked with the contents of
   `agents/ceo/HEARTBEAT.md` as the system/user prompt.
4. The file might say: "Check your inbox. If anything's urgent,
   post in #general. If budget > 80%, alert the Director."
5. The agent runs the CLI, writes to outbox if needed, exits.

## Goals

- `HEARTBEAT.md` is the canonical source of "what should this agent
  do on wake" — user-editable, under the agent directory, no special
  syntax.
- Heartbeat wakes are distinguishable from inbox/mention wakes in
  the audit trail (`trigger: "heartbeat"`).
- Missing `HEARTBEAT.md` → heartbeat wake is skipped with an audit
  event, not an error (an agent that hasn't authored a heartbeat
  intentionally just doesn't do anything on tick).
- Zero new plumbing in the scheduler — reuse the existing cron path.

## Non-goals

- Heartbeat parameter passing. The file is static; the agent reads
  the whole thing on each wake.
- Per-project heartbeats. A task that needs periodic polling belongs
  in `HEARTBEAT.md` as "check project/foo" rather than as task
  metadata.
- Sub-minute heartbeats. The cron expression's floor is 1 minute;
  that's fine for organizational pacing.

## Design

### On-disk layout

```
companies/<co>/agents/<slug>/
├── agent.md           # identity, permissions, heartbeat cron
├── HEARTBEAT.md       # (NEW) instructions for cron-triggered wakes
├── inbox/
├── outbox/
└── workspace/
```

`HEARTBEAT.md` is a plain markdown file. No frontmatter required.
Example:

```markdown
# Heartbeat — ceo

Every 30 minutes:

1. Read the company audit tail (`audit/*.jsonl`).
2. If anything failed (`action: agent.error` or `approval.denied`),
   post a brief summary to `#general` via outbox.
3. If budget used > 80%, ping @director.
4. Otherwise: no-op. Exit cleanly.
```

### Wake path

The scheduler's `dispatch_fun.(:heartbeat)` callback is the
existing hook. Today it fires `agent.wake` with `trigger: "heartbeat"`
and kicks the agent's supervisor. This GEP adds one step *before*
that:

1. Scheduler fires tick.
2. Scheduler resolves `agents/<slug>/HEARTBEAT.md`.
3. If missing → emit `agent.heartbeat_skipped` audit event with
   `reason: "no_heartbeat_file"` and return.
4. If present → write
   `agents/<slug>/state/heartbeat-<ts>.md` with frontmatter
   `{ts, trigger: "heartbeat"}` and a body that references
   `HEARTBEAT.md`. (Same wake-file shape the scheduler already
   uses for heartbeats; no new watchlist.)
5. Emit `agent.wake` audit with `trigger: "heartbeat"`.
6. Agent.Server picks it up and invokes the CLI.

The CLI gets `HEARTBEAT.md` bind-mounted `ro` into the sandbox at
a known path (`/agent/HEARTBEAT.md`), and the invocation prompt
template interpolates it. That interpolation is a provider-adapter
concern (GEP-8) — each provider decides how to frame "here are your
standing orders."

### agent.md wiring

No change required. The existing `heartbeat: "*/30 * * * *"` cron
stays authoritative. A new optional field:

```yaml
heartbeat_file: HEARTBEAT.md   # default
```

for users who want to point elsewhere (e.g. split per-day
heartbeats). Default is `HEARTBEAT.md` if unspecified.

### Prompt template

Each provider's TOML manifest (GEP-8) declares how to inject
`HEARTBEAT.md` contents into the invocation prompt. Proposed
default: read the file at wake time, pass as a `--prompt-file`
argument where the CLI supports it, or prepend to stdin otherwise.

The provider adapter layer is the right home for this because
claude-code / gemini-cli / codex all have different prompt-delivery
shapes. `priv/providers/claude-code.toml` already supports
`prompt_mode = "stdin"` — the heartbeat content slots into stdin
the same way.

## Migration / rollout

v0.0.2 + v0.0.3 agents don't have `HEARTBEAT.md`. Behaviour before
this GEP: scheduler fires, agent wakes, agent has nothing to do and
the CLI invocation is a no-op. Behaviour after this GEP: scheduler
fires, HEARTBEAT.md missing, *heartbeat is skipped entirely* with
an audit event.

The user-visible difference is the audit event (`agent.heartbeat_skipped`),
which is good — it surfaces "this agent isn't scheduled to do anything
useful" rather than hiding it in a no-op CLI invocation.

Migration path: `glorbo new agent <name>` scaffolding writes a stub
`HEARTBEAT.md` with a sensible default (`Check your inbox; reply
if anything needs attention; otherwise exit.`). Existing agents
need the user to author one.

## Failure modes

- **HEARTBEAT.md too large.** Cap at 10 KiB (same as other frontmatter
  limits). Over-cap → emit `agent.heartbeat_error` audit with
  `reason: "file_too_large"`, skip the wake.
- **HEARTBEAT.md with only whitespace.** Treat as "skip" — same
  audit path as missing file.
- **Cron parse error** (already handled upstream): Scheduler's
  existing `:invalid_cron` path doesn't change.
- **Clock skew / long VM pauses.** Existing scheduler already
  re-arms from wall clock each time, not from armed-time. No change.

## Test strategy

- `Scheduler` unit test: fires a heartbeat → HEARTBEAT.md present →
  `state/heartbeat-<ts>.md` written + `agent.wake` with
  `trigger: "heartbeat"`.
- `Scheduler` unit test: fires a heartbeat → HEARTBEAT.md missing →
  `agent.heartbeat_skipped` audit event, no wake file.
- Integration test: write a HEARTBEAT.md, wait for the scheduled
  tick, assert the CLI was invoked with the file contents reaching
  stdin (dep-inject the CLI via the existing provider test shim).

## Open questions

1. **Where does HEARTBEAT.md live in the sandbox?** Bind-mounted
   `ro` at `/agent/HEARTBEAT.md`? Or injected via the prompt
   pipeline only? The former is more discoverable from inside the
   agent (can `cat` it for reference); the latter keeps the sandbox
   lighter. Proposed: bind-mount at `/agent/HEARTBEAT.md` — it's
   one extra `--ro-bind` line and mirrors how `agent.md` is
   surfaced.
2. **What happens if the agent's HEARTBEAT.md @mentions another
   agent?** Should the wake path route mentions like `post_message`
   does? Lean toward yes — a heartbeat saying "@cto check your
   inbox every 30m" should indirectly wake the CTO. But: that
   chains heartbeats indefinitely if both agents @mention each
   other. Defer; v0.0.3 heartbeats don't route mentions.
3. **How does this interact with `wake-request.md`?** The Director
   can already drop a wake-request via `GlorboWeb.Actions.wake_agent/3`.
   A wake-request carries a `reason`; a heartbeat carries the full
   HEARTBEAT.md. Both go through the same agent-server wake path
   but with different `trigger:` values. No change here — just
   explicit that both paths coexist.

## Decision log

### D1. Heartbeat instructions live in `HEARTBEAT.md`, not `agent.md`

- **Decided:** A separate file, not a `heartbeat_prompt:` string
  field in `agent.md`.
- **Alternatives:** Embed the prompt in `agent.md` frontmatter.
- **Why:** (a) `agent.md` is identity metadata — mixing in
  multi-paragraph prose makes it harder to diff. (b) Editors treat
  a `.md` file as prose; YAML strings in frontmatter are awkward
  for multi-paragraph content. (c) One file, one concern.

### D2. Missing HEARTBEAT.md = skip, not error

- **Decided:** If the file is absent, emit an audit event and
  return. No CLI invocation.
- **Alternatives:** Fall back to a default prompt like "check your
  inbox." Emit a warning every tick.
- **Why:** An agent without a heartbeat file has *explicitly*
  opted out of proactive work. A default prompt smuggles in
  behaviour the user didn't ask for. The audit event makes the
  skip visible.

### D3. Reuse the scheduler — no new supervision child

- **Decided:** `Glorbo.Company.Scheduler` stays the single cron
  source; its `dispatch_fun` gets extended to check for the file,
  not replaced with a new `Glorbo.Company.Heartbeat` module.
- **Alternatives:** New module per-agent that owns the HEARTBEAT.md
  read + injection.
- **Why:** Scheduler already does exactly the thing — pick up each
  agent's cron, arm a timer, fire the callback, re-arm from wall
  clock. Layering another module on top just to read a file is
  over-engineering (see CLAUDE.md coding discipline §2).

## Related

- [GEP-4](./0004-cli-tool-agents.md) — CLI-tool agent runtime; the
  wake path delivering HEARTBEAT.md is a CLI-adapter concern.
- [GEP-8](./0008-provider-registry-and-auto-detect.md) — provider
  TOMLs are where each CLI's prompt-delivery shape is declared.
- [GEP-15](./0015-allcaps-agent-md-convention.md) — ALLCAPS naming
  convention for agent-facing contract files; `HEARTBEAT.md` is the
  second file to adopt it.
- `Glorbo.Company.Scheduler` — existing cron scheduler (AGT-02).

## Implementation reconciliation (2026-06-14)

Append-only record per GEP-1: an Accepted/Implemented GEP's body is not rewritten; deviations between the §agent.md-wiring / §Test-strategy text above and the shipped code are recorded here.

- **`heartbeat_file:` redirect field — known-gap (reproduced).** The GEP (§agent.md wiring, lines 124–132) advertises an optional `heartbeat_file: HEARTBEAT.md` field "for users who want to point elsewhere." The field is accepted by the AGENT.md validator (`lib/glorbo/file_spec/agent_md.ex:32,72`) and documented as a real field (`docs/file-formats/agent_v1.md:16,36`), so it validates cleanly — but it is never honored by any consumer. The agent.md parser reads only `heartbeat` (the cron) into the spec (`lib/glorbo/agent/parser.ex:147,168`); `Glorbo.Agent.Spec` has a `:heartbeat` field but no `:heartbeat_file` (`lib/glorbo/agent/spec.ex:93`). Both consumers hardcode the literal `"HEARTBEAT.md"`: the scheduler resolver `Scheduler.default_heartbeat_lookup/3` (`lib/glorbo/company/scheduler.ex:295`) and the prompt composer `read_system_prompt/2` (`lib/glorbo/agent/server.ex:1735`). Disposition: real gap — either thread the field through parser → spec → both resolvers, or drop the unimplemented redirect from the validator, `agent_v1.md`, and the GEP-suggested default. Lower-risk and consistent with the project's pre-1.0 "no kid gloves" stance is to drop it until a consumer actually needs per-day heartbeats.

- **End-to-end test that HEARTBEAT.md body reaches the dispatched prompt — known-gap (reproduced).** §Test strategy (lines 183–185) requires an integration test asserting "the CLI was invoked with the file contents reaching stdin." The injection code exists at `lib/glorbo/agent/server.ex:1734–1742` (`read_system_prompt/2` embeds the HEARTBEAT.md body under a `## Heartbeat checklist` section via `compose_prompt/4`), but no test exercises that link. The scheduler tests (`test/glorbo/company/scheduler_test.exs`) only cover the present/missing/blank/oversize → wake-vs-skip decision with a stubbed `heartbeat_file_fun`, never the prompt body. `test/glorbo/agent/untrusted_provenance_test.exs:8` explicitly states it pins the provenance contract *without* faking the disk-reading `compose_prompt/4` pipeline, and `compose_prompt/4` + `read_system_prompt/2` are both private (`defp`), so the body→prompt path is wholly untested. Disposition: real gap — add a test that drives the dispatch/prompt-composition path with a real HEARTBEAT.md on disk and asserts the body text (under `## Heartbeat checklist`) appears in the composed prompt, closing the only untested link in the present→wake→dispatch chain.
