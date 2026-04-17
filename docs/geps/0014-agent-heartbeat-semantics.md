---
gep: 0014
title: Agent heartbeat semantics and HEARTBEAT.md
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-04-17
history:
  - date: 2026-04-17
    status: Draft
    note: Initial draft — HEARTBEAT.md contract + scheduler reuse.
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

Concrete flow the scope requested for:

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
- `Glorbo.Company.Scheduler` — existing cron scheduler (AGT-02).
