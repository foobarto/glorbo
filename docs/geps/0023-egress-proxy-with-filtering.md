---
gep: 23
title: Egress Proxy with Host Filtering and Smart Mode
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-04-21
requires: [2, 5, 19]
see-also: [4, 8, 22]
history:
  - date: 2026-04-21
    status: Draft
    note: Initial draft — introduces CONNECT proxy + sandbox namespace changes + LLM-driven smart filtering.
---

# GEP-23: Egress Proxy with Host Filtering and Smart Mode

## Problem

Today an agent with `network: :open` (the default for most real-world
use cases — LLMs live in the cloud) can reach any host on the
internet. We record nothing about where traffic went, we have no way
to block specific hosts, and we have no way to limit the blast
radius of a prompt-injected agent that decides to POST credentials
to an attacker.

The existing three primitives — `:none | :proxy | :open` — are
too coarse AND overlap: `:proxy` is a limp subset of `:open` with
no real enforcement (the kernel has no way to distinguish API calls
from other HTTPS). With this GEP we collapse the network policy to
**three values: `:loopback | :full | :proxy`**. `:none` goes too —
see the "loopback replaces none" discussion below.

Three concrete failures this GEP prevents:

1. **Exfiltration via unexpected hosts.** An injected agent could
   push company data to anywhere the sandbox reaches.
2. **DNS-based side channels** (e.g. TXT record abuse). Today the
   agent resolves DNS itself and we see nothing.
3. **Opacity.** Even *legitimate* outbound traffic is invisible in
   the audit log. The director cannot answer "did this agent call
   anything unusual last week?" without SSL-intercepting proxies.

## Goals

- Agents with `network: :proxy` route all outbound through a
  Glorbo-managed CONNECT proxy on `127.0.0.1:4100`.
- `bwrap` enforces it at the kernel layer: the agent's netns has no
  route to the internet except via the proxy.
- Allow/deny host lists in AGENT.md decide per-request.
- A **smart mode** uses a cheap LLM call to classify unlisted hosts
  against director-declared natural-language categories (e.g.
  `smart_deny: gambling, banking`).
- Every decision (allow/deny/pending) is audit-logged with host,
  agent, and reason.
- A new `/companies/:co/egress` LiveView surfaces history + pending
  approvals.
- **No TLS MITM.** We see hostnames (CONNECT preamble), not bodies.

## Non-goals

- **No response body inspection.** Preserving end-to-end TLS for CLI
  auth is non-negotiable.
- **No SOCKS5 support.** `HTTPS_PROXY` env covers every CLI we ship.
- **No WebSocket per-message filtering.** CONNECT tunnels are
  bytes-in-bytes-out past the handshake; we allow or deny the
  initial CONNECT and then can't inspect further.
- **No per-task egress rules.** AGENT.md is the granularity; tasks
  inherit the agent's network policy.
- **No runtime-installed filters.** Allow/deny/smart-rule changes
  happen via AGENT.md edits + watcher reload.
- **No multi-host deployment.** The proxy binds `127.0.0.1` — it's a
  single-host appliance, same as the rest of Glorbo.
- **No LLM calls on the happy path.** Smart mode only runs for hosts
  not matched by allow/deny/history.

## Design

### Network policy, AGENT.md

The `network:` field takes a new, simpler three-value set:

| Old | New | Behaviour |
|-----|-----|-----------|
| `none` | `loopback` | loopback-only netns; can reach `127.0.0.1` / `::1` but no external hosts. Fits the local-LLM (LM Studio / Ollama) case without opening the internet. |
| `:proxy` | `loopback` | same target; see migration section |
| `open` | `full` | `--share-net`; unfiltered access to anything the host can reach |
| *(new)* | `proxy` | veth pair into proxy-only netns; every external packet goes through `127.0.0.1:4100` |

**Why no `"truly isolated"` value?** A CLI invocation that literally
can't open any socket is rare enough in practice (most CLIs talk to
*something* — at minimum a local daemon, at best an API) that it
isn't worth a dedicated primitive. If the director really wants a
fully-offline CLI, they run a process without any LLM wiring; the
network policy doesn't help them there.

Extended frontmatter:

