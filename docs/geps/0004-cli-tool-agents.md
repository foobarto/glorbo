---
gep: 4
title: CLI-Tool Agents over a Custom LLM Client
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Informational
created: 2026-04-17
implemented-in: v0.0.1
requires: [2]
see-also: [5, 8]
extended-by: [32]
history:
  - date: 2026-04-17
    status: Draft
    note: Initial retrofit from DESIGN.md §4.2–4.3.
  - date: 2026-04-17
    status: Accepted
    note: Canonical record of the CLI-wrapping approach shipped in v0.0.1.
  - date: 2026-04-17
    status: Implemented
    version: v0.0.1
    note: Three adapters (claude-code, gemini-cli, codex) shipped in v0.0.1. Retrofitted status.
---

# GEP-4: CLI-Tool Agents over a Custom LLM Client

## Purpose

Glorbo does not ship its own LLM client. Every agent is bound to a
terminal CLI tool (`claude-code`, `gemini-cli`, `codex`, and
eventually OSS alternatives like `hermes`, `opencode`, `pi`) and
Glorbo runs that CLI as a sandboxed subprocess. This GEP records the
reasoning behind that inversion, the properties it gives Glorbo, and
the costs it imposes.

This is an Informational GEP documenting a v0.0.1 design decision
that still holds. The complementary GEP-8 (Provider Registry) builds
on this by decomposing each CLI's invocation into config + a named
parser, collapsing the three hand-written adapter modules into a
data-driven registry.

## Context: what Glorbo wraps

Each supported provider maps to a published CLI tool maintained by
someone else. v0.0.1 covered three:

| provider        | Binary   | Auth                                    |
|-----------------|----------|------------------------------------------|
| `claude-code`   | `claude` | Claude Code's own login (`~/.claude/`)   |
| `gemini-cli`    | `gemini` | `GEMINI_API_KEY` or `gcloud` ADC         |
| `codex`         | `codex`  | Codex CLI's own auth (`~/.codex/`)       |

Per agent, `agent.md` declares exactly one provider + one model. No
multi-model routing within an agent. Different agents in the same
company can use different providers freely.

Each CLI invocation receives a prompt on stdin, executes its own
internal tool-use loop (reading files, editing code, making HTTP
calls — all filtered through the sandbox), and returns output. Glorbo
never makes its own LLM API calls, never hands agents API keys, and
never implements provider-specific retry or streaming logic.

## Why wrap CLIs instead of writing an SDK client

### 1. Every CLI already solves the hard problems

Each provider's CLI handles:

- **Auth and credentials.** OAuth dances, API key rotation, cloud
  identity federation. A year of engineering per provider that Glorbo
  would otherwise own.
- **Model selection and routing.** Model names, regions, latency
  hints, deprecation migrations.
- **Token streaming, cancellation, retries, backoff.** The provider's
  CLI knows its own rate limits and retry etiquette better than a
  third-party wrapper could.
- **Tool-use / function-calling loops.** Modern LLM CLIs implement
  multi-turn tool invocation with their providers' native schemas
  (Claude's tool_use, OpenAI's function_call, Gemini's function
  declarations) — each subtly different.
- **Session persistence.** Resume mid-task, replay transcripts, hand
  off to humans mid-flight.

Rebuilding any of this produces a worse version than the CLI already
provides, and the CLI improves on its own cadence.

### 2. Reduced surface area for Glorbo to maintain

No HTTP client. No provider-specific retry logic. No streaming token
handling on Glorbo's side. Glorbo's job becomes: write a prompt file,
invoke a binary, read the output, record what happened. That scope
fits in a few modules; an SDK-based client would be a subsystem.

### 3. Auth isolation without API key handling

Because the CLI owns auth, Glorbo never touches API keys. A compromised
Glorbo process can't leak Claude credentials to a Gemini agent because
it doesn't hold them. `~/.claude/` is bind-mounted read-only into a
Claude-provider sandbox; `~/.gemini/` is bind-mounted read-only only
into Gemini-provider sandboxes; Glorbo itself sees only file
descriptors, never the secret contents.

This composes with GEP-5's kernel-level permissions: the auth
directory is a mount, not a value in Glorbo's memory. An agent that
lacks the right mount literally can't see the credentials.

