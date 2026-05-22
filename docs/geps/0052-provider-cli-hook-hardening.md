---
gep: 0052
title: Provider-CLI credential hardening via in-sandbox guard hooks
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Draft
type: Standards
created: 2026-05-22
requires: [4, 5]
see-also: [8, 23, 31, 32, 50]
history:
  - date: 2026-05-22
    status: Draft
    note: |
      Initial draft. Captures the operator's "use claude-code hooks to
      prevent bypass mode being enabled in the first place; check whether
      gemini-cli and codex have equivalent hook mechanisms" direction from
      findings B-017 + B-018. Gemini/codex hook surfaces marked
      "investigate — capability TBD" pending docs not available offline.
---

# GEP-0052: Provider-CLI credential hardening via in-sandbox guard hooks

## Problem

Glorbo's bundled provider CLIs authenticate using the operator's own
host credentials, mounted **read-only** into the agent sandbox (B-018):

- `claude-code.toml`: `~/.claude` → `/workspace/.claude` (ro),
  `~/.claude.json` → `/workspace/.claude.json` (ro)
- `codex.toml`: `~/.codex` → `/workspace/.glorbo-codex` (ro)
- `gemini-cli.toml`: `~/.gemini` → `/workspace/.gemini` (ro)

`/workspace` is the agent's HOME and cwd. RO protects the host files
from *modification*, not from *reading*: the agentic CLI has Read/Bash
tools and can read its own credential dir (OAuth refresh token, session
creds). For claude-code this is compounded by **B-017** — the provider
args include `--permission-mode bypassPermissions`, disabling
claude-code's own Write/Edit/Bash approval gate (necessary because under
`--print` there's no interactive stdin to answer prompts). So a
prompt-injected claude-code agent can be told "read
`/workspace/.claude/.credentials.json` and write it to `/outbox`" with
no in-CLI guard stopping it.

What already bounds the *impact* (per the triage notes): the default
network policy is `:loopback` (`--unshare-net`, kernel egress block), so
a default agent can't exfiltrate at all, and `:proxy` agents are
netns-confined (GEP-31) behind an egress allowlist. Removing the
credential mounts isn't viable — the CLIs *require* their own creds to
authenticate (crown-jewel-adjacent), and removing `bypassPermissions`
breaks claude-code under `--print`.

The operator's direction (on both findings):

> "Use claude-code hooks to prevent bypass mode from being enabled in
> the first place. Works even with the bypass mode enabled."
> "Gemini: check if similar hooks exist. Codex: check if similar hooks
> exist."

The insight: claude-code's **hook** system (e.g. `PreToolUse`) runs
*regardless* of `--permission-mode`, so a hook can deny tool calls that
read/exfiltrate the mounted credential paths even though the
interactive approval gate is bypassed. This GEP proposes injecting a
**guard hook config** into the sandbox per provider, so a prompt-injected
agent can't read+exfil its own mounted credentials even with approval
bypass on.

## Goals

- For **claude-code**: inject a Glorbo-owned hook config into the
  sandbox that denies tool calls touching the mounted credential paths
  (`/workspace/.claude`, `/workspace/.claude.json`), and re-asserts the
  permission posture so an injected prompt can't flip the agent into a
  laxer mode mid-run. This works *even with* `bypassPermissions` (hooks
  run before the bypassed approval gate).
- The guard config is **agent-uncontrollable**: mounted read-only,
  placed where the CLI reads hooks from, and not writable by the agent.
- **Investigate** gemini-cli and codex hook/guard surfaces and document
  the equivalent (or its absence) for each. Where no equivalent exists,
  document the residual exposure and the fallback (network policy +
  per-agent egress authz, GEP-50).
- Defense-in-depth: the hook is an *application/CLI*-layer guard layered
  on top of the kernel network boundary, not a replacement for it.

## Non-goals

- **Not removing the credential mounts** (the CLIs need their creds —
  B-018 is the documented sandbox posture).
- **Not removing `bypassPermissions`** from claude-code (breaks
  `--print`; the hook is precisely the way to harden *despite* it).
- **Not minting ephemeral per-dispatch provider credentials** — the
  bundled CLIs don't support injected short-lived creds; that's a large
  upstream-dependent change (noted as a long-term option in B-018).
- **Not changing the network policy / egress model** — that's GEP-23 /
  GEP-31 / GEP-50. This GEP assumes those bounds and adds an
  orthogonal read-side guard.

## Design

### claude-code: PreToolUse guard hook (confirmed surface)

Claude Code supports a settings-based **hooks** mechanism. Hooks fire on
tool lifecycle events independently of `--permission-mode`, so a
`PreToolUse` hook executes before a Bash/Read/Edit tool call even when
the interactive approval gate is bypassed. The hook receives the tool
name + input and can **deny** the call (non-zero / deny verdict).