```yaml
network: proxy
egress:
  allow:
    - api.anthropic.com
    - "*.googleapis.com"
    - raw.githubusercontent.com
  deny:
    - "*.ads.*"
    - facebook.com
  mode: allow | deny | strict | smart
  smart_allow: >
    open-source code repositories,
    technical documentation,
    official language/framework docs
  smart_deny: >
    gambling,
    banking,
    cryptocurrency,
    adult content
  smart_model: claude-haiku-4-5   # optional; defaults to agent's own model
  kbps_cap: 512                   # optional; token-bucket throttle per dispatch
```

**Modes:**

- **`allow`** — allowlist-only. Unlisted = deny.
- **`deny`** — denylist-only. Unlisted = allow.
- **`strict`** — both lists checked; unlisted falls through to
  director approval (sentinel file, same UX as `approval.granted`).
- **`smart`** — same as `strict` plus LLM classification for
  unlisted hosts (see "Smart mode" below).

Wildcards supported in allow/deny: `*.example.com` matches any
subdomain; bare `example.com` matches exact only.

### Sandbox integration

Final three modes:

| Mode | bwrap netns | External reach |
|------|-------------|-----------------|
| `:loopback` | own netns with `lo` up; no veth pair; default route = none | loopback only (`127.0.0.1`, `::1`) |
| `:full` | `--share-net` | anywhere the host can reach |
| `:proxy` | own netns + veth pair into proxy-only ns | only `127.0.0.1:4100` (the proxy); the proxy then reaches the internet with filtering |

For `:proxy`, the dispatched process sees:
- `HTTPS_PROXY=http://127.0.0.1:4100`
- `HTTP_PROXY=http://127.0.0.1:4100`
- `NO_PROXY=127.0.0.1,localhost`
- No `/etc/resolv.conf` (proxy resolves all DNS in its own namespace).

The veth pair routes only to `127.0.0.1:4100`. The default route is
removed. An agent that ignores the env vars and tries direct sockets
gets `ENETUNREACH`.

### Proxy daemon

OTP layout under the main Glorbo app supervisor:

```
Glorbo.Egress.Supervisor
├── Glorbo.Egress.Proxy            # :ranch listener on 127.0.0.1:4100
├── Glorbo.Egress.Filter           # pure classifier
├── Glorbo.Egress.History          # per-company decision cache
├── Glorbo.Egress.SmartClassifier  # LLM dispatch for smart mode
└── Glorbo.Egress.Audit            # fire-and-forget audit writer
```

**Per-connection flow** (CONNECT handling):

1. Agent opens TCP to `127.0.0.1:4100`.
2. Proxy reads `CONNECT host:port HTTP/1.1\r\nProxy-Authorization: Basic <token>\r\n\r\n`.
3. Proxy resolves `<token>` → agent slug + company. Tokens are
   ephemeral per-dispatch (allocated by `Dispatch.execute/3`).
4. `Egress.Filter.classify(company, agent, host, port)` runs:
   - allow list match → `{:allow, :allowlist}`
   - deny list match → `{:deny, :denylist}`
   - private/internal IP → `{:deny, :private_ip}`
   - ad-TLD → `{:deny, :ad_tld}`
   - history cache hit → `{:allow | :deny, :cached}`
   - heuristic (known LLM provider, recent repeat) →
     `{:allow, :known}`
   - in smart mode, fall through to `SmartClassifier.classify/3`
     (async, see below)
   - otherwise → `{:pending_approval, sentinel_path}`
5. Emit audit event (always, even on allow).
6. Act on the classification:
   - allow → `:gen_tcp.connect/3` to real host, send `200
     Connection established`, tunnel bytes.
   - deny → send `403 Forbidden`.
   - pending_approval → write sentinel, send `503 Unavailable
     Retry-After: 60`. The agent's retry path (GEP-248) handles the
     wait. Director clicks approve/deny in the Approvals queue;
     next request reads the cache.
7. On tunnel: per-dispatch token-bucket throttles kbps per
   `egress.kbps_cap`.

### Smart mode (LLM classifier)

Proxy blocks on a cheap LLM call when the agent's mode is `smart`
and classification didn't match anything else.