### 4. Provider neutrality by construction

Supporting a new provider is a new CLI binary + a small amount of
config (and, with GEP-8, a named parser for telemetry if we want
budget tracking). Contrast an SDK-first design where each provider
needs a full HTTP client adapter, error-code mapping, streaming
shape, etc.

This is why adding hermes, opencode, pi, or whatever LLM CLI ships
next year is cheap in Glorbo — the integration surface is a
subprocess, not an API surface.

### 5. Human-parallel story

Agents use the same CLI tools the human Director uses. If the Director
debugs a prompt by running `claude --print 'explain this'` in their
own terminal, the output shape matches what the agent would have seen.
Removes a class of "works for me, not for the agent" bugs.

## Costs and accepted tradeoffs

### 1. Telemetry is heterogeneous

Each CLI emits token usage in a different place and format:
- Claude Code writes JSONL to a session directory.
- Gemini CLI emits a single JSON blob on stdout.
- Codex streams event lines with cumulative counters.

Glorbo needs a per-CLI parser for budget tracking. GEP-8 formalises
this as named parser modules. Cost: real but bounded — one parser per
distinct output format, and some providers may ship with
`usage_parser = "none"` if we don't need their telemetry.

### 2. Stdout is noisy

CLIs print session banners, warnings, tool-use logs, and other chrome
on stdout. Getting the agent's actual reply back cleanly required
designing the reply-file contract (GEP-8 §7.4, D1) where the agent
writes its reply to `$GLORBO_REPLY_PATH` and Glorbo ignores stdout.

### 3. Invocation asymmetry

Each CLI has its own flags, prompt delivery mode (stdin vs stdin-dash
vs argv vs file-arg), and env-var conventions for session directory
override. GEP-8 captures these as templated TOML fields.

### 4. No real-time streaming control

Glorbo tails stdout for the dashboard but can't inject mid-stream
feedback ("stop, retry with X") — the CLI owns the turn. For v0.0.1
this is fine; real-time co-piloting is a non-goal (GEP-2 non-goal:
"agents are autonomous until they complete or fail").

### 5. Dependence on upstream CLI stability

Each CLI changes its flags and telemetry format on its own cadence.
Glorbo has to version-pin or feature-detect. Mitigation: GEP-8's
version-probe field gives Glorbo the CLI's version string at detect
time, so parsers can branch on version when upstream breaks.

## Per-agent isolation within a shared CLI install

The Director has one login per provider on the host
(`~/.claude/`, `~/.gemini/`, `~/.codex/`). But agents must not pollute
the Director's session history or cross-contaminate each other.
Solution: per-invocation env-var redirection.

Example for `claude-code`:
- `CLAUDE_CONFIG_DIR=<agent-workspace>/.glorbo-claude` tells Claude
  Code to write session state *inside* the agent's workspace, not
  `~/.claude/projects/`.
- The auth dir (`~/.claude/credentials.json`) is still bind-mounted
  read-only from the host into the sandbox.
- Session JSONL ends up in the agent's workspace, visible only to
  that agent, not to the Director's next `claude` invocation.

Every supported CLI has a similar session-redirect env var (or will
gain one as providers catch up). This pattern composes cleanly with
GEP-8's TOML `[env]` block.

## Auth model summary

```
Host                          Sandbox                           Agent's view
---------                     ---------                         ----------------
~/.claude/credentials.json →  /home/agent/.claude/...           ro (bind-mount)
(Glorbo process sees FD,      (visible only to this agent)      (used by `claude` CLI)
 not contents)
                               CLAUDE_CONFIG_DIR=
                               /workspace/.glorbo-claude        rw (session writes)
                               (created fresh per invocation,
                                deleted or rotated per policy)
```

Glorbo mediates zero of the auth traffic. The CLI binary talks to the
provider directly from inside the sandbox.

## v0.0.2+ evolution: direct-SDK providers inside the container

The original v0.0.2 plan adds a second dispatch mode: direct SDK
calls via `litellm` inside the `glorbo-runtime` Podman container.
This is *complementary* to CLI-wrapping, not a replacement.

Use cases:
- Local models via `ollama` or `huggingface` where there's no CLI
  worth wrapping.
