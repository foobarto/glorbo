---
gep: 0045
title: Stado as glorbo provider via ACP (Agent Client Protocol) transport
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-05-04
requires: [4, 5, 8]
see-also: [9, 23]
history:
  - date: 2026-05-05
    status: Implemented
    note: |
      All four phases shipped (see the phase table below): ACP
      JSON-RPC client + `prompt_mode = "acp"` provider loader
      (Phase 1, 2026-05-04), the stado smoke bench (Phase 2), per-frame
      `cli.acp.<role>.<kind>` audit emission + GEP-32 static catalog
      wiring + `stado_acp` usage parser (Phase 3, 2026-05-04), and the
      `gemini-cli-acp` / `codex-acp` / `claude-code-acp` sibling
      provider TOMLs (Phase 4, 2026-05-05). Status was left at Draft by
      oversight; flipped to Implemented during the 2026-05-21 docs pass.
  - date: 2026-05-04
    status: Draft
    note: |
      Initial draft framed the integration as "agents use claude-code
      as outer LLM, stado-mcp-server as a tool source." Maintainer
      corrected the shape: stado is a complete standalone agent
      runtime — calls its own configured model with its own tools.
      The right glorbo shape is stado-as-provider parallel to
      claude-code / codex / gemini-cli / opencode (matching dogfood
      doc option 1, "Add a stado provider adapter"), and the user's
      "MCP/ACP > stdio prompt" preference refers to the TRANSPORT
      glorbo uses to drive stado, not the model of integration.
      ACP is what stado already exposes (`stado acp`, JSON-RPC 2.0
      over stdio per Zed's Agent Client Protocol), so this GEP
      extends GEP-8's provider-registry pattern with a new
      `prompt_mode = "acp"` rather than the original draft's
      MCP-config-injection scaffolding.
---

# GEP-45: Stado as glorbo provider via ACP transport

## Problem

Glorbo agents pick a CLI provider (`provider: claude-code`,
`provider: codex`, `provider: gemini-cli`, `provider: opencode`)
declared in their AGENT.md. Each provider in `priv/providers/<name>.toml`
declares the binary, its argv template, the auth dirs to bind into
the sandbox, and the reply-file contract used to collect the agent's
answer (GEP-8). Every shipped provider uses
`prompt_mode = "stdin"` — glorbo writes the prompt to the CLI's
stdin and the CLI writes prose to `$GLORBO_REPLY_PATH`.

Stado (`foobarto/stado`) is a fully self-contained agent runtime —
it calls its own configured model (anthropic / openai / google /
groq / ollama-cloud / any OAI-compat preset), uses its own bundled
tools (webfetch / ripgrep / ast-grep / lsp / fs / bash), and emits
its own audit trace into a per-session git ref. It's a peer of
claude-code in glorbo's sense: a thing glorbo dispatches a task to,
not a thing claude-code calls into.

Two reasons stado doesn't drop into the existing provider pattern:

1. **Driving stado via subprocess + stdin prompt is the wrong
   transport.** Stado already exposes `stado acp` — JSON-RPC 2.0
   over stdio, the canonical Agent Client Protocol shape used by
   editors (notably Zed). Per the dogfood note from the
   field-testing workflow integration:

   > "tbh best way to use stado is with MCP or ACP rather than via
   > stdio prompt"

   ACP is the right transport when the surrounding system wants
   structured agent semantics (initialize / session/new /
   session/prompt / session/cancel / streamed progress) rather than
   "shove a prompt into stdin and read whatever comes out."

2. **The stdin-prompt provider TOML doesn't model JSON-RPC.**
   `prompt_mode = "stdin"` writes the prompt as bytes to the CLI's
   stdin. ACP needs a JSON-RPC handshake (`initialize` →
   `session/new` → `session/prompt`) followed by streamed updates
   the dispatcher needs to assemble into the reply file. That's a
   different code path inside glorbo's dispatcher.

## Proposal

Extend GEP-8's provider registry with a new transport mode and
ship stado as the first provider that uses it.

### Schema — `prompt_mode = "acp"` on provider TOML

`priv/providers/stado.toml`:

```toml
name   = "stado"
binary = "stado"

# stado acp speaks JSON-RPC 2.0 over its own stdio. --tools opens
# the full audited executor loop; --no-tools is also valid for
# prompt-only agents that should not touch the host filesystem.
args        = ["acp", "--tools"]
prompt_mode = "acp"

# Stado writes its reply through ACP messages — glorbo assembles
# them into the on-disk reply file using the same contract as
# stdin-prompt providers.
reply_dir               = "{workspace}/.glorbo/outbox"
reply_filename_template = "{timestamp}-{invocation_id}.md"
reply_max_bytes         = 1_048_576

version_flag        = "--version"
version_regex       = '(\d+\.\d+\.\d+)'
allow_version_probe = true

# Stado's per-user state — its config (provider/model selection,
# inference presets, custom tools) and its audit/session storage.
# All bound ro EXCEPT the session storage, which stado writes
# JSONL traces into during the dispatch.
[[auth_binds]]
host    = "~/.config/stado"
sandbox = "/workspace/.config/stado"
mode    = "ro"

[[auth_binds]]
host    = "~/.local/share/stado"
sandbox = "/workspace/.local/share/stado"
mode    = "rw"
```

Loader changes are tiny: `prompt_mode` already validates against an
allowlist; widen the allowlist to `[stdin, acp]`.

### Dispatcher branch — `Glorbo.CLI.Dispatcher.Acp`

`Glorbo.Agent.Dispatch` currently builds a sandboxed CLI invocation
that pipes the prompt to stdin and waits for the reply file. The
new dispatch branch (selected by `provider.prompt_mode == :acp`)
spawns the same sandboxed binary but drives it as a JSON-RPC peer:

1. Spawn under bwrap exactly like the stdin path — same
   sandbox, same auth_binds, same network policy, same audit
   wiring at the OS layer.
2. Hold the child's stdin / stdout as a `Port` in two-way mode.
3. Send `initialize` JSON-RPC, expect protocolVersion + capabilities
   in the response. Hard-fail if the response shape doesn't match.
4. Send `session/new`, capture `sessionId`.
5. Send `session/prompt` carrying the agent's task content. Stream
   `session/update` notifications coming back; concatenate the
   `agent_message_chunk` text into the reply buffer.
6. On the prompt's response (terminal), write the buffered text
   to the same `$GLORBO_REPLY_PATH` the stdin path uses. Existing
   downstream code (audit log, reply parsing, agent state machine)
   sees no difference — the reply file is the contract.
7. Send `shutdown`, drain the child, close the port.

Errors at any stage map to the existing dispatch-error categories:
ACP transport / framing errors → `:provider_protocol_error`;
session-prompt error responses → `:provider_returned_error` with
the JSON-RPC `error.message` carried through.

The ACP client lives in `lib/glorbo/cli/dispatcher/acp.ex`. It has
no dependency on stado specifically — any conforming ACP server
can be driven the same way (Zed agent servers, future first-party
agents, etc.). Stado is the validation case.

### Sandbox + auth_binds reuse the existing GEP-8 plumbing

The whole point of fitting stado into the provider TOML pattern is
that the bwrap composition logic in `Glorbo.Agent.Dispatch.build_invocation/3`
doesn't need to know about ACP at all. Stado's binary lands at
`/tmp/glorbo-cli-stado-stado` exactly like the claude binary lands
at `/tmp/glorbo-cli-claude-code-claude`. Auth_binds work identically.
Network policy works identically. The only branch is in the
dispatcher's run-loop (stdin-prompt vs ACP), well after the sandbox
is built.

### Why ACP and not MCP

Stado exposes both `stado acp` (driven as an agent) and
`stado mcp-server` (driven as a tool source). They serve different
roles:

  * **ACP** — stado is the agent. Glorbo says "here's a task,"
    stado picks the model + uses its own tools, returns a reply.
  * **MCP** — stado's tools are exposed for an external agent
    (e.g. a sandboxed claude-code) to call. The external agent is
    the brain.

This GEP only covers the ACP case (stado-as-provider). The MCP case
— glorbo agents using claude-code as the brain with stado-mcp-server
as a tool source — is a separate concern that may or may not be
worth the additional scaffolding (sandbox binary binds, per-CLI MCP
config injection). If it ever becomes necessary it gets its own
GEP. The earlier draft of this GEP was that other concern; we
replaced the body because the dogfood ask was for ACP-shape
integration, not MCP injection.

## Phases

| Phase | Deliverable | Status |
|-------|-------------|--------|
| 0 | This GEP (Draft → Accepted) | In progress |
| 1 | `Glorbo.CLI.Dispatcher.Acp` JSON-RPC client; provider loader accepts `prompt_mode = "acp"`; `priv/providers/stado.toml` ships; FileSpec validator accepts `provider: stado` (registry-driven so this is automatic). | Implemented (1a + 1b shipped 2026-05-04: f7eaf6b, 21b994d, 18dcfcc, 80826e5) |
| 2 | Smoke + bench: a `bench-acp` company with a stado-driven agent dispatches end-to-end against a real stado on the host, audit log captures the ACP message exchange. | Implemented — see `docs/research/gep-45-bench-acp.md`. Audit-log capture deferred to Phase 3 (handshake/dispatch path verified end-to-end against pinned stado v0.26.4). |
| 3 | Operational polish: surface stado's own model/budget metrics through glorbo's usage parser, document network-policy interactions, integrate with the model catalog (GEP-32). Audit-log capture of the ACP message exchange (carried over from Phase 2). | Implemented 2026-05-04. (a) Per-frame `cli.acp.<role>.<kind>` audit emission via injected `audit_fun` in `Acp.Client`; dispatcher result carries `acp: %{session_id, chunks, ignored_updates}`. (b) GEP-32 catalog wiring via new `model_list.shape = "static"` — stado advertises 13 model aliases that surface in the LV combobox without an HTTP probe. (c) `stado_acp` usage parser shells out to `stado stats --session <sid> --json` after each dispatch and surfaces tokens / cost / duration / dominant model / per-tool breakdown via the existing `Parsers.usage()` shape. |
| 4 | Cross-provider rollout: ACP variants of the dogfood CLIs (`gemini-cli-acp`, `claude-code-acp`, `codex-acp`) shipped as sibling provider TOMLs. `gemini-cli-acp` rides Gemini's native `gemini --acp` server; `codex-acp` uses the upstream `codex acp-server` subcommand; `claude-code-acp` routes through the `@zed-industries/claude-code-acp` npm wrapper since the `claude` binary itself doesn't speak ACP. All three share the existing dispatcher branch + auth_binds. Usage parsers default to `"none"` — no per-token attribution for these variants until upstream surfaces stats endpoints (see Open Q5 below), so agents must opt in with `allow_untracked_budget: true`. | Implemented 2026-05-05. |

## Decision log

### D1 — Extend GEP-8 vs new sibling registry

**Status:** Decided — extend GEP-8.

ACP providers and stdin-prompt providers share 90% of the TOML
shape (binary, args, auth_binds, version probe, reply contract).
Splitting the registry into `stdin_providers/` and `acp_providers/`
duplicates the loader, the validator, and the test fixtures for no
real benefit. The transport mode is one field; branching on it in
the dispatcher is the right granularity.

### D2 — Reply file contract: keep it for ACP

**Status:** Decided — keep.

Glorbo's downstream code (audit log appending, reply rendering on
the dashboard, the inbox/outbox flow) all reads the reply file.
Switching ACP providers to a different output mechanism would
double the surface for no operational gain. The dispatcher
assembles streamed `session/update` chunks into the reply buffer
and writes once at the end; stado-side audit semantics (its own
git-native session trace) live alongside the file, accessed via
the bound `~/.local/share/stado/`.