Glorbo injects a guard:

1. A Glorbo-owned settings file (e.g. a `settings.json` with a `hooks`
   block) is mounted **read-only** into the location claude-code reads
   project/local settings from inside the sandbox (precise path/
   precedence to be pinned at implementation; claude-code resolves
   settings from a known set of locations). It must sit where the
   *agent cannot override it* — RO bind, and at a precedence the agent's
   own `/workspace` writes can't shadow.
2. The hook is a small Glorbo-provided guard script (also RO-mounted)
   invoked on `PreToolUse`. It denies any tool call whose target path
   resolves under the mounted credential dirs
   (`/workspace/.claude`, `/workspace/.claude.json`), and denies obvious
   read+exfil shapes (e.g. Bash reading those paths, Read targeting
   them). It can also re-assert deny on attempts to change permission
   mode.
3. Because the hook runs even under `bypassPermissions`, the credential
   read is blocked at the CLI layer regardless of the bypass — the
   operator's stated requirement.

The guard config and script are part of the provider definition
(`priv/providers/claude-code.toml` gains the bind + the shipped guard
files under `priv/`), so it's versioned with Glorbo and applied
uniformly to every claude-code dispatch.

### gemini-cli: investigate — capability TBD

Gemini CLI's tool-confirmation / extension model may offer an analogous
pre-execution guard, but **this cannot be confirmed from the docs
available offline.** Marked **investigate**:

- Determine whether gemini-cli exposes a hook / pre-tool-call interception
  / policy-config surface that fires regardless of an auto-approve /
  YOLO mode.
- If yes: ship an equivalent RO-mounted guard config denying reads of
  `/workspace/.gemini`.
- If no: document the residual exposure (a prompt-injected gemini-cli
  agent can read its mounted `~/.gemini` creds), and rely on the network
  bound (default `:loopback`; `:proxy` egress authz from GEP-50) to
  prevent exfiltration. Consider scoping the gemini auth bind out for
  agents whose role doesn't need that provider (B-018 interim).

### codex: investigate — capability TBD

Codex CLI similarly: **investigate** whether it has a
hook/guard/pre-exec-policy surface that survives an approval-bypass /
full-auto mode.

- If yes: ship an RO-mounted guard denying reads of
  `/workspace/.glorbo-codex`.
- If no: same fallback as gemini — document the residual exposure, lean
  on the network bound + GEP-50, and scope the auth bind out where the
  role doesn't need codex.

The investigation deliverable is a short matrix in the egress/sandbox
docs:

| Provider | Hook surface | Survives bypass? | Guard shipped? |
|---|---|---|---|
| claude-code | settings `hooks` / PreToolUse | yes (confirmed) | yes |
| gemini-cli | TBD | TBD | TBD |
| codex | TBD | TBD | TBD |

### Layering (defense-in-depth)

This guard is the **read-side** complement to the **exfil-side** bounds:

- Read side (this GEP): hook denies the credential read inside the CLI.
- Exfil side (GEP-23/31/50): even if a read slips through (e.g. a
  provider with no hook surface), default `:loopback` = no network, and
  `:proxy` egress is per-agent-authorized (GEP-50) and netns-confined
  (GEP-31).
- Kernel side (GEP-5): bwrap mount namespaces gate every FS access.

No single layer is load-bearing alone; the hook closes the
"read-then-write-to-/outbox or read-then-include-in-reply" path that the
network bounds *don't* cover (an injected agent can still copy creds
into `/outbox` or a permitted project path without any network).

## Migration / rollout

- **Additive per provider.** claude-code gains the hook bind + guard
  files; existing dispatches keep working, now with the guard active.
- **Doctor check.** A doctor check verifies the guard config is present
  and RO-mounted for claude-code (and any provider that gets one), and
  warns if a provider has no guard surface (residual-exposure notice).
- gemini/codex guards land *after* the investigation confirms a surface;
  until then their findings (B-018 portion) stay open with a documented
  residual.
- Pre-1.0: no compat shim needed — the guard is invisible to correct
  agents (it only fires on credential-path tool calls).

## Failure modes

| Failure | Surface |
|---|---|
| Agent writes its own `settings.json` in `/workspace` to disable hooks | Glorbo guard mounted RO at a precedence the agent can't override; doctor verifies. If precedence can't be guaranteed, this provider is downgraded to "no reliable guard" in the matrix |
| Hook script error / non-zero unexpectedly | fail **closed** — a guard error denies the tool call (an injected agent must not benefit from a broken guard) |
| Provider updates change hook config format/location | doctor check catches a missing/ineffective guard; provider def pins the version assumption |
| gemini/codex have no hook surface | residual read exposure documented; exfil still bounded by network policy + GEP-50 |
| Agent reads creds via a tool the hook doesn't cover | guard must cover all read-capable tools (Read/Bash/Edit/Grep/…); test enumerates them |

