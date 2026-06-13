---
gep: 55
title: In-process inference proxy for sandboxed agents
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-06-07
requires: [8, 23, 31, 32]
see-also: [2, 5, 50, 52]
history:
  - date: 2026-06-07
    status: Draft
    note: |
      Initial draft. OpenAI v1-compatible proxy that replaces the GEP-32 credentials-mount path; eliminates real API keys from the sandbox. Single wire shape. Host-side credentials via GEP-32 TOML.
  - date: 2026-06-08
    status: Draft
    note: |
      Revised. Operator reframed the design with the "ollama launch" analogy + "quality over partial result" directive. Now multi-shape (OpenAI v1 + Anthropic Messages + Gemini), host-side credentials via `System.get_env/1` only, GEP-32 credentials TOML removed from the proxy path. D4, D10, non-goals, failure modes, and related-GEPs all updated.
  - date: 2026-06-10
    status: Draft
    note: |
      Slice 1-4a review round (multi-agent review + fixes). Fixed pre-commit: nested {:ok, token} tuple in the dispatch mint, *_BASE_URL pointing at the GEP-23 CONNECT proxy (with its userinfo token), token never revoked at dispatch end, head/body buffering stall on single-segment POSTs, acceptor-death respawn re-binding on a new port/0.0.0.0, upstream auth headers dropped, missing token-company cross-check, nil-adapter crash, and the harness/model-catalog `via_proxy` gap. Implementation-plan table added; CLI first wave re-gated behind D11 + loader lift; pasta -T now forwards the inference-proxy port.
---

# GEP-0055: In-process inference proxy for sandboxed agents

## Problem

Glorbo's native agent runtime — and every OpenAI v1-compatible CLI
(Codex, opencode) and every Anthropic-Messages-compatible CLI
(Claude Code, Kiro) and every Gemini-compatible CLI (gemini-cli) the
user can configure — needs an upstream provider's API key to make
inference calls. Today, GEP-32 ships that key into the sandbox by
`--ro-bind`-ing `~/.local/etc/glorbo/credentials/<provider>.toml` at
`/creds/provider.toml` and pointing the in-sandbox runtime at it. The
bwrap mount view is read-only and the parent directory is `chmod 700`,
but the file itself is *in* the sandbox: a misbehaving or
prompt-injected LLM can `cat /creds/provider.toml`, copy the key into
`/outbox/`, and exfiltrate it on the next dispatch's reply. GEP-52
narrows this with a PreToolUse guard hook, but the mount is still
there; a class of bugs in the hook, or any tool surface the hook
doesn't cover, leaks the key.

The structural fix is to **remove the credentials from the sandbox
entirely**. The model is `ollama launch`: Glorbo starts the
in-process proxy; the proxy rewrites the agent's `*_BASE_URL`
environment variable (or equivalent settings-file injection) to point
at Glorbo's loopback listener; the agent's CLI thinks it's talking to
the real provider's API and behaves exactly as it would otherwise;
Glorbo translates between the agent's expected wire format and the
real upstream's wire format, attaches the real provider key, and
forwards. The agent's runtime never holds the real key. The kernel
boundary (bwrap + GEP-31 netns) is the only thing keeping the agent
*in its sandbox at all*; the proxy boundary keeps the key *out of
the sandbox*.

This is the same pattern Ollama users already know: a single command
launches the wrapped app with the right env vars; the wrapped app
talks to Ollama's API instead of Anthropic's. The difference is that
Glorbo's "Ollama" is a multi-shape proxy that can talk to *any*
upstream, not just a single local model server.

## Goals

- Eliminate real provider API keys from the bwrap sandbox. The
  sandbox only sees an ephemeral per-dispatch token, never a real
  key. The agent's `*_BASE_URL` env (or equivalent settings
  injection) points at the proxy's loopback port; the proxy is the
  one process that holds the upstream key.
- Support the full range of provider wire shapes the bundled CLIs
  speak, on day one: **OpenAI v1** (openai / openrouter / minimax /
  any local OpenAI-compatible endpoint), **Anthropic Messages**
  (claude-code / kiro / any Anthropic-Messages-compatible CLI), and
  **Google Gemini** (gemini-cli). Each shape is an adapter behind a
  single `Glorbo.OpenAIProxy.Shape` behaviour; the proxy routes by
  HTTP path prefix.
- Make the operator's life simple. **No new credential location.**
  The user exports `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` /
  `GEMINI_API_KEY` (etc.) in their normal shell environment — the
  same env vars their CLI tools already use when run outside Glorbo.
  Glorbo reads those env vars on the host. No `glorbo doctor --fix`
  for credential file permissions. No `~/.glorbo/credentials/`
  directory. No TOML.
- Reuse the GEP-23 per-dispatch `Glorbo.Network.ProxyTokens`
  infrastructure for sandbox-side authentication. No new token
  registry. The token's job is audit attribution, not authorisation
  (cross-provider replay is impossible by construction: the agent's
  request goes to a per-company proxy port that already knows which
  provider this company uses).
- Preserve the GEP-32 `usage_parser = "native-v1"` accounting path:
  each shape adapter extracts `usage` from the upstream's wire
  format and writes the same `~/.glorbo/run/usage.json` shape the
  harness already emits, so the budget ledger and audit log don't
  notice the swap.
- Stream end-to-end (SSE passthrough with audit tee) so Codex /
  opencode / claude-code / gemini-cli keep their progressive UX.
- Per-dispatch request log + per-agent cost rollup for the Director
  view, parallel to the GEP-23 egress history.

## Non-goals

1. **No new credential store.** No `~/.glorbo/credentials/`, no TOML,
   no `~/.env` parse, no opencode-config integration. The proxy
   reads `System.get_env/1` only. If the user wants to add another
   credential source (1Password, Vault, etc.), that's a separate
   GEP that this one consumes as a wrapper around `getenv`.