- Cost-optimised routing via litellm's built-in provider fallback
  graphs.
- Agents whose workflow needs programmatic control that CLI tools
  don't expose.

When this ships, the `agent.md` provider field accepts either a
CLI-tool name (`claude-code`, `gemini-cli`, etc.) or a direct-SDK
name (`anthropic`, `openai`, `google`, `ollama`, `huggingface`). The
dispatch path differs — CLI tools go through `bwrap` + the CLI
binary; direct-SDK goes through the container + litellm — but the
agent.md contract is uniform.

As of v0.0.2, the container runtime is deferred to v0.0.3 (GEP-2
D8). This GEP therefore covers only the CLI-tool path.

## Relationship to other GEPs

- **GEP-5** (Sandboxing): provides the kernel-level isolation every
  CLI invocation runs inside. Auth bind-mounts rely on it.
- **GEP-8** (Provider Registry): refactors the hand-written adapter
  modules into config + named parsers. Depends on this GEP's model
  that "providers are CLI subprocesses."
- **GEP-3** (Filesystem as source of truth): session directories and
  workspaces are ordinary filesystem state, reindexable per the
  authoritative-files invariant.

## Decision log

### D1. Wrap CLI tools, don't build an SDK client

- **Decided:** every v0.0.1 agent provider is a CLI subprocess.
  Glorbo never calls Anthropic/OpenAI/Google APIs directly.
- **Alternatives:** write per-provider HTTP clients; use `litellm` as
  a unified SDK; mix CLI-wrapping and direct SDK per provider.
- **Why:** CLIs already solve auth, model selection, retry, tool-use,
  and streaming. Reinventing them is wasted work and the wheel keeps
  spinning upstream. The CLI-wrapping approach also composes with
  kernel sandboxing (GEP-5) in a way SDK calls wouldn't — you can't
  `bwrap` a function call. Cost: heterogeneous telemetry (addressed
  in GEP-8).

### D2. One provider + one model per agent

- **Decided:** `agent.md` declares exactly one provider and one
  model. No multi-model routing within an agent.
- **Alternatives:** per-task model selection; provider pools with
  fallback graphs; automatic cost-based routing.