### D3 — `--tools` on by default in `args`

**Status:** Decided — yes, with explicit override path.

`stado acp --tools` opens the full audited executor loop. Without
`--tools` stado is prompt-only — the model can't read files, run
shell, fetch the web, etc. Glorbo's bwrap sandbox is the outer
permission boundary, so giving stado its full tool set inside the
sandbox is safe by construction (same posture as
`claude-code --permission-mode bypassPermissions` in the existing
provider TOML — glorbo's Router + ACLMapper are the policy engine,
not the inner CLI).

A future Director who wants prompt-only stado can drop a user
override at `~/.glorbo/providers/stado.toml` with
`args = ["acp"]`. GEP-8 already supports this override pattern.

### D4 — Sandbox state mode for `~/.local/share/stado`

**Status:** Decided — `rw`.

Stado writes its session JSONL trace into `~/.local/share/stado/`
during dispatch. Read-only would prevent the audit log from
landing. Per-dispatch ephemerality is wrong here — the user wants
the trace persisted across glorbo dispatches so they can run
`stado audit verify` and `stado audit show <session>` from the
host afterward. Trade: stado can write more than just session
state (cache, etc.) — but the surface is contained to
`~/.local/share/stado/` and nothing else gets `rw` from this kit.

### D5 — Single ACP session per glorbo dispatch