**Prompt** (≈200 tokens):

```
You are a URL safety classifier. Decide whether the host is safe to
connect to for an autonomous agent working on behalf of a company.

Agent: <slug> (role: <role>)

Classify this host:
  <host>:<port>

Allowed categories (match → allow):
  <smart_allow>

Denied categories (match → deny):
  <smart_deny>

Respond with ONE line in this exact format:
  <verdict>|<category>|<rationale>

Where:
  <verdict>  = allow | deny | unknown
  <category> = one matching category from above, or "-" for unknown
  <rationale> = one short English sentence

No other output.
```

Classifier response is parsed line-at-a-time; malformed → treat as
`unknown` (fall-safe).

**Caching**: verdict cached for 30 days in `History`. Same host
within that window skips the LLM call.

**Budget**: classifier calls bill to synthetic `agent_slug:
"egress-classifier"` in `Glorbo.Budget`, per-company monthly cap.
Exhausted budget → classification skipped, fall through to director
approval sentinel.

**Prompt injection defence**:
- Host string stripped of `:`, `?`, `/`, `#` before prompting (port
  separated into its own field); capped at 253 chars.
- Classifier system prompt explicitly forbids output beyond the
  verdict line; the parser rejects any response that doesn't match
  the exact format.

**Model choice**:
- Defaults to the agent's own `model` (so local-only agents stay
  local).
- Overridable via `smart_model:` on AGENT.md.
- Never routes through a provider the agent doesn't already have
  permission for.

### History module

`Glorbo.Egress.History` — GenServer per company (started under
Company.Supervisor, same pattern as Company.Router).

On-disk shape: `companies/<co>/state/egress-history.json` with
schema:

```json
{
  "decisions": {
    "sha256(host)": {
      "host": "api.example.com",
      "first_seen": "2026-04-21T10:00:00Z",
      "last_seen": "2026-04-21T15:20:00Z",
      "count": 14,
      "last_decision": "allow",
      "last_reason": "known",
      "decided_by": "system" | "director" | "smart"
    }
  }
}
```

30-day rolling window: entries older than `last_seen + 30 days` get
pruned on next write.

### Audit events

- `egress.allowed` — `%{agent, host, port, bytes_in, bytes_out,
  duration_ms, reason}`
- `egress.denied` — `%{agent, host, port, reason}`
- `egress.pending_approval` — `%{agent, host, port, sentinel_path}`
- `egress.smart_allowed` — `%{agent, host, port, category,
  classifier_model, cost_usd_cents}`
- `egress.smart_denied` — `%{agent, host, port, category,
  classifier_model, cost_usd_cents}`
- `egress.smart_failed` — `%{agent, host, port, error,
  classifier_model}`

`AuditEntry.action_phrase/4` gains sentence renderers (e.g.
"denied egress to `api.ads.example.com` (ads_tld)"). The egress audit
volume can dwarf everything else on a busy dispatch — the
`channel.rotate` code path (GEP-238) applies unchanged.

### UI surfaces

- **`/companies/:co/egress`** — new LiveView:
  - Top-N hosts by bytes/count.
  - Denied-attempts tally.
  - Live feed (PubSub-driven) of recent decisions.
  - Filter by agent.
- **Sidebar** — add "Egress" row under Audit log (company scope).
- **CompanyLive stat card** — "egress · 24h" alongside
  "invocations · 24h".
- **ApprovalQueue extended** — pending-egress sentinels render
  alongside task approvals, with `approve (this request)` / `approve
  + allowlist (30 days)` / `deny (permanent)` buttons.
- **AgentLive Configuration tab** — network policy dropdown expands
  to include `:proxy`, with textareas for allow/deny/smart_allow/
  smart_deny.

### Per-dispatch token

`Glorbo.Agent.Dispatch.build_ctx/6` allocates an ephemeral token
(`:crypto.strong_rand_bytes(32) |> Base.url_encode64()`) for each
dispatch whose spec is `network: :proxy`. Token registered with the
proxy (`Egress.Proxy.register_token(token, company, agent,
expires_at)`). Expires 2× `spec.timeout_seconds` after dispatch end.