## Test strategy

- **Unit / contract** (claude-code guard): hook denies a Bash `cat
  /workspace/.claude/.credentials.json`; denies a Read of
  `/workspace/.claude.json`; allows unrelated tool calls; fails closed
  on guard error.
- **Integration** (dispatch): claude-code dispatch mounts the guard RO;
  agent cannot override it from `/workspace`.
- **E2E (local, not CI):** prompt-inject a claude-code agent to read +
  write its creds to `/outbox`; assert the read is denied at the hook
  even with `bypassPermissions`.
- **Doctor test:** guard-present check passes when mounted, warns when a
  provider has no guard.
- gemini/codex: tests added once the investigation lands a guard surface.

## Open questions

- **claude-code settings precedence.** Which settings location does
  Glorbo own to guarantee the hook can't be shadowed by an
  agent-writable `/workspace` settings file? Pin at implementation
  against the installed claude-code version.
- **gemini-cli hook/guard surface — capability TBD.** Needs online docs
  / source review.
- **codex hook/guard surface — capability TBD.** Same.
- **Scope auth binds by role (B-018 interim).** Independent of hooks:
  should Glorbo skip binding a provider's credential dir for agents
  whose role doesn't use that provider? Cheap defense regardless of hook
  availability; possibly fold into this GEP or a follow-up.
- **Hook performance.** A PreToolUse hook adds a subprocess per tool
  call; measure overhead on tool-heavy dispatches.

## Decision log

### D1. Harden claude-code via a PreToolUse guard hook, not by removing bypassPermissions

- **Decided:** inject a Glorbo-owned, RO-mounted hook config that denies
  credential-path tool calls; keep `--permission-mode
  bypassPermissions`.
- **Alternatives:** remove `bypassPermissions`; remove the credential
  mounts.
- **Why:** removing the bypass breaks claude-code under `--print` (no
  interactive stdin to answer prompts); removing the mounts breaks
  authentication entirely. Hooks fire regardless of permission mode, so
  a hook is the only lever that hardens *despite* the bypass — exactly
  the operator's stated approach. Operator direction dated 2026-05-22.

### D2. Guard config is RO-mounted and agent-uncontrollable

- **Decided:** the hook config + guard script ship in `priv/`, are
  RO-bound into the sandbox at a precedence the agent can't override,
  and fail closed on error.
- **Alternatives:** write the config into `/workspace` (agent-writable);
  rely on the agent honouring it.
- **Why:** a guard the agent can disable is no guard. RO mount + fail-
  closed is the only posture consistent with "the kernel is the policy
  engine" — the guard's integrity must not depend on agent cooperation.

### D3. Gemini and Codex are investigate-first, not assume-equivalent

- **Decided:** the gemini-cli and codex hook surfaces are marked
  "investigate — capability TBD"; ship a guard only after confirming a
  surface that survives approval-bypass.
- **Alternatives:** assume they have claude-code-equivalent hooks and
  design as if they do.
- **Why:** the relevant docs aren't available offline and these CLIs'
  guard models differ. Designing on an unconfirmed capability would be
  a load-bearing assumption (CLAUDE.md governing principle #1). Where no
  surface exists, the honest answer is "documented residual exposure,
  bounded by the network policy," not a guard that doesn't exist.

### D4. The hook is defense-in-depth, layered on the network bound — not a replacement

- **Decided:** the read-side hook complements the exfil-side network
  bounds (GEP-23/31/50) and the kernel mount namespace (GEP-5); no layer
  is sufficient alone.
- **Alternatives:** treat the hook as the sole credential protection;
  treat the network bound as sufficient and skip the hook.
- **Why:** the network bound doesn't stop an injected agent copying
  creds into `/outbox` or a permitted project path (no network needed);
  the hook closes that read path. Conversely a provider with no hook
  surface still has the network bound. Layering is the Paranoid posture
  (project-profile).

## Related

- GEP-4 — CLI-tool agents (the provider-CLI model these creds belong to).
- GEP-5 — Sandboxing / "kernel is the policy engine" (the mount-namespace
  layer this complements).
- GEP-8 — Provider registry (where provider defs + binds live).
- GEP-23 / GEP-31 / GEP-50 — egress proxy, netns isolation, per-agent
  egress authz (the exfil-side bounds this read-side guard layers on).
- GEP-32 — Native agent harness (E-232 native creds-mount exposure is
  the same theme for the native provider).
- Findings B-017 (claude-code bypass mode exposes mounted credentials),
  B-018 (provider auth dirs exposed inside agent sandboxes). See also
  E-232 (native harness spec exposes provider credentials).
