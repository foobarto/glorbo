---
gep: 32
title: Native Agent Harness — OpenAI v1-Compatible Provider
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-23
requires: [4, 5, 8]
see-also: [3, 6, 7, 17, 23, 31, 55]
extended-by: [67]
history:
  - date: 2026-04-23
    status: Draft
    note: Initial draft from multi-turn brainstorm + gep-research grounding (GEPs 2, 3, 7, 8, 23, 31).
  - date: 2026-04-23
    status: Accepted
    note: Accepted by Director on the same day as draft. 28 decision-log entries locked via prior brainstorm; no revisions requested.
  - date: 2026-04-23
    status: Accepted
    note: "Phase 1 landed in v0.1.0: native registry kind, `glorbo harness`, built-in `openai` + `openrouter`, runtime untracked gate, and `read_file` tool loop. Phases 2–4 remain open."
  - date: 2026-04-23
    status: Accepted
    note: "Phase 2a landed in v0.2.0: `write_file`, `edit_file`, `glob`, and `grep` join the native tool loop, and sanitized per-tool audit events replay through `Agent.Dispatch`. `bash`, `web_fetch`, and later phases remain open."
  - date: 2026-04-23
    status: Accepted
    note: "Phase 2b landed on `main`: `bash` and `web_fetch` now ship in the native tool loop, `http_timeout_s` / `http_max_retries` / `web_fetch_timeout_s` / `max_tool_calls_per_turn` are threaded from `agent.md`, and provider/tool HTTP retries now honor transient-failure policy."
  - date: 2026-04-23
    status: Accepted
    note: "Phase 3 host-side ModelCatalog GenServer landed: per-provider `/v1/models` + Ollama `/api/tags` probes on explicit refresh, `~/.glorbo/cache/providers/*.json` cache, derived `provider_models` SQLite projection, reindex rebuild without network calls, `AgentBoot` soft-warn on unknown model, ProvidersLive model-count + catalog-status chip, and shared `Glorbo.Providers.NativeConfig` helpers extracted from Harness. Phase 4 (`glorbo detect-providers`, agent-wizard model combobox) remains open."
  - date: 2026-04-23
    status: Accepted
    note: "Phase 4 partial: `glorbo detect-providers` CLI verb + ProvidersLive `scan localhost` button ship localhost auto-detection across ollama/llama.cpp/LocalAI/vLLM/LM Studio with shape + Server-header + body fingerprints. AgentLive config editor now renders a `model` datalist populated from the `provider_models` cache for the currently-selected provider. Auto-activation (append-to-`providers.toml` on Enable) and the KanbanLive new-task quick-add combobox are still open, but Director-driven discovery + manual enablement is now end-to-end."
  - date: 2026-04-23
    status: Implemented
    note: "Phase 4 Enable flow landed: `Glorbo.Providers.Enable.enable/2` appends a matching `[[providers]]` block to `~/.glorbo/providers.toml` (kind=native, auth=none, usage_parser=native-v1, correct model_list shape per alias) when the Director clicks `+ enable` on a `:ready` scan row. Action is idempotent — a second enable is a no-op. With that the four planned phases (registry schema + harness, full tool catalog, model catalog, auto-detect + Providers UX) are complete. KanbanLive quick-add model combobox remains as a polish follow-up tracked in `docs/todo.md`."
  - date: 2026-04-23
    status: Implemented
    note: "Release-surface catch-up: `mix glorbo.release_formula` now handles the Linux-only shipped state (previously hard-required darwin SHAs, which blocked tap refreshes after the 2026-04-22 macOS-runner freeze), and a new `publish-homebrew-tap` job auto-pushes `foobarto/homebrew-tap` after every signed release, closing the Linux tag → tap loop end-to-end. Attempt to re-enable `build-macos` on the same day was reverted after the first run (24852774115) queued indefinitely with no job ever scheduled — macOS matrix gated off again until GHA capacity returns."
  - date: 2026-04-23
    status: Implemented
    note: "macOS builds resurrected via Burrito's Zig cross-compile path from Linux. New `build-macos-cross` ubuntu-24.04 matrix produces both Mach-O arches (universal ERTS from BEAM machine CDN, `zig cc -target <arch>-macos` for the `exqlite` NIF, Zig launcher wrap, `file` smoke check per arch). Host-macOS `build-macos` job retired. Darwin SHAs + signatures back in the release bundle; tap auto-publish pulls them into the formula on the next tag push."
  - date: 2026-06-15
    status: Implemented
    note: "Security hardening (codex L3): `Glorbo.Providers.Enable.append_entry/2` now chmods the config parent to `0700` and `providers.toml` to `0600` on every enable append, matching GEP-32 D9 / credentials-file permissions. `config_migration.harden/1` only chmods existing subdirs — it did not cover a fresh `providers.toml` create under a permissive umask."
---

# GEP-32: Native Agent Harness — OpenAI v1-Compatible Provider

## Problem

Glorbo's agent runtime today (GEP-4) dispatches work by wrapping three
external CLI binaries — claude-code, gemini-cli, codex — inside bwrap
(GEP-5). Every provider the Director wants to use must ship its own
CLI, be discoverable on `$PATH`, and speak our reply-file contract
(GEP-8). That design is a deliberate choice — it lets us inherit
well-tested agent harnesses, tool implementations, and prompt-caching
logic for free — but it has two sharp edges:

1. **Provider coverage is bounded by "does this company ship a CLI?"**
   The major-frontier triad (Anthropic / Google / OpenAI) is covered.
   Everything else — OpenRouter, Groq, Together, local inference
   (Ollama / llama.cpp / LM Studio / vLLM / TGI), enterprise gateways
   (Databricks, Azure OpenAI, Vercel AI Gateway) — has no first-party
   CLI and therefore no Glorbo integration.
2. **Installation friction is high for pre-v1 Directors.** Standing up
   a new Glorbo tenant today means installing Node / npm for
   claude-code, pip for codex, the Google CLI for gemini — each with
   its own auth ritual. For a Director whose actual job is
   dispatching tasks to a small Ollama server on the same host, that
   ceremony is the entire project.