2. **No multi-provider fan-out or routing logic.** The proxy is
   1:1: an agent's configured provider maps to one upstream
   endpoint. An agent does not pick the cheapest provider per
   request. Provider selection is a per-agent decision declared in
   `agent.md` and frozen at dispatch start.
3. **No replacement of GEP-23's HTTPS CONNECT egress proxy.** That
   proxy carries arbitrary HTTPS from the sandbox (for non-LLM
   egress, e.g. `web_fetch`); this proxy only carries the LLM
   wire-format traffic. The two coexist on different loopback
   ports.
4. **No per-agent credential override.** The credential posture is
   per-provider (uniform across all agents using that provider);
   per-agent override is a footgun (the operator has to remember
   which agents have which override).
5. **No replacement of the GEP-32 `glorbo harness` binary** for
   tools-mode work. The harness's filesystem-tool batch
   (`read_file`, `write_file`, `edit_file`, `glob`, `grep`, `bash`,
   `web_fetch`) is unrelated to upstream-API call auth. Agents that
   need the harness's tool batch can still use it; this GEP just
   stops the harness from needing `/creds/provider.toml` mounted
   when the harness is the proxy consumer (the harness reads
   `GLORBO_OPENAI_BASE_URL` etc. the same way any CLI does).
6. **No change to the GEP-23 `network:` enum** (`loopback |
   proxy | full`). The proxy path is only meaningful for
   `network: proxy` agents; a `network: loopback` agent that
   somehow invokes this proxy will get `EHOSTUNREACH` from the
   kernel.
7. **No body-capture GEP.** The Director sees per-dispatch counts
   (chunk count, total bytes, first-token latency) and per-agent
   cost rollup, but never the full request/response body. Surfacing
   bodies is a separate threat-model GEP.
8. **No provider-agnostic streaming protocol.** Each shape adapter
   owns its own streaming implementation. The proxy layer is
   protocol-aware at the adapter boundary, not the wire boundary.

## Design

### Mental model

```
                     ┌─────────────────────────────────────┐
                     │  sandbox (bwrap + netns)            │
                     │                                      │
   Claude Code ──────┤  $ANTHROPIC_BASE_URL                 │
   Codex        ─────┤  = http://127.0.0.1:<PROXY_PORT>     │
   opencode     ─────┤                                      │
   gemini-cli   ─────┤  $OPENAI_BASE_URL (provider-specific)│
   harness      ─────┤  $GLORBO_PROXY_TOKEN                 │
                     │                                      │
                     │  "I'm talking to my provider's API"  │
                     └──────────────────┬───────────────────┘
                                        │ HTTP (plaintext, loopback)
                                        │ per-dispatch token in
                                        │ Authorization: Bearer /
                                        │ X-Glorbo-Token
                                        ▼
   ┌────────────────────────────────────────────────────────┐
   │  per-company Glorbo.OpenAIProxy                        │
   │  (Bandit on 127.0.0.1:<ephemeral>, behind GEP-31 netns)│
   │                                                        │
   │  ├─ TokenResolver ───> Glorbo.Network.ProxyTokens.resolve/1
   │  │                     → {co, agent, dispatch_id}      │
   │  ├─ ShapeRouter ─────> /v1/chat/completions, /v1/messages│
   │  │                     /v1beta/models/... → adapter     │
   │  └─ ShapeAdapters (3)                                 │
   │     ├─ OpenAI v1     (openai, openrouter, minimax)    │
   │     ├─ Anthropic     (claude-code, kiro)              │
   │     └─ Gemini        (gemini-cli)                     │
   │       │                                                │
   │       ├─ attach_auth: System.get_env(provider.api_key_env)
   │       ├─ translate_request → upstream's wire format    │
   │       ├─ upstream_call (Req, OpenAI/Cloud/Gemini API)  │
   │       ├─ translate_response → agent's wire format      │
   │       └─ extract_usage → GEP-32 D12 shape              │
   └────────────────────────────────────────────────────────┘
                                        │ HTTPS
                                        │ Authorization: Bearer <real-key>
                                        │ (read from System.get_env at call time)
                                        ▼
                          ┌──────────────────────────┐
                          │  upstream provider       │
                          │  (openai / anthropic /   │
                          │   google / openrouter /  │
                          │   minimax / local OAI-   │
                          │   compatible)            │
                          └──────────────────────────┘
```

### Provider-registry extension

The provider-registry TOML gets one new auth value and one new
required field:

```toml
name           = "openai"
kind           = "native"
endpoint       = "https://api.openai.com/v1"  # when auth=via_proxy, this is the UPSTREAM URL
auth           = "via_proxy"                   # NEW: opts this provider into the proxy
api_key_env    = "OPENAI_API_KEY"              # NEW: required when auth=via_proxy
usage_parser   = "native-v1"

[model_list]
path  = "/v1/models"
shape = "openai"
```

**Field semantics under `auth = "via_proxy"`:**

- `endpoint` — the **upstream URL** Glorbo forwards to, not the
  agent's base URL. The agent's `*_BASE_URL` is always the proxy's
  loopback URL.
- `api_key_env` — the **name of the host env var** Glorbo reads at
  request time to find the upstream key. Required, no default. If
  unset, the proxy refuses to route this provider's traffic.