Prompt-internal details: the token lives in `HTTPS_PROXY` env; the
agent never sees it as a prompt input and never learns the full URL
(env is bwrap-private).

## Migration / rollout

**Breaking**: the `network:` field's value set changes.

| Old value | New value | Behaviour change |
|-----------|-----------|------------------|
| `none` | `loopback` | previous `:none` was `--unshare-net` (nothing at all); becomes loopback-only. Strictly more useful (local LLMs work) with the same "no external reach" guarantee. |
| `:proxy` | `loopback` | no enforcement was ever real; collapses to `loopback`. Directors who actually meant "route everything through an API host on the internet" should migrate to `proxy`. |
| `open` | `full` | rename only; same behaviour |

`Glorbo.Agent.Parser` accepts the old values as synonyms for one
release (v0.0.4 → v0.0.5), emitting a `spec.deprecated_network`
warning audit. v0.0.6 removes the aliases entirely — a hard error
at parse time.

**Why loopback replaces both `none` and `:proxy`?** `:none`
(`--unshare-net`) is strictly less useful than loopback-only: no
legitimate CLI benefits from total network absence over loopback-
only access, and most "offline" CLIs actually need at least a local
daemon (LM Studio, Ollama, pg). `:proxy` pretended to allow only
HTTPS-to-APIs but the kernel has no way to enforce that — it was
documentation, not a boundary. Collapsing both into `loopback` gives
directors one honest answer for "local talking to local"; anyone
who needs real-world API access migrates to `:proxy` and gets
actual filtering.

**Why no separate `:none` (truly-offline) value?** If a director
genuinely wants a CLI that cannot open any socket at all, they can
run a CLI that doesn't attempt to. Glorbo's network policy is a
ceiling, not a compulsion — a CLI that never calls `socket(2)` is
safe under `:loopback` too. Three values that carry meaning beat a
fourth that mostly duplicates the third.

Other rollout notes:

- **Additive for `:proxy`.** Existing agents keep working; no
  agent automatically becomes `:proxy` without an AGENT.md edit.
- **Config flag**: `config :glorbo, :egress_proxy_enabled, true` —
  the proxy only boots when enabled. Disabled = `:proxy` agents
  fail at mount with a clear error.
- **Veth dependency**: Linux `ip` command required on host (already
  a bwrap dep); doctor check gates feature.
- **No per-company activation** — the proxy is a global host-level
  service that any company's agents can route through once enabled.
- **Staged rollout**: ship proxy + allow/deny/strict modes first;
  smart mode in a follow-up PR so the LLM-classifier path can be
  separately audited.

## Failure modes

| Failure | Surface |
|---------|---------|
| Proxy process crashed | `:gen_tcp.connect` fails; agent sees `ENETUNREACH`; dispatch sees `:reply_file_missing`; GEP-248 retries kick in |
| Veth namespace setup failed at dispatch | `Dispatch.execute/3` returns `{:error, :netns_failed}`; audit event; no retry (config issue) |
| SmartClassifier timeout | Treat as `:unknown` → director approval sentinel |
| SmartClassifier returns malformed output | Same — `:unknown` |
| Classifier cost cap exhausted | Skip LLM, write director sentinel; `egress.smart_budget_exhausted` audit (once per month) |
| Allow/deny list malformed in AGENT.md | Parser rejects (existing validation path) |
| Token collision (ephemeral) | 256-bit random; practical probability of collision is zero |
| Agent bypasses env vars (tries raw socket) | bwrap netns has no route; `ENETUNREACH` |
| Agent uses DoH over the one allowed LLM host to tunnel | Covered by destination filtering — DoH endpoints (`dns.google`, etc.) are not in default allow lists; directors who allow them accept the risk |
| Director approves a host, then revokes it later | Next request hits the cache → allowed; director must explicitly deny (separate sentinel) to override |
| History JSON corrupted | Ignore file, start fresh, emit warning; no crash |

## Test strategy

- **Unit** (`Filter.classify/4`): allow/deny/private-IP/ad-TLD/
  wildcard match logic.
- **Unit** (`History`): 30-day pruning, cache hit/miss, atomic write.
- **Unit** (`SmartClassifier.parse_response/1`): verdict parsing,
  malformed handling.