We already have the hard parts: kernel-layer isolation (GEP-5),
filesystem-as-source-of-truth (GEP-3), the provider registry (GEP-8),
the audit log, the budget ledger. What's missing is a first-party
harness that speaks the universal OpenAI `/v1/chat/completions`
wire format and runs inside the same bwrap tree every CLI agent
already uses.

## Goals

- Add **one new provider kind** — `kind = "native"` — to the GEP-8
  Registry schema, sitting alongside `kind = "cli"`.
- Ship a **`glorbo harness` subcommand** of the existing single binary
  that runs under bwrap and speaks OpenAI v1 REST to any of ~33 cloud
  or local endpoints.
- Preserve every load-bearing invariant: GEP-2 pillars, GEP-5 two-layer
  enforcement, GEP-7 "every SQLite row rebuildable from disk", GEP-8's
  `Registry.Loader` hard-fail config/code split.
- Cover the common local-inference servers (Ollama, LM Studio,
  llama.cpp, LocalAI, vLLM, TGI, Jan, text-generation-webui, koboldcpp,
  MLX-Omni) so a Director with a local endpoint can stand up Glorbo
  without installing any CLI.
- Provide **first-party model discovery** so Director UX isn't a
  free-text model name box. Cache on disk; SQLite is a projection.
- Provide **first-party local-provider auto-detection** so Directors
  see "you have Ollama running on :11434, click to enable" without
  typing URLs.

## Non-goals

- **No native-shape providers in v1.** Anthropic's extended-thinking
  flag, Gemini grounding, and similar provider-specific features stay
  behind the OpenAI-compat façade for v1. A v2 GEP can add richer
  shapes if demand shows up.
- **No in-harness MCP client in v1.** GEP-29 covers Glorbo-as-MCP-server;
  the reverse direction (harness as MCP client consuming external tool
  servers) is a distinct surface and goes in a follow-up GEP.
- **No prompt caching across invocations in v1.** Each harness
  invocation is a fresh HTTP session. Adding cross-invocation caching
  couples the harness to the scheduler and is a v2 concern.
- **No cost/pricing normalisation in v1.** The budget ledger already
  tracks token counts; translating counts to per-provider dollar
  pricing is a separate GEP.
- **No cross-OS port.** Linux-only, same as every other GEP. GEP-17
  captures the macOS / Windows research for when that time comes.
- **No `glorbo backup` verb in v1.** Directors who use naïve
  `tar cf backup ~/.glorbo` today get secret-free backups automatically
  because credentials live outside the tree (D5). A verb that
  opinionates backup is separate work.

## Design

### Positioning

A native harness that runs as an SDK client inside the Elixir host
process would invert GEP-5's two-layer enforcement: the HTTP
connection, the tool-call dispatcher, and every byte of untrusted LLM
output would live in-process in the BEAM. Any exploit against the
harness (a malformed tool-call payload, a UTF-8 bug, a future library
CVE) would land on the dashboard's own privileges.

Instead, the native harness is structured as a **first-party wrapped
CLI**. It is a subcommand of the same Glorbo binary the Director
installed — no separate artifact, no Burrito rebuild, no PATH
installation — but it runs inside the identical bwrap tree that
claude-code, gemini-cli, and codex already run under. From the
Router's perspective, a native agent looks structurally identical to
a CLI agent: same dispatch pipeline, same reply-file contract, same
`/run/usage.json` schema, same sandbox mounts.

This extends GEP-2 pillar 5 ("wrap existing CLIs") rather than
softening it. The wrapped CLI happens to be first-party; nothing else
changes.

### Dispatch

The Registry's dispatch layer (`Glorbo.Dispatch` per GEP-8 §5) learns
one new case for `kind = "native"`:

- Invocation shape: `glorbo harness --provider <alias> --agent <slug>
  --task <id>` (exact flags to be fixed during implementation — the
  surface is fully Glorbo-owned).
- Bind mount: `--ro-bind $(System.find_executable "glorbo")
  /usr/bin/glorbo-harness`. The sandboxed command line invokes
  `/usr/bin/glorbo-harness ...`.
- Everything else — `--unshare-net` behaviour, workspace mounts,
  per-permission project binds, `--cap-drop ALL` — is inherited
  from the CLI-agent dispatch path verbatim.

The **reply-file contract is unchanged**: the harness writes its
final assistant message to `$GLORBO_REPLY_PATH`, same as every CLI
adapter. The Router's existing reply-watcher path stays intact.

The **usage file contract** is Glorbo-owned:

```json
{
  "tracked": true,
  "prompt_tokens": 1247,
  "completion_tokens": 318,
  "model": "llama3.1:70b",
  "duration_ms": 4123
}
```

- `tracked: true` — the provider returned a `usage` block in the
  response body; token counts are real.
- `tracked: false` — the provider didn't return `usage` (common for
  Ollama, llama.cpp). Counts are zero; GEP-8 D15's
  `allow_untracked_budget` per-agent gate decides whether the dispatch
  is allowed.

### Provider Registry extensions

Three new fields on the GEP-8 TOML schema:

```toml
# priv/providers/openai.toml
alias = "openai"
kind  = "native"                  # NEW: "cli" (default) | "native"
endpoint = "https://api.openai.com/v1"
auth  = "bearer"                  # NEW: "none" | "bearer" | "api-key"
usage_parser = "native-v1"        # named parser, not "none"

[model_list]                      # NEW
path  = "/v1/models"
shape = "openai"                  # "openai" | "ollama" | "none"
```

Validation additions to `Registry.Loader`'s hard-fail list (extends
GEP-8 D9):

- `kind` is present and one of `"cli" | "native"`. Absent means
  `"cli"` (back-compat for existing `priv/providers/*.toml` entries).
- `auth` is present for `kind = "native"` entries and is one of
  `"none" | "bearer" | "api-key"`.
- `model_list.shape` is one of `"openai" | "ollama" | "none"` when
  present; absent is equivalent to `shape = "none"`.
- Native entries without a valid `usage_parser` fail to load.

### Seed provider list (v1)

**Cloud (23 entries).** All `auth = "bearer"` except `azure-openai`
(`api-key`):