- **Why:** the agent's model is part of its identity — changing it
  changes behaviour. Multi-model within an agent makes budget
  tracking, audit trails, and debugging ambiguous ("which model
  produced this output?"). If an operator wants model diversity, they
  create multiple agents. Simpler contract, clearer audit, cleaner
  failure modes.

### D3. CLI owns auth, Glorbo never sees API keys in v0.0.1

- **Decided:** credentials stay in the user's home directory. Glorbo
  bind-mounts them read-only into the sandbox for providers that
  need them.
- **Alternatives:** Glorbo manages API keys in `~/.glorbo/config.md`
  and injects them as env vars; write keys to the company directory.
- **Why:** a Glorbo process that doesn't hold secrets can't leak
  them. The company directory is git-trackable and backup-friendly;
  putting keys there would make every backup a credential leak.
  Kernel-mediated access (bind-mount) composes with GEP-5 so the auth
  dir's presence is itself an enforced permission.
  (v0.0.2 adds direct-SDK providers where Glorbo does handle keys —
  but via env-var injection at container start, never written to
  disk.)

### D4. Per-invocation session redirect, not per-CLI config rewriting

- **Decided:** use each CLI's documented "config dir override" env
  var (e.g. `CLAUDE_CONFIG_DIR`, `CODEX_HOME`) to point session
  writes into the agent's workspace.
- **Alternatives:** symlink the CLI's config dir to the workspace
  before invocation; write our own session JSONL format.
- **Why:** env-var override is the upstream-supported mechanism.
  Symlinks race on concurrent agents; rewriting session format
  requires tracking each CLI's schema changes.

### D5. Provider neutrality over feature completeness per provider

- **Decided:** Glorbo supports the lowest common denominator of
  provider features (prompt-in / text-out / telemetry). Per-provider
  bells and whistles aren't first-class in `agent.md`.
- **Alternatives:** expose each provider's special features
  (Claude's extended thinking, Gemini's grounding, etc.) as
  per-provider `agent.md` fields.
- **Why:** fragmenting the agent contract by provider pushes
  complexity to every feature downstream (audit, budget tracking,
  dashboard rendering). If a provider-specific feature is important
  enough, add it as a generic concept that maps onto each provider's
  equivalent — not as a provider-specific override.

### D6. Accept heterogeneous telemetry as the price of wrapping

- **Decided:** per-CLI usage-parser modules handle token counting.
- **Alternatives:** require providers to emit a uniform telemetry
  schema (impossible — we don't control them); skip telemetry
  entirely (breaks budget tracking); use an intermediate proxy that
  normalises output (adds a moving part).
- **Why:** the cost is bounded (one parser per distinct format) and
  formalised in GEP-8. Skipping telemetry would violate GEP-2's
  "budget tracking is core" premise.

## Related

- **GEP-2** — architectural overview (see "Agents are wrapped CLIs,
  not SDK clients" pillar).
- **GEP-5** — sandboxing (provides the bwrap/container layer every
  invocation runs inside).
- **GEP-8** — provider registry + auto-detect (data-driven refactor
  of the hand-written adapter pattern).
- `DESIGN.md` §4.2 (CLI Agents — The Hands), §4.3 (LLM Providers).

## Implementation reconciliation (2026-06-14)

This is an append-only record. Per GEP-1, an Accepted/Implemented GEP's body is not rewritten in place; the sections above stand as the historical v0.0.1 record, and deviations discovered since are recorded here.

- **§"v0.0.2+ evolution: direct-SDK providers inside the container" (lines 204–226) — as-shipped (body stale).** The GEP says direct-SDK providers will run via `litellm` inside a `glorbo-runtime` Podman container, deferred to v0.0.3. That container/litellm path was killed (GEP-5 D6: no Python anywhere, no container runtime). The direct-SDK feature instead shipped as the in-process `glorbo harness` (GEP-32): `lib/glorbo/cli/harness.ex` reads the prompt on stdin, POSTs to the provider's `/v1/chat/completions` (`chat_completion/3` at harness.ex:289–301, `chat_url/1` at harness.ex:488–492), and runs inside the same `bwrap` sandbox as CLI tools — not a container, not litellm. The narrative is doc drift; the underlying "second dispatch mode for non-CLI providers" intent did ship, just by a different mechanism.

- **§"Context: what Glorbo wraps" (lines 60–61) and §"Auth model summary" (line 201) — as-shipped (claims now over-broad).** The GEP asserts as design absolutes that "Glorbo never makes its own LLM API calls, never hands agents API keys… never implements provider-specific retry or streaming" and "Glorbo mediates zero of the auth traffic." Those hold for the CLI-tool path but are false for the shipped `native` providers. `glorbo harness` makes the API call itself, building `Authorization` headers (`auth_headers/1`) and POSTing to endpoints like `https://api.openai.com/v1` (`priv/providers/openai.toml`), `https://openrouter.ai/api/v1`, `https://api.minimax.io/v1` — all `kind = "native"`, `auth = "bearer"` — and implements its own retry/backoff (`HTTP.request_with_retries`, harness.ex:303–327). These claims should be read as scoped to the CLI-tool path; the native-harness path is a deliberate post-v0.0.1 addition (GEP-32) where Glorbo does hold the key and drive the request.

- **No body cross-reference to GEP-0055 (`via_proxy` / in-process inference proxy) — as-shipped (frontmatter + see-also gap).** GEP-0004's premise that "Glorbo mediates zero auth traffic" is further inverted by the shipped `auth = via_proxy` mode (GEP-0055, `lib/glorbo/openai_proxy.ex`). For a `via_proxy` provider, Glorbo mints a per-dispatch proxy token (`resolve_openai_proxy_token/5`, dispatch.ex:833–853), injects `*_BASE_URL` env into the sandboxed CLI/native client (dispatch.ex:973–1041), and the in-process proxy attaches the real upstream key read from `api_key_env` at request time (`loader.ex:442–484`, `provider.ex:74–80`). GEP-0004's `see-also` ([5, 8]) and `extended-by` ([32]) omit 0055 entirely, and the auth-model section has no pointer to it — a reader of the canonical CLI-wrapping GEP is left unaware that Glorbo now brokers credentials for some providers. Recorded here as the canonical pointer until/unless the frontmatter is amended in a future editorial pass.