**Status:** Decided — yes.

GEP-2 / GEP-4: agent dispatch is per-task, fire-and-forget. The
ACP session is `session/new` → `session/prompt` →
`session/shutdown` within a single bwrap-confined process
lifetime. No session reuse across dispatches; if Director wants
long-running stado state, that lives in
`~/.local/share/stado/sessions/` and stado's own
`session resume` path picks it up the next dispatch.

### D6 — Validation target: stado specifically

**Status:** Decided.

Same rationale as the previous draft — first-party tool, dogfood
integration already specified, both sides have skin in the game.
Once Phase 1 ships, any conforming ACP server (a Zed agent server,
a future first-party glorbo agent runtime) can be added as a
`prompt_mode = "acp"` provider for free.

## Open questions

1. **Stado's stderr stream during ACP.** Stado prints
   `stado acp: ready (...)` and other status lines to stderr when
   it starts. The ACP client should drain stderr concurrently with
   stdin/stdout to prevent backpressure-induced hangs, and route
   the lines into the agent's stdout-tail stream so the dashboard
   can show what stado is doing in real time. Phase 1 prototype
   needs to confirm this works under the bwrap sandbox where stado
   may also be writing diagnostics to its own audit dir.

2. **Cancellation propagation.** Glorbo's existing dispatch
   timeout (per-agent `timeout_seconds`) currently kills the bwrap
   tree. ACP also has `session/cancel`. Soft cancel (ACP) lets
   stado flush its trace before exiting; hard kill doesn't. Phase
   1 should send `session/cancel` first, give stado a short window
   (~2s), then SIGTERM the tree. Confirm stado's behavior under
   `session/cancel`.