```
openai                https://api.openai.com/v1
azure-openai          https://{resource}.openai.azure.com/...
openrouter            https://openrouter.ai/api/v1
groq                  https://api.groq.com/openai/v1
together              https://api.together.xyz/v1
fireworks             https://api.fireworks.ai/inference/v1
deepseek              https://api.deepseek.com/v1
mistral               https://api.mistral.ai/v1
perplexity            https://api.perplexity.ai
xai                   https://api.x.ai/v1
cerebras              https://api.cerebras.ai/v1
sambanova             https://api.sambanova.ai/v1
deepinfra             https://api.deepinfra.com/v1/openai
novita                https://api.novita.ai/v3/openai
hyperbolic            https://api.hyperbolic.xyz/v1
moonshot              https://api.moonshot.cn/v1
nvidia-nim            https://integrate.api.nvidia.com/v1
github-models         https://models.inference.ai.azure.com
cloudflare-workers-ai https://api.cloudflare.com/.../ai/v1
databricks            https://{workspace}.cloud.databricks.com/serving-endpoints
vercel-ai-gateway     https://gateway.ai.vercel.app/v1
anthropic-compat      https://api.anthropic.com/v1/
gemini-compat         https://generativelanguage.googleapis.com/v1beta/openai/
```

**Local (10 entries).** Default `auth = "none"` and all endpoints
on `127.0.0.1`. Fingerprints disambiguate shared ports:

```
ollama         :11434  /v1  (also /api/tags)
lmstudio       :1234   /v1  (Server: LM Studio)
llamacpp       :8080   /v1  (shared w/ localai)
localai        :8080   /v1  (/readyz present)
vllm           :8000   /v1  (Server: uvicorn)
tgi            :8080   /v1  (HF text-generation-inference)
jan            :1337   /v1
textgen-webui  :5000   /v1  (oobabooga)
koboldcpp      :5001   /v1
mlx-omni       :10240  /v1  (Apple Silicon)
```

### Credentials

**Location.** `~/.local/etc/glorbo/credentials/<provider>.toml`.
Mirrors the system `/etc/` convention scoped to the user's home; lives
**outside** `~/.glorbo/` on purpose — so a naïve
`tar cf backup.tgz ~/.glorbo/` doesn't sweep secrets into the
backup. Glorbo never writes through this path; the Director creates it
by hand or via the ProvidersLive "Configure credentials" action.

**Override.** `GLORBO_CREDENTIALS_DIR` env var takes precedence over
the default, mirroring the existing `CLAUDE_CONFIG_DIR` pattern
agents already use. Supports CI runners and secrets-manager
deployments that inject creds under `/run/secrets/...`.

**Permissions.**

- Credentials file: `chmod 600`.
- Parent directory: `chmod 700`.
- `glorbo doctor` emits a warning (not an error) when it finds a file
  world-readable or a directory group-readable.

**Format.**

```toml
api_key  = "sk-..."             # optional; omit for auth = "none"
endpoint = "https://..."        # optional; overrides Registry default

[extras]
organization = "org-..."
project      = "proj-..."
deployments  = ["gpt-4-prod", "gpt-4-staging"]  # Azure: manual model list
```

`[extras]` is a free-form string table. Keys known to specific
providers (Azure's `deployments`, OpenAI's `organization`, etc.) are
read by the harness at invocation time; unknown keys are ignored.

**Per-dispatch bind.** For agent `alice` with `provider: openai`, the
sandbox receives:

```
--ro-bind ~/.local/etc/glorbo/credentials/openai.toml /creds/provider.toml
```

**Only** the selected provider's file enters the sandbox. Agents with
different providers never see each other's keys; an agent has no way
to read a peer's credentials through the filesystem.

**Global per-provider, not per-alias.** One file per provider globally
(single-Director model). Per-alias multiplication bought nothing at
our tier and added indirection.

### Tool catalog (v1)

Seven tools, all implemented inside the harness:

| Tool | Purpose | Sandbox gating |
|---|---|---|
| `read_file` | Read a file from the workspace | bwrap mount view |
| `write_file` | Create / overwrite a file | bwrap mount view |
| `edit_file` | Targeted line-anchored edit | bwrap mount view |
| `glob` | Pattern-match filenames | bwrap mount view |
| `grep` | Pattern-match file contents | bwrap mount view |
| `bash` | Shell command | bwrap view + network policy |
| `web_fetch` | HTTP GET an external URL | network policy + GEP-23 filter |

No in-process allowlist on filesystem tools — the sandbox mount view
is the authority. An agent with `permissions: [projects:write:acme]`
literally cannot `write_file` to another project; the paths aren't
mounted. This is GEP-5 two-layer enforcement applied to tool calls.

`web_fetch` always emits an `egress.web_fetch` audit event with the
target host and the agent slug, regardless of network mode. When
GEP-23's proxy lands, `web_fetch` additionally routes through
`Glorbo.Egress.Filter.classify/4`; the audit layer works without the
proxy, so v1 has real auditing of agent web access even before
GEP-23 ships.

`bash` is a documented network-policy bypass of `web_fetch`'s filter
layer: an LLM that emits `curl https://attacker/` inherits the sandbox
network rules (which are real — GEP-31's netns, once shipped, blocks
it outright on `network: proxy`), but it does not flow through
`web_fetch`'s per-host classifier. This matches existing CLI-agent
semantics exactly — claude-code, codex, and gemini-cli all let their
own shell tools do the same.

### Network policy

| `network:` value | Native meaning |
|---|---|
| `none` | **Invalid.** Rejected at `Agent.Parser` parse time with a config error. A native agent with no network cannot reach its endpoint. Structurally impossible; we fail fast rather than at dispatch time. |
| `proxy` | Declarable in v1; `HTTPS_PROXY` / `HTTP_PROXY` env vars are plumbed into the harness, and on Linux the outer launcher now wraps the sandbox in GEP-31's `pasta` netns so only the proxy port is reachable. On macOS it remains part of the documented unsandboxed degraded mode. |
| `open` | Supported. `bash` tool can reach any host the sandbox permits. `web_fetch` is filter-aware and always audits. |

No stub proxy module is required for v1 — `:httpc` honours
`HTTPS_PROXY` natively.