- The GEP-32 `auth_binds` (CLI tool config mounts) are unused
  under `auth = "via_proxy"`; the proxy injects the base URL via
  env (or settings file, for CLIs that don't read env) instead.

**Field semantics under `auth ∈ {bearer, api_key}`** (the existing
GEP-32 path): unchanged. `endpoint` is still the agent's base URL
(matters for providers whose CLI doesn't read env), `api_key_env`
isn't read.

### Per-shape dispatch

When the agent's CLI process inside the sandbox starts up, it reads
its `*_BASE_URL` env (or its `settings.json`) and sees
`http://127.0.0.1:<PROXY_PORT>`. It makes its first inference call
to that URL, using whatever path the wire shape dictates:

| Shape adapter | Agent's CLI | Path pattern | Provider-registry entries |
|---|---|---|---|
| `OpenAI v1` | Codex, opencode, openai harness | `/v1/chat/completions`, `/v1/models`, `/v1/completions` | `openai`, `openrouter`, `minimax`, any local OpenAI-compatible |
| `Anthropic` | claude-code, kiro | `/v1/messages`, `/v1/models` | `anthropic`, `kiro` (or any Anthropic-Messages-compatible) |
| `Gemini` | gemini-cli | `/v1beta/models/...` | `google`, `vertex`, any Gemini-compatible |

The proxy's `ShapeRouter` matches the request path to the right
adapter. The match is exact, not fuzzy: `/v1/chat/completions` only
ever goes to the OpenAI adapter. There is no path-confusion surface.

### Per-provider TOML: shape is orthogonal to `auth = "via_proxy"`

A provider entry's wire shape is determined by which CLI it
backstops, not by its `model_list.shape`. Example: a `model_list.shape
= "static"` provider (Stado-style broker) that happens to be
configured as the upstream for an `openai` agent is still routed
through the OpenAI adapter. The adapter is the agent's CLI's wire
format; the model list shape is what Glorbo's UI shows in the
`/providers` page.

### New module: `Glorbo.OpenAIProxy`

Lives in `lib/glorbo/openai_proxy.ex`. GenServer with `:gen_tcp.listen`
+ a hand-rolled HTTP/1.1 request reader (D9), modeled on
`Glorbo.Network.Proxy` (GEP-23). Supervision-tree seat: under
`Glorbo.Company.Supervisor`, conditional on
`company_has_openai_proxy_provider?/2` (mirrors the GAP-4 scan for
the GEP-23 listener). The scan runs at supervisor init only:
flipping an agent or provider to `via_proxy` while the company is
running requires a company restart before the proxy exists;
dispatch fails loudly (`{:error, :openai_proxy_unavailable}`) in
that window.

**Auth flow** (per-request):

1. Read `Authorization: Bearer <token>` (also accept
   `X-Glorbo-Token: <token>` for clients that don't do Bearer
   auth, e.g. anthropic-cli).
2. `Glorbo.Network.ProxyTokens.resolve/1` returns
   `%{company, agent, dispatch_id, expires_at}` or `:expired` /
   `:unknown`.
3. Reject if `expires_at` is past, or dispatch_id is no longer
   alive (the agent's GenServer is gone).
4. Cross-check the token's `company` against the listener's
   company (`ProxyTokens` is one global table; the netns is the
   kernel layer, this check is the application layer — both-layers
   invariant). Then require the aliased provider's
   `auth == :via_proxy`: GEP-23 CONNECT tokens (no
   `provider_alias`) and tokens for other auth modes get a clean
   401.

**Routing flow:**

1. Match the request path to a shape adapter.
2. If no adapter matches, return 404 OpenAI-shaped error.
3. Adapter receives the request body, the upstream URL, and the
   upstream env-var name.
4. Adapter returns a translated request body + auth header for the
   upstream.
5. Proxy calls the upstream via `Req`, reads the response,
   translates back to the agent's wire format, writes the audit
   tee, writes `usage.json` if the adapter extracted usage.

The upstream URL is the provider endpoint's **origin** (scheme +
host + port) plus the agent's route-matched request target. The
endpoint's own path (the `/v1` in `https://api.openai.com/v1`) is
dropped — every shape's wire paths already start at the API root,
so appending would double the prefix. Upstreams hosted under a
subpath are a known limitation of this rule.

**Per-shape adapters (separate modules, one behaviour):**

```
Glorbo.OpenAIProxy.Shape               # behaviour
  ├─ OpenAI        (covers /v1/* paths)        # ~150 LOC
  ├─ Anthropic     (covers /v1/messages, /v1/models)  # ~180 LOC
  └─ Gemini        (covers /v1beta/models/...)  # ~150 LOC
```

Each adapter implements:

```elixir
@callback route?(path :: String.t()) :: boolean()
@callback translate_request(body :: map(), headers :: %{String.t() => String.t()}) ::
  {:ok, translated_body :: map(), translated_headers :: %{String.t() => String.t()}} |
  {:error, :bad_request, reason :: String.t()}
@callback attach_auth(headers, api_key) :: headers
@callback translate_response(upstream_body, original_request_body) :: agent_body
@callback extract_usage(upstream_body) :: {:ok, usage_map()} | :no_usage
@callback stream?(body :: map()) :: boolean()
@callback translate_stream_chunk(chunk :: String.t(), state :: any()) :: {[String.t()], any()}
```

The behaviour is intentionally narrow. Adding a new shape adapter
(e.g. for Mistral or Cohere) is a single module implementing
~6 callbacks.

### `usage` extraction

Each adapter's `extract_usage/1` returns a `usage_map()` in the
GEP-32 D12 shape:

```elixir
%{
  tracked: boolean(),          # false when upstream returned no usage
  prompt_tokens: non_neg_integer(),
  completion_tokens: non_neg_integer(),
  model: String.t() | nil,      # from upstream's response
  duration_ms: non_neg_integer()  # measured by the proxy
}
```

The proxy writes this to
`~/.glorbo/run/<dispatch_id>/usage.json` exactly as the GEP-32
harness does. The existing `usage_parser = "native-v1"` chain
consumes it unchanged. The budget ledger, the audit log, and
`allow_untracked_budget: true` semantics are preserved without
touching `Glorbo.Company.BudgetTracker` or `Glorbo.Agent.Parser`.

**Per-shape extraction rules:**

- **OpenAI v1**: final SSE chunk has `usage` (when `stream_options.include_usage`
  is set), or buffered JSON's `usage` field.
- **Anthropic Messages**: `message_delta` event carries
  `usage.output_tokens`; the initial `message_start` carries
  `usage.input_tokens`. Combine.
- **Gemini**: `usageMetadata` on the final non-streaming response;
  streaming responses do not currently include usage metadata
  (Google API limitation as of 2026-06) — adapter returns
  `:no_usage` for streamed Gemini calls; Director sees zero
  tokens for those.

### SSE audit tee

For streaming requests, the proxy:

1. Opens a write-stream to
   `companies/<co>/state/proxy-history/<dispatch_id>/stream.jsonl`
   (one JSONL row per chunk: `{ts, kind, payload_digest,
   byte_size}`; never the raw body — digest only, to keep the
   audit tee small).
2. Forwards each chunk to the agent's response unchanged.
3. After the stream closes, writes a final `usage_extracted` row
   with the parsed usage and `cost_usd` from the per-model rate
   table (`config/llm_rates.exs`, already the source of truth).

The proxy history lives under `state/` (not `audit/`) because it's
larger-grained than the JSONL audit log and isn't
append-only-mandatory in the same way; it's a per-dispatch
debugging artifact.

### Per-dispatch flow (end-to-end)

1. `Glorbo.Company.Supervisor.init/1` (existing) walks
   `agents/*.md`; if any agent's provider has
   `auth = "via_proxy"`, it starts `Glorbo.OpenAIProxy` alongside
   the existing `Glorbo.Network.Proxy`.
2. `Glorbo.Agent.Dispatch.do_execute/4` (existing) detects
   `auth = "via_proxy"` on the agent's provider; calls the new
   `Glorbo.OpenAIProxy.dispatch_token/2` to mint a per-dispatch
   token (reusing the GEP-23 `ProxyTokens` registry).
3. `Glorbo.Sandbox.Bwrap.start/2` (existing) gains a branch: when
   the provider is `auth = "via_proxy"`, it:
   - **Drops** the `--ro-bind ~/.local/etc/glorbo/credentials/...`
     mount that GEP-32 added.
   - **Adds** the per-shape `*_BASE_URL` env to the bwrap env
     list. The dispatch site knows the provider's wire shape
     (looked up from the provider's `auth` + name), so the right
     env var is set: `ANTHROPIC_BASE_URL` for Anthropic,
     `OPENAI_BASE_URL` for OpenAI v1, `GOOGLE_GEMINI_BASE_URL`
     (or equivalent) for Gemini, and the universal
     `GLORBO_PROXY_TOKEN` + `GLORBO_PROXY_BASE_URL`.
   - For CLIs that don't read env (e.g. claude-code's
     `settings.json`), generates a tiny on-disk settings file
     and bind-mounts it read-only at the CLI's config path.
     This is the only in-sandbox file Glorbo writes for proxy
     providers.
4. The CLI runtime inside the sandbox reads its
   `*_BASE_URL` (or its mounted `settings.json`) and calls the
   proxy. It does not know the proxy is Glorbo; it just thinks
   it's calling the real provider.
5. The proxy resolves the token, routes by path to the right
   adapter, the adapter reads `System.get_env(provider.api_key_env)`,
   translates the request, calls the upstream, translates the
   response, writes the audit tee, writes `usage.json` on
   completion.
6. On dispatch end, the existing GEP-23 token revocation path
   (`Glorbo.Agent.Dispatch` calls `Glorbo.Network.ProxyTokens.revoke/1`
   in its `after` block) revokes the token. Subsequent requests
   with that token get `401`.

### CLI-runtime base-URL injection

The `*_BASE_URL` env convention is universal for most modern CLIs,
but a few don't honor it. The exceptions and the per-shape handling:

| CLI | Wire shape | Reads env? | Mounted settings file? |
|---|---|---|---|
| Codex | OpenAI v1 | yes (`OPENAI_BASE_URL`) | no |
| opencode | OpenAI v1 | yes (`OPENAI_BASE_URL`) | no |
| `glorbo harness` | OpenAI v1 | yes (`OPENAI_BASE_URL`) | no |
| claude-code | Anthropic Messages | **no (settings.json)** | yes — `~/.claude/settings.json` rewritten to point `apiBase` at the proxy |
| gemini-cli | Gemini | partial (`GOOGLE_GEMINI_BASE_URL` works in recent versions) | no |
| Kiro | Anthropic Messages | yes (`ANTHROPIC_BASE_URL`) | no |

The settings-file injection for claude-code is a 4-line
`%{"apiBase": "http://127.0.0.1:<port>", "env": {"ANTHROPIC_AUTH_TOKEN": "<token>"}}`
file bind-mounted read-only. The agent sees a Claude Code config
that points at the proxy; it has no way to read the real
`ANTHROPIC_API_KEY` from anywhere.

### Director visibility

The Director's existing per-agent cost view
(`/costs`, `/companies/<co>/costs`) already reads the budget
ledger, which is fed by the `usage.json` write in the per-shape
adapter. No new widget required for costs.

For per-request visibility (the "what did the agent send and what
came back?" view), the proxy history under
`state/proxy-history/<dispatch_id>/stream.jsonl` is the source of
truth. The `/companies/<co>/agents/<agent>` page gains one tab:
"Proxy traffic", listing recent dispatches with chunk counts,
total bytes, first-token latency (SSE timestamp on chunk 1 vs.
request start), and a link to a paginated view of the JSONL. The
full request/response body is **not** in the JSONL — only digests,
model name, token counts, and timing.

### Failure modes

| Failure | Detection | Surfaces as |
|---|---|---|
| Token missing or expired | `ProxyTokens.resolve/1` → `:expired` | `401` OpenAI/Anthropic-shaped; `proxy.auth_failed` audit |
| Token's company ≠ route's company | post-resolve check (defence-in-depth) | `401`; `proxy.cross_company_blocked` |
| Upstream env var unset | `System.get_env(api_key_env)` returns `nil` at request time | `503` upstream-shaped; `proxy.upstream_credentials_missing` |
| Upstream unreachable (DNS / TCP) | `Req` `Mint.TransportError` | `502` agent-shaped; `proxy.upstream_unreachable` |
| Upstream returns 4xx | `Req` response status passthrough | Same status, agent-shaped body; `proxy.upstream_4xx` |
| Upstream returns 5xx | `Req` response status passthrough | `502`; `proxy.upstream_5xx` |
| Upstream mid-stream drop | `Req` stream error | SSE terminator chunk with `error: stream_dropped`; `proxy.stream_truncated` |
| Body too large | GEP-8 D12-style cap (default 1 MiB) | `413`; `proxy.body_too_large` |
| Token replayed after dispatch end | dispatch_id no longer in registry | `401`; `proxy.auth_failed` |
| pasta / netns failure | kernel-level (GEP-31 D-11) | dispatch aborts; `proxy.netns_failed` |
| Path doesn't match any shape adapter | `ShapeRouter.route/1` returns `nil` | `404` OpenAI-shaped (default); `proxy.path_unrouted` |
| Adapter rejects request body | `translate_request/2` returns `{:error, :bad_request, _}` | `400` agent-shaped; `proxy.adapter_rejected` |

All errors log to the per-company audit log (`audit/<YYYY-MM>.jsonl`)
with `actor_kind: "openai_proxy"` and a per-event `proxy.*` action
vocabulary.

## Implementation plan

Numbered slices (code comments reference these; the working copy
of this table previously lived only in untracked session state):

| # | Slice | Status |
|---|---|---|
| 1 | Provider-registry TOML: `auth = "via_proxy"` + `api_key_env` + validation | in tree |
| 2 | Dispatch env swap: per-shape `*_BASE_URL` + `GLORBO_PROXY_*`, token mint/revoke, pasta `-T` forward | in tree |
| 3 | Proxy listener + `Shape` behaviour + three adapters (routing) | in tree |
| 4 | Token resolution + company/auth checks; harness + model-catalog `via_proxy` support | in tree |
| 4a | Real upstream call, non-stream (translated body, auth headers, origin+target URL) | in tree |
| 5 | Streaming SSE passthrough + audit tee | pending |
| 6 | `usage` extraction write-out (GEP-32 D12 `usage.json`) | pending |
| 7 | Doctor check + `actor_kind: "openai_proxy"` audit rows | pending |
| 8 | Director visibility — "Proxy traffic" tab | pending |
| 9 | Gemini adapter translation + `?key=` auth; CLI wave (D11 settings.json + loader lift) | pending |

## Migration / rollout

- **Pre-1.0 atomic cut** (GEP-31 D-10 precedent). No
  `GLORBO_OPENAI_PROXY=1/0` rollout flag.
- **Built-in providers flip one-by-one.** The bundled native
  OpenAI-compatible providers (`openai`, `openrouter`, `minimax`)
  are the first wave. CLI providers (`claude-code`, `gemini-cli`,
  Codex, Kiro) follow once the per-CLI base-URL injection slice
  (D11 settings.json mount + lifting the loader's
  `kind = "native"` restriction on `auth = "via_proxy"`) lands —
  until then the loader hard-rejects `cli` + `via_proxy` (GEP-8
  D9). Each
  TOML gets `auth = "via_proxy"`, an `api_key_env` field, and the
  existing `endpoint` re-reads as "upstream URL." Migration is a
  per-file TOML change; no code changes ship unless the
  per-provider argv-injection logic needs the new field.
- **No re-keying.** The user's existing `OPENAI_API_KEY` /
  `ANTHROPIC_API_KEY` env vars keep working — Glorbo reads
  them on the host now, instead of the user's CLI reading them
  in the sandbox.
- **No on-disk migration.** The GEP-32
  `~/.local/etc/glorbo/credentials/<provider>.toml` files are
  no longer read by the proxy path. They stay in place for
  the GEP-32 harness (`glorbo harness` running outside the
  proxy) until that path also migrates (a future GEP, not this
  one). `glorbo doctor` no longer warns about missing or
  wrong-permissioned credential files for `via_proxy`
  providers.
- **Backwards compatibility:** a user who, for whatever reason,
  still wants the GEP-32 credentials-mount path keeps it by
  setting `auth = "bearer"` (or `api-key`) on their custom
  provider entry. The two paths coexist; the per-provider
  `auth` value picks.

## Test strategy

- **Unit tests** for each new module:
  - `Glorbo.OpenAIProxy` — request/response shape, token
    resolution, path-based routing, error mapping, streaming
    chunk handling, `usage.json` writing.
  - `Glorbo.OpenAIProxy.Shape.{OpenAI,Anthropic,Gemini}` —
    request translation, response translation, auth header
    attachment, `usage` extraction per shape, streaming
    chunk translation.
  - `Glorbo.CLI.Registry.Loader` — new `api_key_env` validation
    rule (required when `auth = "via_proxy"`), and the
    multi-shape routing.
  - `Glorbo.Agent.Dispatch` — bwrap argv branch for
    `auth = "via_proxy"`: no `/creds` mount, per-shape
    `*_BASE_URL` env vars, settings.json mount for
    claude-code.
- **Integration tests** for the full dispatch flow:
  - Stub upstream OpenAI v1 + Anthropic Messages + Gemini
    servers (already exist for GEP-32 tests; extend with
    per-shape variants).
  - Dispatch a `via_proxy` agent, assert:
    - Sandbox `/creds` does not exist (`File.lstat` →
      `:enoent`).
    - The right `*_BASE_URL` env is in the agent's env.
    - The stub upstream received the call and the
      `Authorization: Bearer <real-key>` header (read from
      `System.get_env` at call time).
    - `usage.json` is written in the GEP-32 D12 shape.
  - Negative test (GEP-31 D-8 discipline): the sandbox cannot
    reach any other loopback service (e.g. `127.0.0.1:4000`
    the Phoenix endpoint) at the `connect()` level.
  - Negative test: a revoked token gets `401` and the call
    does not reach the upstream.
  - Negative test: an unset `api_key_env` returns
    `proxy.upstream_credentials_missing` and the call does
    not reach the upstream.
- **E2E (Playwright via distrobox)**: the
  `/companies/<co>/agents/<agent>` page shows the new "Proxy
  traffic" tab populated after a dispatch, with the expected
  chunk counts and latency.
- **Security review**: every change to `Glorbo.Sandbox.Bwrap`
  argv construction gets a manual OWASP review (Paranoid
  posture, project-profile.md); the new branches are
  `auth = "via_proxy"` argv construction and the
  claude-code settings.json mount (defence-in-depth: lstat the
  file, refuse symlink ancestors).

## Open questions

1. **Streaming chunk audit granularity.** Capturing every
   SSE chunk's digest makes the per-dispatch JSONL grow ~linearly
   with response size. A 10K-token streaming response is ~50
   chunks. Two options for the v1 cut: (a) every chunk
   (simple, useful for debugging, ~5–10 KiB per dispatch), (b)
   only the first chunk and the last (smaller, less granular).
   Recommendation: every chunk; the size is bounded by
   `reply_max_bytes` already. Defer to implementation review
   if the on-disk cost surprises.
2. **Anthropic streaming usage.** Anthropic's streamed
   `message_delta` events carry `usage.output_tokens`. The
   `usage.input_tokens` is in the initial `message_start`.
   The Anthropic adapter needs to thread state through the
   stream to combine them. The behaviour interface's
   `translate_stream_chunk/2` already supports a state
   argument; final shape TBD in slice 3.
3. **Gemini streaming usage.** As of 2026-06, Google's Gemini
   streaming API does not include `usageMetadata` in the
   streamed chunks; it appears only in non-streaming
   responses. Director-visible "no tokens for this dispatch"
   on streamed Gemini calls is a known limitation. Mitigation:
   the budget ledger still records dispatch counts even when
   usage is zero (per `usage_parser = "native-v1"`'s
   `tracked: false` semantics).
4. **Per-company port allocation.** GEP-23 uses 4100 + a
   per-company offset (or `:ranch` `:ephemeral`). The new
   proxy is a third listener; pick a stable offset (e.g.
   4120) and document it. Recommend ephemeral to avoid
   multi-company-on-one-host collisions.
5. **Other shapes.** Mistral, Cohere, Groq, xAI/Grok, DeepSeek
   are all OpenAI v1 wire-compatible — they use the OpenAI
   adapter, no new code. Truly non-OpenAI shapes (Llama
   Stack, AWS Bedrock) are out of scope; each would be a
   new adapter module.
6. **Director body-capture GEP.** Surfacing full request
   bodies to the Director (currently digests only) is its own
   threat-model GEP — bodies may contain PII the Director
   uploaded. Not in this GEP.

## Decision log

### D1. Per-company loopback listener, in-process

- **Decided:** Implement the proxy as a per-company
  `:gen_tcp.listen` + Bandit Plug under the per-company
  supervision tree, bound to `127.0.0.1:<ephemeral>`,
  behind the existing GEP-31 pasta + netns enforcement.
- **Alternatives:**
  - Single global listener, multi-company. Rejected: shares
    a token-namespace surface that the GEP-50 per-agent
    authz model rejects.
  - UNIX domain socket. Rejected: requires a different
    injection point in bwrap argv and complicates the
    portable-OAI tooling that hard-codes `http://`.
  - Ranch listener in its own netns (GEP-23 pattern).
    Rejected: GEP-23 owns a netns because it tunnels
    arbitrary bytes; this proxy speaks JSON over HTTP and
    can share the proxy-mode netns the GEP-23 listener
    already has.
- **Why:** Per-company listener + GEP-31 netns = kernel-level
  guarantee that an agent can only reach the proxy for its
  own company, with no per-listener auth code on the accept
  path. In-process (not a separate OS process) is consistent
  with GEP-29's MCP server and keeps the Burrito binary lean.

### D2. Reuse `Glorbo.Network.ProxyTokens` for auth

- **Decided:** The sandbox sends `Authorization: Bearer
  <per-dispatch-token>` (or `X-Glorbo-Token`). The proxy
  resolves via the existing GEP-23
  `Glorbo.Network.ProxyTokens` registry.
- **Alternatives:**
  - New token registry. Rejected: doubles the auth code
    path and forces a parallel revocation flow. The GEP-23
    token already has the right TTL semantics (2×
    `spec.timeout_seconds`) and is already revoked on
    dispatch end.
  - mTLS. Rejected: requires a per-dispatch CA inside the
    sandbox; the GEP-23 userinfo + `Basic` pattern is
    simpler and equally unspoofable from another netns.
- **Why:** Token = audit attribution, single namespace. No
  new protocol surface. Reuses the GEP-31 D-8 test discipline
  (the agent can't reach any other loopback service, so
  token theft from a sibling agent is impossible).

### D3. New provider-registry field `auth = "via_proxy"` + `api_key_env`

- **Decided:** `auth = "via_proxy"` is a fourth value in
  the existing `auth` enum (`none | bearer | api_key |
  via_proxy`). It opts a provider into the proxy path.
  `api_key_env` is a new required field naming the host
  env var Glorbo reads for the upstream key.
- **Alternatives:**
  - New `mode = "proxy"` field orthogonal to `auth`.
    Rejected: two flags for one concept invites
    inconsistent combos (`auth = "bearer"`, `mode = "proxy"`
    = ???).
  - Per-agent field. Rejected: the security posture is
    uniform per-provider; per-agent override adds a
    configuration surface for no upside.
  - Auto-map `provider.name` to `<NAME>_API_KEY` for
    `api_key_env`. Rejected: brittle to renames, opaque
    when the user uses a non-standard env var name.
- **Why:** Single enum extension, single config seam, hard
  validation in `Registry.Loader`. Explicit > clever for
  the env-var name.

### D4. Drop the GEP-32 credentials mount AND the GEP-32 credentials TOML

- **Decided:** When `auth = "via_proxy"`, the bwrap argv
  drops `--ro-bind ~/.local/etc/glorbo/credentials/<provider>.toml /creds/provider.toml`.
  The proxy reads the upstream key from
  `System.get_env(provider.api_key_env)` at request time,
  with no host-side credential file at all.
- **Alternatives:**
  - Keep both the mount and a TOML file; agent decides
    at runtime which to use. Rejected: two ways to do the
    same thing is two ways to misconfigure; the security
    model is cleaner if the mount is simply absent.
  - Re-key into a new in-proxy credential store. Rejected:
    the user already has `OPENAI_API_KEY` in their shell
    (that's the whole point of the `ollama launch` analogy).
    Adding a Glorbo-specific credential store is friction
    the user doesn't need.
- **Why:** No new credential location. The env var the user
  already has set is what Glorbo reads. Removes the entire
  class of "agent reads its own creds and exfiltrates" bugs
  by construction. Removes the GEP-32 D9
  `chmod 600 / chmod 700` posture requirement (no file to
  chmod).

### D5. Multi-shape from day one, behind a behaviour

- **Decided:** Ship three shape adapters (OpenAI v1,
  Anthropic Messages, Gemini) in v1. Each is a small module
  implementing `Glorbo.OpenAIProxy.Shape`. Routing is by
  HTTP path prefix. New shapes are follow-on modules
  implementing the same behaviour.
- **Alternatives:**
  - OpenAI v1 only; Anthropic + Gemini as follow-on GEPs.
    Rejected per operator directive ("quality over partial
    result"); also rejected because it would force
    claude-code and gemini-cli to keep using the GEP-32
    credentials-mount path, defeating the GEP's main goal.
  - Per-shape dispatch in three separate proxies. Rejected:
    one proxy per company is already a non-trivial listener
    count; one proxy per company per shape is unmanageable
    on a host with several companies.
- **Why:** The behaviour is narrow enough (~6 callbacks)
  that adding a fourth or fifth shape is a single-day
  exercise. The OpenAI v1 adapter alone covers ~10+ bundled
  providers (openai, openrouter, minimax, plus any local
  OpenAI-compatible). Anthropic and Gemini cover the rest
  of the bundled CLIs. The "three adapters in v1" is a
  finite, bounded scope.

### D6. SSE passthrough with audit tee

- **Decided:** Streaming requests are proxied as SSE
  end-to-end. Each chunk is teed to
  `state/proxy-history/<dispatch_id>/stream.jsonl` with
  `{ts, kind, payload_digest, byte_size}`. Full bodies
  are never written.
- **Alternatives:**
  - Buffer then respond. Rejected: breaks the streaming UX
    Codex / opencode / claude-code depend on for progress
    indicators and tool-call preview.
  - Passthrough with no audit tee. Rejected: Director
    loses observability into what the agent sent and got,
    which is load-bearing for the "deliverable quality"
    crown jewel (project-profile.md).
- **Why:** Passthrough preserves UX; the digest-only audit
  tee is bounded by `reply_max_bytes` (GEP-8 D12) and gives
  the Director the observability they need without
  body-exfiltration risk.

### D7. Usage extraction, GEP-32 D12 schema preserved

- **Decided:** Each shape adapter parses the upstream's
  `usage` field (final SSE chunk for OpenAI when
  `stream_options.include_usage` is set, `message_delta`
  for Anthropic, `usageMetadata` for Gemini non-streaming)
  and writes `~/.glorbo/run/<dispatch_id>/usage.json` in
  the existing GEP-32 D12 schema. The existing
  `usage_parser = "native-v1"` chain consumes it
  unchanged.
- **Alternatives:**
  - New schema + new parser. Rejected: doubles the parser
    code path; the GEP-32 schema is already a clean
    superset of what the budget ledger reads.
  - No `usage` extraction; let the budget ledger run
    without per-request counts. Rejected: defeats
    `allow_untracked_budget: true` semantics (GEP-8 D15)
    and removes the per-agent cost rollup the Director
    depends on.
- **Why:** Schema preservation = no downstream code change.
  The proxy slots in transparently between the upstream
  and the GEP-32 parser; the budget ledger doesn't notice.

### D8. Per-dispatch proxy history, not global audit

- **Decided:** Streaming audit lives at
  `companies/<co>/state/proxy-history/<dispatch_id>/stream.jsonl`,
  not in `audit/YYYY-MM.jsonl`.
- **Alternatives:**
  - Append to the existing `audit/` JSONL. Rejected: the
    audit log has a size and frequency ceiling (it's
    indexed into SQLite for search); a single streaming
    dispatch could swamp it. State-level files are
    appropriately sized.
  - In-memory only. Rejected: the Director's "Proxy
    traffic" tab needs history to survive BEAM restart;
    per-dispatch files are reconstructable from disk per
    GEP-2 D3.
- **Why:** State is the right prefix for per-dispatch
  debugging artifacts (GEP-23 D6 precedent: `egress-history`
  is also under `state/`). Bounded by GEP-2 D3 (rebuildable
  from disk; `glorbo reindex` can drop the in-memory
  projection without losing data).

### D9. Hand-rolled Plug + behaviour, not a third-party SDK

- **Decided:** The proxy is a hand-rolled Plug on a
  Bandit listener. Each shape adapter is a hand-rolled
  module implementing `Glorbo.OpenAIProxy.Shape`.
- **Alternatives:**
  - `openai_ex` or similar client SDK. Rejected: drags a
    client-shaped API into a server role; the request
    shape is simple enough to parse by hand. Also: we
    support three shapes, not one.
  - Full MCP-shaped protocol. Rejected: MCP is
    LLM-orchestrator-facing, not provider-facing; the
    wire shapes in scope here are exactly what Codex /
    claude-code / gemini-cli already speak.
- **Why:** GEP-29 D6 made the same hand-rolled choice for
  the MCP server (Burrito-lean, no `finch` transitive
  surprises). Each wire shape is stable and small; a Plug
  per shape adapter is enough.

### D10. Atomic cut, no rollout flag

- **Decided:** No `GLORBO_OPENAI_PROXY=0/1` env flag. The
  built-in providers flip to `auth = "via_proxy"` in the
  same release the proxy ships. Users who want the old
  behavior set `auth = "bearer"` on a custom provider
  entry.
- **Alternatives:**
  - Opt-in rollout flag. Rejected per GEP-31 D-10
    precedent: pre-1.0 atomic cuts avoid the
    long-tail-of-half-configured-flags problem.
- **Why:** Pre-1.0, breaking changes are cheap; the cut
  is invisible to working agents (they get LLM responses
  either way) and security-positive (no real key in the
  sandbox).

### D11. Settings-file injection for CLIs that don't read env

- **Decided:** For CLIs that don't honor a `*_BASE_URL`
  env var (claude-code reading `settings.json`), the
  dispatch site generates a tiny in-sandbox settings file
  pointing the CLI's base at the proxy and bind-mounts it
  read-only. The settings file is the only in-sandbox file
  the proxy path produces.
- **Alternatives:**
  - Mount the user's actual settings file, rewritten on
    the host. Rejected: would let the agent see the
    user's real `apiKey` in adjacent keys.
  - Require the user to maintain a separate settings
    file. Rejected: shifts the burden to the user for a
    security boundary they shouldn't have to think about.
- **Why:** The settings file is per-agent, per-dispatch
  (in `<run_dir>/.glorbo/settings-<dispatch_id>.json`),
  bind-mounted read-only at the CLI's expected config
  path. The agent has no way to read the real `apiKey`
  because the real `apiKey` is never on the host at all —
  only the proxy process holds it (transitively, via
  `System.get_env`).

## Related

- GEP-2 — architectural baseline. The proxy slots in
  beside the GEP-23 egress proxy and the GEP-32 harness;
  it does not change any of the five pillars.
- GEP-8 — provider registry. The new `auth = "via_proxy"`
  value + `api_key_env` field extend the existing schema;
  no new registry surface.
- GEP-23 — HTTPS CONNECT egress proxy. The new proxy
  shares the GEP-23 per-dispatch token registry
  (`Glorbo.Network.ProxyTokens`) and the pasta netns
  enforcement.
- GEP-31 — netns isolation. The new proxy inherits
  GEP-31's "agent can only reach the proxy port"
  guarantee; no new kernel primitive is needed.
- GEP-32 — native agent harness. The proxy replaces
  GEP-32's credentials-mount path for `auth =
  "via_proxy"` providers; the harness itself
  (`glorbo harness` for filesystem tools) is unaffected
  and continues to use the GEP-32 credentials TOML for
  its own non-proxy mode.
- GEP-50 — per-agent egress authorization. The token
  registry is shared; per-agent allowlist semantics
  applied at the OpenAI proxy follow the GEP-50
  caller-identity pattern (for the non-LLM HTTPS the
  GEP-23 proxy carries).
- GEP-52 — provider-CLI hook hardening. The hook remains
  defense-in-depth for providers still on the
  credentials-mount path; for `auth = "via_proxy"`
  providers, the hook's threat model (agent reads
  `/creds/provider.toml`) is closed by construction.
- GEP-29 — MCP server. Same hand-rolled Plug pattern
  for loopback-only in-process HTTP; no shared code, but
  the same architectural shape.
- DESIGN.md §4.3 — provider and model configuration; the
  table will be updated to add a column for the proxy
  path once this GEP is accepted.
- `docs/testing/threatmodel.md` — proxy-related rows to
  add at acceptance time: "sandbox-side token never
  crosses proxy egress", "upstream key only in
  `System.get_env`", "settings.json mount is read-only
  + lstat-checked", "upstream 4xx/5xx surfaced as
  agent-shaped".

## Implementation reconciliation (2026-06-14)

This is an append-only reconciliation record. Per GEP-1, an Accepted/Implemented GEP's body is not rewritten; deviations between the GEP prose and the shipped code are recorded here instead (note: GEP-0055 is still `status: Draft`, line 5).

- **Goals "on day one" / Migration "first wave" overstate shipped reality — disposition: deferred.** The Goals (lines 70-76) promise OpenAI v1, Anthropic Messages, and Google Gemini support "on day one," and Migration (lines 508-513) says the bundled OpenAI-compatible providers (`openai`, `openrouter`, `minimax`) "are the first wave." In the current code: (a) the Gemini adapter's `attach_auth/2` is a self-documented no-op placeholder (`lib/glorbo/openai_proxy/shape/gemini.ex:107`, `def attach_auth(headers, _api_key), do: headers`), with `translate_request`/`translate_response`/`translate_stream_chunk` all pass-through (gemini.ex:99-114) and a "Current status (slice 4a)" docblock stating request translation, `?key=` auth, and streaming translation are slice 9 (gemini.ex:57-62); and (b) zero shipped provider TOMLs opt into the proxy — all of `priv/providers/openai.toml:6`, `openrouter.toml:6`, and `minimax.toml:6` set `auth = "bearer"`, none set `auth = "via_proxy"` or `api_key_env` (grep for `via_proxy` and `api_key_env` across `priv/providers/*.toml` returns no matches). The `via_proxy` mechanism itself is genuinely wired through the loader, dispatch, bwrap, supervisor, and proxy modules (`grep via_proxy lib/` hits 10 files incl. `cli/registry/loader.ex`, `agent/dispatch.ex`, `sandbox/bwrap.ex`, `openai_proxy.ex`), so this is specced-and-built-but-not-yet-activated rather than a code error. The GEP's own implementation-plan table (lines 491-502) is already internally honest: it marks slice 9 ("Gemini adapter translation + `?key=` auth; CLI wave") and slices 5-8 as `pending`, while slices 1-4a are `in tree`. Net: full Gemini auth/translation and the bundled-provider flip are not-yet-shipped (deferred to slice 9 and the per-provider TOML cut respectively); the "on day one" / "first wave" framing in Goals and Migration is aspirational prose that the slice table does not yet back. No code change is required — the gap is prose-vs-status, appropriate to a Draft GEP; on acceptance, either soften the "on day one" Goal to scope Gemini auth/translation to slice 9 or add a status banner pointing readers at the slice table.