- **Integration** (`Proxy`): fake client → proxy → fake upstream,
  asserts CONNECT/403/503 responses and byte forwarding.
- **Integration** (`Dispatch.execute/3`): with `network: :proxy`,
  verify token is set in env + netns bound.
- **End-to-end** (local-only, not CI): real agent with `mode: allow`
  + allow list `[example.com]` makes requests to a local stub
  server; deny + direct socket attempt fails with `ENETUNREACH`.
- **No live skills.sh / LLM calls in CI.** Stub classifier returns
  canned responses.

## Open questions

- **UDP**: we don't proxy UDP at all. An agent that needs UDP (rare
  for CLI tools) fails. Do we need a sidecar? Deferred until a real
  use case.
- **IPv6**: first version is IPv4 only; IPv6 allow/deny rules
  planned for v2.
- **Multi-proxy** (e.g. corporate upstream): for directors who want
  to chain behind their own corporate proxy. Deferred.
- **Per-host rate limits**: today we throttle per-dispatch bytes,
  not per-host. A runaway agent that hammers one host at 512 kbps is
  still 512 kbps. Deferred; the budget cap provides a global stop.
- **Classifier prompt-injection adversarial tests**: the prompt-
  injection defence above is design-level; real adversarial testing
  needs to happen before smart mode goes out by default.
- **Bandwidth billing**: today we bill token cost via Budget; should
  bandwidth be billed too? Deferred — no pricing signal yet.

## Decision log

### D1. CONNECT proxy, not SOCKS5

- **Decided:** HTTP CONNECT on `127.0.0.1:4100`.
- **Alternatives:** SOCKS5; transparent proxy via iptables; per-CLI
  plugin (e.g. `claude-proxy`, `codex-proxy`).
- **Why:** every CLI honours `HTTPS_PROXY=http://...`. SOCKS5
  requires per-CLI configuration that's inconsistent and often
  missing. iptables transparent redirection breaks opaque TLS because
  the handshake SNI is mid-stream, not first-flight. Per-CLI plugins
  multiply the surface area we'd need to maintain. CONNECT is the
  corporate-network-proxy convention for exactly this reason.

### D2. No TLS MITM

- **Decided:** CONNECT tunnels are opaque; we see host + port, not
  bodies.
- **Alternatives:** MITM with a Glorbo CA injected into the sandbox;
  per-CLI configured to trust Glorbo's cert.
- **Why:** MITM means we see request bodies including API keys,
  personal data, and secrets the agent is authenticated with. That
  shifts Glorbo's threat model from "audits metadata" to "has
  plaintext of everything." The director's loss of trust on that
  single change is much larger than the gain in visibility.
  Host-level filtering at CONNECT time is enough for the threat model
  this GEP addresses.

### D3. Smart mode uses LLM but fails closed

- **Decided:** smart mode routes unlisted hosts through a cheap LLM
  classifier with director-declared natural-language categories;
  any failure path (timeout, malformed output, budget exhausted)
  defers to a director approval sentinel.
- **Alternatives:** skip smart mode entirely (only rules); always
  defer to director; bake in a fixed category taxonomy.
- **Why:** natural-language rules ("smart_deny: gambling, banking")
  match how directors actually think about allowed destinations.
  The LLM classifier is cheap per request (~$0.0001 for haiku) and
  cached for 30 days. Fail-closed means a broken classifier never
  results in silently allowing unknown hosts.

### D4. LLM classifier defaults to the agent's own model

- **Decided:** `smart_model` defaults to the agent's `model` unless
  overridden.
- **Alternatives:** always use a global default (cheapest-known); make
  it mandatory to configure.
- **Why:** respects trust boundaries — an agent whose director picked
  a local-only provider (LM Studio) shouldn't have egress decisions
  quietly routed through a cloud model. The override exists for
  directors who accept the cross-provider trust but want lower cost.

### D5. Per-dispatch ephemeral token for agent identification

- **Decided:** `Dispatch.execute/3` mints a 32-byte random token,
  registers it with the proxy, sets `HTTPS_PROXY=http://:<token>@…`
  in sandbox env.