### Retries and timeouts

**Retry classification.**

| Condition | Retry? |
|---|---|
| Network error (`:econnrefused`, `:nxdomain`, TLS failure) | yes |
| Connect / read timeout | yes |
| HTTP 5xx | yes |
| HTTP 429 (rate limit) | yes; honour `Retry-After` header |
| HTTP 4xx other than 429 | **no** (auth, bad-request, context-too-long) |

Retrying 4xx wastes budget and spams providers; 401/403 and 400
context-too-long are not going to fix themselves.

**Backoff.** Exponential with jitter. Default `http_max_retries: 3`.

**Timeouts.** Every HTTP request has a timeout. Unbounded blocking is
the harness-liveness footgun.

| Setting | Default |
|---|---|
| `http_timeout_s` | 120 |
| `web_fetch_timeout_s` | 30 |
| `http_max_retries` | 3 |

**Two retry layers, not conflated.**
`Glorbo.Agent.Dispatch.attempt_with_retries/4` (process-level retries
per GEP-8 — kills the sandbox and respawns) wraps the harness's
in-process HTTP retries. Conflating them would double-retry every
5xx, multiplying cost against providers.

### New `agent.md` fields

```yaml
---
provider: openai
model: gpt-4
network: proxy
http_timeout_s: 60           # NEW, optional; default 120
http_max_retries: 5          # NEW, optional; default 3
web_fetch_timeout_s: 10      # NEW, optional; default 30
max_tool_calls_per_turn: 50  # NEW, optional; default TBD during impl
---
```

All optional; absent → defaults. All live on `kind = "cli"` agents
too — identically-named CLI adapter wrappers may or may not honour
them, but parsing is uniform.

### Local-provider auto-detection

New `glorbo detect-providers` CLI verb and a "Scan" button in
ProvidersLive (GEP-6). Both are **localhost-only** — network scanning
is a surprise behaviour, so LAN probing requires explicit Director
configuration (not in v1).

**Probe.** `GET {endpoint}/v1/models` (or shape-appropriate path) on
each alias's default port. 1 s connect timeout, 2 s read timeout.

**Tie-breaks.** llamacpp and localai both default to `:8080`. A
successful `/readyz` response suggests LocalAI; a response header of
`Server: llama.cpp` points the other way. Ollama fingerprints via its
native `/api/tags` path. vLLM via `Server: uvicorn`. LM Studio via a
`Server: LM Studio` header.

**UX.** Discovered providers surface in `glorbo doctor` output and
the Providers view. No auto-activation — the Director clicks "Enable"
to create the per-provider TOML (empty credentials for local, `auth =
"none"`).

### Automatic model discovery

`Glorbo.Providers.ModelCatalog` — a new `GenServer` on the host,
**not** sandboxed — is the only place that legitimately holds every
provider credential at once. Agents never call it; they read cached
`/v1/models` data indirectly through SQLite when the wizard asks.

**Triggers.**

- Credential-file watcher (extends GEP-3's filesystem watcher to
  `~/.local/etc/glorbo/credentials/`). A new / edited file kicks off
  a probe for that provider.
- Manual "Refresh" button per provider in ProvidersLive.
- `glorbo detect-providers` CLI verb (same button, different surface).
- **Not** on `glorbo reindex`. Reindex remains offline-clean.
- **Not** on dispatch. Dispatch never waits on a catalog probe.

**Periodic refresh.** Default **OFF**. Directors who want it set
`providers.refresh_every_hours` in `~/.glorbo/config.md`. Most
Directors don't rotate models; surprise background traffic is
avoided.

**Storage.**

```
~/.glorbo/cache/providers/<alias>.json   # raw /v1/models response
```

Plus a SQLite projection:

```sql
CREATE TABLE provider_models (
  alias       TEXT NOT NULL,
  model_id    TEXT NOT NULL,
  context_window INTEGER,
  family      TEXT,
  raw_json    TEXT,
  refreshed_at TEXT,
  PRIMARY KEY (alias, model_id)
);
```

GEP-7 D6 compliant: every row is reconstructable from the cache
files. `glorbo reindex` reads the cache files and rebuilds the
table. No network call from reindex. Empty cache → empty table until
the next probe.

**Per-shape probe.**

| `shape` | Endpoint | Parse |
|---|---|---|
| `"openai"` | `GET {endpoint}/v1/models` | `data[].id` → `model_id` |
| `"ollama"` | `GET {endpoint_base}/api/tags` | `models[].name` → `model_id` |
| `"none"` | — | Manual via `[extras].deployments` (Azure) |

**Concurrency.** `Task.async_stream` with `max_concurrency: 5`;
per-provider 5 s overall budget. A slow provider never blocks the
catalog update for others.

**Failure classification.**

| Condition | Status in UI |
|---|---|
| 401 / 403 | `:auth` — bad credentials |
| `:econnrefused`, `:nxdomain` | `:unreachable` |
| 5xx, timeout | `:stale` — keep previous cache |
| Malformed JSON, unknown shape | `:shape` — probe broken, keep cache |

**UX.** ProvidersLive shows, per provider: model count, last-refreshed
timestamp, status chip. Agent-creation wizards (KanbanLive "New task"
quick-add, AgentLive "Add agent" modal) get a model combobox populated
from the cache; free-text fallback remains available.

**Unknown-model soft warn.** If `agent.md` names a model absent from
the cached list, Glorbo logs a warning at agent load time but does
**not** block dispatch. The provider is authoritative; the Director
may have added a new model between refreshes.

### `usage_parser = "native-v1"`

Named parser, **not** `"none"`. GEP-8 D6's "usage parsing is
code-shaped telemetry" applies to native agents too; the harness's
`/run/usage.json` schema is Glorbo-owned and the parser is a
trivial JSON read.

`tracked: false` is set by the harness **only** when the provider
didn't populate `usage` in the response body (common for Ollama,
llama.cpp, some self-hosted endpoints). GEP-8 D15's
`allow_untracked_budget: true` per-agent gate kicks in **only** for
those dispatches, not blanket-for-all-native-agents.