3. **Network policy interactions.** Stado fetches models and
   webfetch results over HTTPS. `network: loopback` isn't enough;
   `network: proxy` requires stado to honor `HTTPS_PROXY` (it
   does — uses the standard Go HTTP client). `network: full`
   bypasses the proxy. The provider TOML doesn't currently
   constrain network policy; should `prompt_mode = "acp"` providers
   require `network: proxy` or `full`? Decision deferred until the
   smoke test surfaces real failure modes.

4. **Usage parser.** Stado prints token / cost numbers to stderr
   on session end. Glorbo's existing `usage_parser` field assumes
   per-CLI JSONL paths (claude-code uses `claude_jsonl`). Stado's
   per-session JSONL trace is structured but not in the same
   shape. Phase 3 adds a `stado_acp` usage parser kind; until
   then, Phase 1 logs stado's session ID and the operator
   correlates manually via `stado stats`.

5. **Per-token attribution for the cross-provider ACP variants.**
   Phase 4 ships `gemini-cli-acp`, `claude-code-acp`, and
   `codex-acp` with `usage_parser = "none"`. Gemini's ACP server
   doesn't surface token totals through `session/update`, the
   Zed Claude wrapper doesn't either, and none of the three exposes a
   stado-style stats subcommand the dispatcher could shell out to.
   Until upstream adds an out-of-band stats endpoint (or surfaces
   totals through a session-end ACP notification), the budget
   ledger records these dispatches with `usage: nil`. Operators
   must set `allow_untracked_budget: true` on agents that use these
   providers. Operators who need attribution today should stay on the
   stdin variants (`claude-code`, `codex`, `gemini-cli`) which retain
   their existing parsers.

## Bidirectional links

- **GEP-8** — provider registry pattern this GEP extends with
  `prompt_mode = "acp"`.
- **GEP-9** — protocol-integration direction record. ACP is the
  first concrete protocol-level integration glorbo ships outbound;
  GEP-29 already shipped Glorbo as MCP server (inbound).
- **GEP-23** — sandbox network policy + per-agent allowlist
  extensions. Open question 3 above will interact heavily with
  GEP-23 once Phase 1 surfaces real network requirements.