- **Alternatives:** identify by source port (bwrap netns gives us a
  1:1 mapping); identify by process UID namespace.
- **Why:** source-port identification is fragile across bwrap
  internals that may change. UID namespace doesn't map cleanly to
  "which agent slug right now." Ephemeral token is explicit,
  self-documenting in env, and leaves a forensic trail (token appears
  in the proxy's own log when it registers).

### D6. History is per-company file, not global

- **Decided:** `companies/<co>/state/egress-history.json`.
- **Alternatives:** one global file; SQLite table; no persistence
  (everything in memory).
- **Why:** matches GEP-2 company-isolation invariant. The director
  of acme.corp shouldn't see what hosts bigcorp.co allowed. SQLite is
  overkill for a file that's <1 MB. Memory-only loses 30 days of
  director decisions on restart, which is not acceptable.

### D7. Loopback-only binding, no LAN exposure

- **Decided:** `bind: {127, 0, 0, 1}` hardcoded.
- **Alternatives:** bind to `0.0.0.0` gated by config; bind to a
  Unix domain socket.
- **Why:** the proxy is an intra-host integration. LAN exposure
  would require auth the proxy doesn't have, and would give another
  machine the ability to route through it. Unix socket would work
  but requires every CLI to support Unix-socket proxies (many don't).
  Loopback is the minimum-surface option that works.

### D8. Proxy runs in its own netns, not the host's

- **Decided:** proxy's `:gen_tcp.connect` goes out through a
  dedicated namespace; sandbox's netns has a veth pair into it.
- **Alternatives:** proxy runs in the host netns, accessible via the
  sandbox's shared-net.
- **Why:** a proxy in the host netns means the agent's outbound is
  gated only by the proxy's application-level checks. A dedicated
  netns means even a bypass in the proxy (e.g. CONNECT parser bug)
  can't reach hosts we haven't allow-listed at the kernel layer.
  Defense in depth matching GEP-5's principle.

### D9. 30-day decision cache window

- **Decided:** director decisions and smart-mode verdicts cached
  30 days.
- **Alternatives:** forever; 24 hours; director-configurable.
- **Why:** 30 days balances "don't re-prompt for routine hosts" with
  "revisit stale decisions before they get stale." Forever means
  security posture decisions decay silently. 24h would make the
  prompt fatigue unmanageable. Director-configurable is
  over-engineering until someone asks.

### D10. Collapse to three policies (`loopback | full | proxy`)

- **Decided:** drop `:proxy`; rename `none → loopback` (and give
  it loopback access rather than nothing); `open → full`; add
  `proxy`.
- **Alternatives:** keep four values; keep `none` as
  truly-no-network; keep `:proxy` with best-effort deny lists.
- **Why:** `:proxy` never had kernel-layer enforcement — it was
  documentation, not a boundary, and `:proxy` now does the actual
  filtering it was gesturing at. `none` is strictly less useful
  than `loopback` (local LLMs work under loopback; directors who
  genuinely want *zero* network just run a CLI that makes no
  socket calls — the policy is a ceiling, not a compulsion). Both
  collapse into a single `loopback` value. Three clearly-named
  values are easier for directors to reason about than four values
  with overlapping semantics.

### D11. Failure at veth setup = hard stop, not fallback to direct

- **Decided:** if the netns/veth setup fails at dispatch time, the
  dispatch errors (no traffic flows); never silently fall back to
  `:open`.
- **Alternatives:** fall back to the previous policy; fall back to
  `:none`.
- **Why:** fall-back-to-open is the worst failure mode — the
  director expected proxying, gets unfiltered instead. Fall-back-to-
  `:none` looks correct-ish but breaks the dispatch in a confusing
  way. Explicit error with `:netns_failed` audit is honest.

## Related

- GEP-2 — Architecture (offline-by-default, single-host appliance).
- GEP-5 — Sandboxing (bwrap mount and netns invariants, extended by
  this GEP with a new policy).
- GEP-19 — Director approval workflow; egress pending-approval
  sentinels reuse the UX.
- GEP-22 — First external HTTP dependency (skills.sh); this GEP is
  the more invasive follow-up — outbound from the agent sandbox,
  not from the director's machine.