Cloud providers virtually always emit token counts; local providers
often don't. The per-agent gate lets a Director say "I trust this
Ollama endpoint even without billing" without opting every native
agent out of the budget system.

## Migration / rollout

This is an **additive** extension of GEP-8 with one compatibility
concern: the new `kind` field.

**Back-compat.** Existing `priv/providers/*.toml` entries
(claude-code, codex, gemini-cli, hermes, opencode, pi) do not declare
`kind`. `Registry.Loader` treats absence as `kind = "cli"`. No
migration work for existing deployments.

**Phased landing.** The implementation plan breaks into four shippable
increments:

1. **Registry schema + first native provider.** Extend `Registry.Loader`
   validation, land `priv/providers/openai.toml` + `openrouter.toml`,
   ship the `glorbo harness` subcommand with `/v1/chat/completions`
   + `read_file` only. Enough to dispatch a toy task.
2. **Full tool catalog.** `write_file`, `edit_file`, `glob`, `grep`,
   `bash`, `web_fetch`. Per-tool audit events.
3. **Credentials + model discovery.** `~/.local/etc/glorbo/credentials/`
   layout, `ModelCatalog` GenServer, cache + SQLite projection, doctor
   warnings.
4. **Auto-detect + Providers UX.** `glorbo detect-providers` CLI verb,
   ProvidersLive "Scan" button, model combobox in agent-creation
   wizards.

Each increment is shippable on its own. Directors with only CLI
agents see no behaviour change at any point.

**`glorbo reindex` contract preserved.** Reindex remains offline —
the `provider_models` table rebuilds from the `~/.glorbo/cache/` JSON
files, not from network calls.

## Failure modes

| Failure | Surface | Director response |
|---|---|---|
| Provider TOML declares `kind = "native"` but omits `usage_parser` | Hard fail at `Registry.Loader` boot | Fix the TOML |
| Agent points at a provider whose credentials file is missing | `:no_such_provider_credentials` dispatch error | Create the TOML |
| Credentials file has wrong permissions | `glorbo doctor` warning (not a fail) | `chmod 600` |
| Model name not in cache | Soft warn at agent load; dispatch proceeds | None required — dispatch will fail fast if the provider rejects |
| Provider 401 / 403 | Dispatch error, audit `dispatch.auth_failed`, `ModelCatalog` marks provider `:auth` | Rotate key |
| Provider 5xx / timeout | Harness-level retry (up to `http_max_retries`); if exhausted, dispatch error, Router retries once per GEP-8 | Usually transient |
| Provider 429 | Harness honours `Retry-After`; if exhausted, dispatch error | Usually transient; budget concern |
| Provider silently omits `usage` field | `tracked: false` in `/run/usage.json`; GEP-8 D15 gate applies | Director enables `allow_untracked_budget: true` per-agent if intentional |
| Harness crash mid-dispatch | Sandbox exits non-zero; Router audits `dispatch.crashed`; reply file empty | Existing Router behaviour |
| `web_fetch` hits a host classified deny (once GEP-23 lands) | Audit `egress.blocked`; tool returns error to the LLM | Director reviews filter config |
| Local provider stopped between detection and dispatch | `:unreachable` in ModelCatalog; dispatch fails with clear error | Restart the provider |

No new supervision-tree risk: the harness is just another sandbox
process under the existing `Agent.Dispatch` supervisor.

## Test strategy

- **Registry loader.** Unit tests for each new validation rule
  (`kind ∈ {"cli", "native"}`, `auth` enum, `model_list.shape` enum,
  missing `usage_parser` on native). Hard-fail path exercised.
- **Harness dispatch.** Integration test against a stubbed OpenAI-v1
  endpoint (`Plug.Cowboy` on a loopback port mounted into the
  sandbox). Exercises `/v1/chat/completions`, `usage` parsing,
  reply-file contract, and one of each tool.
- **Tool gating.** Unit-level tests that `write_file` outside the
  mounted project tree fails at the kernel layer, not the application
  layer (confirming no in-process allowlist is needed).
- **ModelCatalog probes.** Property tests covering each shape
  (`openai`, `ollama`, `none`) plus each failure classification
  (`:auth`, `:unreachable`, `:stale`, `:shape`) using a stubbed HTTP
  server.
- **Reindex offline contract.** `glorbo reindex` with the network
  down, with a populated `~/.glorbo/cache/providers/` tree, rebuilds
  `provider_models` bit-for-bit against the cached JSON.
- **Credentials isolation.** Integration test: agent A (provider
  `openai`) must not have `/creds/openrouter.toml` visible in its
  sandbox. Hard assertion on `File.exists?` inside the sandboxed
  process.
- **Auto-detect.** Unit tests per-fingerprint. Integration test:
  fake local server on `:11434` with Ollama-shape response →
  detected as `ollama`; with LM Studio headers → detected as
  `lmstudio`.
- **Budget tracking.** End-to-end: native dispatch with `tracked:
  true` writes correct token counts into the ledger; with `tracked:
  false`, GEP-8 D15 gate behaves correctly.
- **UAT.** Director goes from fresh install → `glorbo detect-providers`
  → enables Ollama → creates an agent via the wizard → dispatches a
  task → sees audit + reply. Covered in `docs/testing/uat.md`.

## Open questions

- **Streaming.** v1 will deliver the full assistant message after the
  provider responds, matching how the CLI adapters behave. Whether the
  harness streams tool-call deltas to the Router (for live UI) is
  deferred to a v2 GEP.
- **Azure `deployments` lifecycle.** `[extras].deployments` is
  manually-maintained today. Probing an Azure deployment list
  programmatically requires management-plane credentials, which is a
  separate auth surface. Deferred.
- **Shared-port disambiguation regressions.** `llamacpp` and `localai`
  both default to `:8080`. Our fingerprint heuristics are
  best-effort; a user whose endpoint is a reverse-proxy in front of
  either will likely need manual configuration. Acceptable for v1.

## Decision log

### D1. Native OpenAI-v1 provider as new Registry `kind`

- **Decided:** Add `kind = "native"` to the GEP-8 Registry schema,
  sitting alongside `kind = "cli"`. Dispatch extends with one new
  case; everything else is inherited.
- **Alternatives:** Drop-in replace CLI dispatch with native (would
  break GEP-4 and every shipped CLI provider). In-process SDK client
  (would collapse GEP-5's two-layer enforcement).
- **Why:** Extending the Registry kind is the smallest change that
  keeps every invariant. It is GEP-8 D6's config/code split applied
  to a new parser kind.

### D2. Single binary: `glorbo harness` subcommand

- **Decided:** The native harness is a subcommand of the existing
  single Glorbo binary, bind-mounted into the sandbox as
  `/usr/bin/glorbo-harness`. No separate artefact.
- **Alternatives:** Separate standalone harness binary (doubles build
  complexity, Burrito-ifies twice). Statically-linked Rust harness
  (introduces a non-BEAM toolchain and a cross-language contract
  boundary we don't need).
- **Why:** Preserves Glorbo's "one binary, one directory" philosophy.
  The in-sandbox attack surface is a single, small subcommand of our
  own code — no bundled Node/Python runtime, no opaque third-party
  CLI.

### D3. OpenAI v1 REST only for v1

- **Decided:** Support OpenAI-v1-compatible `/v1/chat/completions`
  only. ~33 providers covered. Native-shape APIs
  (Anthropic extended thinking, Gemini grounding) addressable in a v2
  GEP.
- **Alternatives:** Support all native shapes up-front. LiteLLM-style
  meta-router in-process.
- **Why:** Scope containment. LiteLLM would drag Python or Node into
  Glorbo, violating GEP-2 D8. A single wire format covers every
  endpoint a Director is likely to want in v1.

### D4. Harness runs in the identical bwrap tree as CLI agents

- **Decided:** Native harness inherits GEP-4's sandbox profile
  verbatim. Same `--unshare-net` rules, same per-permission project
  mounts, same `--cap-drop ALL`.
- **Alternatives:** Unsandboxed host-process harness. A separate
  sandbox mechanism for native agents.
- **Why:** Preserves GEP-5 D1 two-layer enforcement intact. The native
  harness is an extension of GEP-2 pillar 5 ("wrap existing CLIs"),
  not a softening of it — the wrapped CLI simply happens to be
  first-party.

### D5. Credentials at `~/.local/etc/glorbo/credentials/<provider>.toml`

- **Decided:** Credentials live outside `~/.glorbo/` at
  `~/.local/etc/glorbo/credentials/<provider>.toml`.
- **Alternatives:** Inside `~/.glorbo/credentials/` (naïve
  `tar cf backup ~/.glorbo` sweeps secrets). XDG-split layout
  (`~/.config/glorbo/credentials/`) — deferred to a future
  full-layout-migration GEP. Claude-style sibling dotfile
  `~/.glorbo.credentials.toml` (less discoverable than a per-provider
  directory).
- **Why:** Mirrors system `/etc/` scoped to user; out-of-tree location
  gives Directors free secret-safe backup semantics without teaching
  them a new `glorbo backup` verb.

### D6. `GLORBO_CREDENTIALS_DIR` env-var override

- **Decided:** Env var overrides the default credentials directory.
- **Alternatives:** CLI flag per invocation. Config-file path.
- **Why:** Mirrors the `CLAUDE_CONFIG_DIR` pattern agents are already
  familiar with. Supports CI and secrets-manager deployments (mount
  under `/run/secrets/`, point the env var at it).

### D7. Credentials as one TOML file per provider

- **Decided:** `<provider>.toml` single file, with `api_key`,
  `endpoint`, and an `[extras]` table for provider-specific fields.
- **Alternatives:** Per-provider directory. Single shared blob
  (`credentials.toml` with a section per provider).
- **Why:** Bind-mount shape is one file per provider, which is
  trivial to isolate. A shared blob would force either whole-file
  bind-mount (leaks peer creds) or per-section re-serialisation (more
  code).

### D8. Global per-provider credentials (not per-alias)

- **Decided:** One file per provider globally. No per-alias
  multiplication.
- **Alternatives:** Per-alias files (`<alias>.toml`) allowing
  different keys per logical agent binding.
- **Why:** Single-Director model; we haven't seen a use case for
  per-alias keys at our tier.

### D9. `chmod 600` file + `chmod 700` parent + doctor warnings

- **Decided:** Glorbo relies on standard filesystem permissions for
  secret confidentiality; `glorbo doctor` warns on laxer modes.
- **Alternatives:** Encrypt credentials at rest (master password).
  Delegate to OS keychain.
- **Why:** Filesystem permissions are the existing, well-understood
  secret-confidentiality boundary on Linux. Out-of-tree location (D5)
  + correct perms + doctor nudges is enough for v1.

### D10. `kind = "cli"` is the back-compat default

- **Decided:** `Registry.Loader` treats missing `kind` as
  `kind = "cli"`. Native entries declare explicitly.
- **Alternatives:** Make `kind` mandatory for every provider TOML.
- **Why:** Zero migration work for existing built-in
  `priv/providers/*.toml` entries (claude-code, codex, gemini-cli,
  etc.). Mandatory would require a simultaneous edit of every
  shipped provider for no gain.

### D11. New Registry fields `auth` and `model_list`

- **Decided:** `auth ∈ {"none", "bearer", "api-key"}`;
  `model_list = {path, shape}` with `shape ∈ {"openai", "ollama",
  "none"}`. Validation additions to `Registry.Loader`'s hard-fail
  list.
- **Alternatives:** Infer `auth` from presence of `api_key` in
  credentials (implicit, error-prone). Skip `model_list` and use a
  hard-coded per-provider probe registry (code-shaped instead of
  data-shaped).
- **Why:** Closed enums validate cleanly at boot; `model_list`
  declared in data keeps the discovery subsystem GEP-8 D6 clean.

### D12. `usage_parser = "native-v1"` is a named parser, not `"none"`

- **Decided:** Native usage parsing is a first-class named parser
  reading Glorbo-owned `/run/usage.json`.
- **Alternatives:** `usage_parser = "none"` + global
  `allow_untracked_budget`.
- **Why:** GEP-8 D6's "code-shaped telemetry" applies to native too.
  Using `"none"` here would let a misconfiguration silently opt an
  agent out of budget tracking even when the provider does return
  token counts.

### D13. `allow_untracked_budget` still applies per-agent

- **Decided:** GEP-8 D15's per-agent `allow_untracked_budget` gate
  applies only when the harness sets `tracked: false` (i.e., the
  provider omitted `usage`).
- **Alternatives:** Blanket-opt native agents out of budget tracking.
- **Why:** Cloud providers virtually always return token counts.
  Local / subscription providers often don't. Per-agent gating lets
  the Director tolerate the missing counts on a specific Ollama
  endpoint without opting *every* native agent out of budgets.

### D14. MCP client deferred to v2

- **Decided:** The v1 harness has no MCP client.
- **Alternatives:** Ship MCP client in v1.
- **Why:** Scope containment. GEP-29's MCP-server side is a different
  surface; client-side in the harness is enough work to warrant its
  own GEP.

### D15. `network: none` invalid for native

- **Decided:** Reject `network: none` for `kind = "native"` agents at
  `Agent.Parser` parse time.
- **Alternatives:** Allow it; dispatch would fail at HTTP-connect
  time.
- **Why:** Structurally impossible — a native agent without network
  can't reach its endpoint. Parse-time rejection beats runtime
  surprise.

### D16. `network: proxy` declarable now, kernel-enforced on Linux

- **Decided:** `network: proxy` is declarable in v1; harness plumbs
  `HTTPS_PROXY` / `HTTP_PROXY` via env vars. Functional under
  GEP-23's proxy daemon and now kernel-enforced on Linux via GEP-31's
  `pasta` launcher path.
- **Alternatives:** Block `network: proxy` on native until GEP-23 or
  GEP-31 ships. Require a stub filter module in v1.
- **Why:** `:httpc` honours proxy env vars natively — no stub
  required. The runtime can therefore share the same proxy semantics as
  CLI-backed agents, and Linux now gets the same kernel-enforced
  boundary through the outer launcher without an agent-config rewrite.

### D17. `network: open` accepts the `bash` bypass of `web_fetch` filter

- **Decided:** Under `network: open`, `bash` inherits the sandbox
  network policy; `web_fetch`'s filter does not apply to it.
- **Alternatives:** Blocklist `curl` / `wget` / `nc` / etc. inside
  `bash`.
- **Why:** Partial blocking creates false security. The shell has a
  hundred ways to make an outbound connection; any blocklist is
  trivially evadable via `env`, scripts, Python one-liners. The CLI
  adapters (claude-code, codex, gemini-cli) already accept this
  trade-off. Consistency beats performative security.

### D18. `web_fetch` always emits `egress.web_fetch` audit event

- **Decided:** Every `web_fetch` invocation is audited with the
  target host and agent slug, regardless of `network:` mode or
  whether GEP-23's filter is wired.
- **Alternatives:** Audit only via the proxy. Disable `web_fetch`
  under `network: open`.
- **Why:** The harness is our code; we always audit what it does.
  GEP-23's per-host classification layers on top later. Auditing
  only via proxy would leave `network: open` fully unaudited at the
  tool layer; disabling `web_fetch` on open would not match existing
  CLI-agent semantics.

### D19. Retry classification

- **Decided:** Retry on network errors, connect / read timeouts,
  HTTP 5xx, and HTTP 429 (honour `Retry-After`). Do not retry any
  other 4xx.
- **Alternatives:** Retry everything. Retry nothing.
- **Why:** 4xx retries waste budget and spam providers —
  auth-failure and context-too-long are not transient. 5xx and 429
  are almost always transient and worth a retry.

### D20. Mandatory per-call timeouts

- **Decided:** Every HTTP request (provider + `web_fetch`) has a
  timeout. Defaults `http_timeout_s: 120`,
  `web_fetch_timeout_s: 30`.
- **Alternatives:** Rely on OS-level defaults (often none).
- **Why:** Unbounded blocking is the harness-liveness footgun — one
  slow provider can wedge an agent indefinitely. Explicit timeouts
  are the only responsible default for HTTP.

### D21. Two independent retry layers, kept separate

- **Decided:** `Glorbo.Agent.Dispatch.attempt_with_retries/4`
  (process-level, per GEP-8) wraps the harness's in-process HTTP
  retries. They are not conflated.
- **Alternatives:** Single retry layer, either in Dispatch or in the
  harness.
- **Why:** The layers handle different failure modes. Dispatch
  respawns the sandbox; harness retries within a single dispatch.
  Conflating would double-retry 5xx (Dispatch respawns, harness
  retries again inside the new sandbox) and multiply provider cost.

### D22. Localhost-only (127.0.0.1) auto-detection

- **Decided:** `detect-providers` probes only 127.0.0.1 endpoints.
- **Alternatives:** Scan RFC1918 ranges on start. Scan mDNS /
  Zeroconf.
- **Why:** Network scanning is a surprise behaviour; LAN probing has
  a consent problem even on trusted home networks. LAN support can
  be an explicit opt-in later.

### D23. Model catalog file-backed at `~/.glorbo/cache/providers/<alias>.json`

- **Decided:** Raw `/v1/models` JSON lives in per-alias cache files;
  SQLite `provider_models` is a pure projection.
- **Alternatives:** SQLite-only with a GEP-7 D6 carve-out. Re-probe
  on `glorbo reindex`.
- **Why:** Every row rebuildable from disk — GEP-7 D6 compliance,
  zero carve-outs. Keeps `glorbo reindex` offline-clean; reprobing
  on reindex would violate that contract and make reindex require
  network.

### D24. Catalog refresh triggered by explicit action, not reindex

- **Decided:** Refresh runs on `detect-providers` CLI verb,
  ProvidersLive "Refresh" button, or credential-file watcher — but
  **not** on `glorbo reindex` or dispatch.
- **Alternatives:** Refresh on reindex. Refresh on dispatch.
- **Why:** Reindex stays offline-clean. Dispatch is latency-sensitive
  and shouldn't wait on a probe. Explicit network traffic requires
  explicit user action.

### D25. Periodic refresh default OFF

- **Decided:** `providers.refresh_every_hours` is unset by default.
- **Alternatives:** Default every 24 h.
- **Why:** Most Directors don't rotate models; surprise background
  traffic (and the 401 / 403 cascade when a key expires) is avoided.
  Opt-in remains available.

### D26. Unknown-model soft warn only

- **Decided:** If `agent.md` names a model absent from the cached
  catalog, log a warning at agent load time; never block dispatch.
- **Alternatives:** Hard-fail agent load on unknown model.
- **Why:** Provider is authoritative; our cache is advisory. Blocking
  would frustrate Directors when a new model drops before they refresh
  the catalog.

### D27. Model probing is host-side, not sandboxed

- **Decided:** `ModelCatalog` runs in the host BEAM process.
- **Alternatives:** Spawn a sandboxed probe process.
- **Why:** The host is the only place that legitimately holds every
  provider credential at once — it needs them to probe multiple
  providers. Probes are not agent-initiated, so sandbox rules don't
  apply.

### D28. Smart-mode reentrancy is accepted

- **Decided:** If an agent's own provider is used as GEP-23 smart
  mode's LLM classifier, classifier HTTP calls are audit-tagged
  `egress.smart` and budget-tracked separately.
- **Alternatives:** Forbid an agent's provider from acting as its
  own classifier.
- **Why:** Matches GEP-23 D4's default. Forbidding reentrancy would
  add brittle configuration that Directors would stumble into in
  single-provider setups.

## Related

- **GEP-2** — Architecture Overview. The native harness extends
  pillar 5 ("wrap existing CLIs") with a first-party wrapped CLI,
  and preserves pillar 1 (kernel-layer sandbox) and D8 (no Python /
  Node in the runtime).
- **GEP-3** — Filesystem as Source of Truth. Credentials live
  outside `~/.glorbo/`; cached model catalogs live inside. Every
  SQLite row in `provider_models` rebuildable from the cache files.
- **GEP-4** — CLI-Tool Agents. This GEP extends GEP-4's dispatch
  model rather than replacing it; `kind = "cli"` entries continue to
  work unchanged.
- **GEP-5** — Sandboxing. The native harness runs in the identical
  bwrap tree CLI agents use; GEP-5's two-layer enforcement is
  preserved verbatim.
- **GEP-6** — Phoenix LiveView Dashboard. ProvidersLive grows a
  "Scan" button, per-provider credential configuration, and a model
  combobox in agent-creation wizards.
- **GEP-7** — SQLite as Derived Data. `provider_models` is a
  projection of `~/.glorbo/cache/providers/*.json`; reindex rebuilds
  from disk.
- **GEP-8** — Provider Registry. This GEP extends GEP-8's Registry
  schema (new `kind`, `auth`, `model_list` fields) and reuses GEP-8
  D6's config/code split intact.
- **GEP-17** — Cross-OS Sandbox and Watcher. Notes the macOS /
  Windows port deferral; a native harness port is tracked there for
  when cross-OS work is attempted.
- **GEP-23** — Egress Proxy with Filtering. `web_fetch` calls
  `Glorbo.Egress.Filter.classify/4` when GEP-23 lands; `network:
  proxy` becomes functional at the same point.
- **GEP-31** — Network-namespace Isolation for `:proxy` Agents.
  Soft dependency at draft time; now landed for Linux, so native
  `network: proxy` shares the same enforced proxy-only path there.

## Implementation reconciliation (2026-06-14)

This is an append-only record. Per GEP-1, an Accepted/Implemented GEP's body is not rewritten; deviations between the spec and the shipped code are documented here instead.

- **23 cloud + 10 local seed providers (33 total) vs. 3 shipped native TOMLs — known-gap (with an as-shipped harness caveat).** GEP §Goals (`docs/geps/0032-native-agent-harness.md:80-88`) advertises a harness that "speaks OpenAI v1 REST to any of ~33 cloud or local endpoints" and names Ollama/LM Studio/llama.cpp/LocalAI/vLLM/TGI/Jan/text-generation-webui/koboldcpp/MLX-Omni; §Seed provider list (lines 207-252) enumerates 23 cloud + 10 local = 33 as the v1 deliverable. In the repo, exactly **three** native-kind TOMLs ship under `priv/providers/`: `openai.toml`, `openrouter.toml`, and `minimax.toml` (the last not even named in the GEP). No `groq`/`together`/`fireworks`/`deepseek`/`azure-openai`/etc. seed file exists; the lone `"deepseek"` hit in `lib/` is an unrelated model-family bonus in `lib/glorbo/fit/scorer.ex:384`. The GEP's "33 endpoints" claim is **doc drift** as a *shipped-seed* count.
  - *As-shipped nuance — the harness capability is real, only the seed catalog is thin.* The OpenAI-v1 machinery genuinely works against any compatible endpoint regardless of seed count: native-kind dispatch, the `usage_parser = "native-v1"` path, model catalog, and localhost auto-detection are all built. Local providers are handled by a **detection-and-enable** flow rather than pre-shipped TOMLs — `lib/glorbo/providers/detect.ex:46-75` hard-codes a fingerprint ladder for **5** aliases (`ollama` :11434, `llamacpp` :8080, `localai` :8080, `vllm` :8000, `lm-studio` :1234), and `lib/glorbo/providers/enable.ex` writes the per-provider TOML on Enable. So a Director who runs Ollama/llama.cpp/LocalAI/vLLM/LM Studio gets a working provider without a shipped seed file — but the other 5 named local servers (tgi, jan, koboldcpp, textgen-webui, mlx-omni) and all 23 cloud aliases beyond openai/openrouter are **not yet built into either the seed set or the detect ladder**.
  - *Disposition / fix.* The honest record: v1 ships **openai + openrouter** (plus a later-added **minimax**) as the canonical native seed providers, with 5-alias localhost auto-detect, not the 33-provider catalog the body promises. Closing the gap is the cheap, data-only path suggested in the audit (add the remaining seed TOMLs under `priv/providers/`, and extend the detect ladder for the 5 missing local servers); until then this stands as a real **known-gap** to fix later, and the §Goals "~33 endpoints" / §Seed provider list copy should be read as aspirational catalog intent, not shipped surface.
