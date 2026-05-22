---
gep: 0050
title: Per-agent egress authorization — default-deny + caller-identity authz
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Draft
type: Standards
created: 2026-05-22
requires: [23, 31]
see-also: [5, 19]
history:
  - date: 2026-05-22
    status: Draft
    note: |
      Initial draft. Captures the operator's "default to deny, check the
      company allowlist before allowing egress" + "per-agent
      authentication and authorization/ACL, not per company" decisions
      from findings C-080 + C-082. Touches the network-policy crown jewel
      (GEP-23 / GEP-31).
---

# GEP-0050: Per-agent egress authorization — default-deny + caller-identity authz

## Problem

GEP-23 ships a per-company CONNECT proxy. Two structural gaps surfaced
in review (findings C-080, C-082) — both are *design* gaps, not code
diverging from design, so they need a GEP, not a patch.

### C-080 — strict/deny egress can only widen, never narrow

`Glorbo.Network.Proxy.evaluate_and_tunnel/5` checks the company
allowlist **first** and opens the tunnel immediately on a hit; the
agent's `egress.mode: strict | smart` classifier is only reached for
hosts *not* already in the allowlist:

```
cond do
  port != 443                          -> 403
  MapSet.member?(policy.allowlist, host) -> open_and_splice(...)  # first
  true                                  -> classify_unlisted(...)  # only here
end
```

So an agent with `egress.mode: strict, allow: [audit.example.com]` can
still CONNECT to anything in the base provider allowlist
(`api.openai.com`, `api.anthropic.com`, `chatgpt.com`, `sentry.io`, …),
and an `egress.deny` entry **cannot block an already-allowlisted host**.
The per-agent policy can only add hosts, never remove them. That defeats
the containment the `strict`/`deny` feature implies.

### C-082 — per-agent grants are applied company-wide

`Glorbo.Company.Supervisor.company_allowlist/2` builds the proxy's
allowlist as the **union** of the base list plus *every* agent's
`network_allow:`, and there is **one shared proxy per company**. The
proxy decides purely on hostname (`MapSet.member?(policy.allowlist,
host)`) and is explicitly told the `Proxy-Authorization` token is
"AUDIT CONTEXT, not AUTHORISATION" (`proxy.ex`). Consequently a
sensitive per-agent grant — `network_allow: [payroll.internal]` for one
privileged agent — is reachable by **any** sibling agent in the
company, including a compromised api-only one. A per-agent grant does
not produce per-agent isolation. (Secondary: `network_allow` is read
from every AGENT.md regardless of whether the declaring agent is even a
`:proxy` agent.)

Operator decisions (one per finding):

> C-080: "default to deny, then check if agent is allowed by the company
> allowlist before allowing egress."
>
> C-082: "Yes, it needs per-agent authentication and
> authorization/ACL control rather than per company."

This GEP inverts the proxy decision to **default-deny** and promotes the
per-dispatch `Proxy-Authorization` token from audit-context to a
**per-agent authorization key** tied to that agent's effective egress
ACL. Strict/deny verdicts become **authoritative** — they can narrow the
company allowlist, not merely widen it.

## Goals

- **Default-deny at the proxy.** No host is reachable unless the request
  is positively authorized for the *specific calling agent*.
- **Caller-identity authorization.** The `Proxy-Authorization` token
  resolves to `{company, agent, dispatch_id}` (GEP-23 D5 already mints
  and resolves it) and that identity is an *authorization input*, not
  just an audit field.
- **Per-agent effective ACL.** Each agent's reachable set is computed
  from its own `network_allow` ∪ the base provider allowlist, then
  *narrowed* by the agent's `egress.deny` and (in strict/smart mode) the
  classifier. A sibling agent cannot reach another agent's private
  grant.
- **Strict/deny are authoritative.** `egress.deny: [x]` blocks `x` even
  if `x` is in the company/base allowlist; `egress.mode: strict` runs
  the classifier even on otherwise-allowlisted hosts for that agent.
- Only honour `network_allow` from agents that are actually `network:
  proxy` (close C-082's secondary leak).
- Every decision stays audit-logged (GEP-23 event set unchanged).

## Non-goals

- **No TLS MITM** (GEP-23 D2 stands — host + port only).
- **No per-task egress** (AGENT.md remains the granularity, GEP-23).
- **No LAN exposure** (loopback bind, GEP-23 D7).
- **No change to the netns / veth kernel enforcement** (GEP-31). This
  GEP changes the *application-layer authorization decision* the proxy
  makes inside the netns; the kernel boundary that forces traffic
  through the proxy at all is unchanged.
- **No multi-host / corporate-upstream chaining.**

## Design

Two viable shapes were considered (see D2). This GEP proposes
**caller-identity authorization on one shared proxy** as the primary
design, with **per-agent proxy listeners** documented as the rejected
alternative.

### Token = authorization key (not just audit context)

GEP-23 D5 already mints a 32-byte per-dispatch token, embeds it in
`HTTPS_PROXY=http://<token>@127.0.0.1:<port>`, and registers it with
`Glorbo.Network.ProxyTokens` mapping `token → {company, agent,
dispatch_id, expires_at}`. The token is bwrap-private (the agent never
sees it as a prompt input) and ephemeral.

This GEP promotes that resolution from "stamp audit context" to "select
the authorization policy":

1. Proxy reads `CONNECT host:443` + `Proxy-Authorization: Basic
   base64(token:)`.
2. `ProxyTokens.resolve(token)` → `{company, agent, …}` or
   `:anonymous`.
3. **`:anonymous` (absent/invalid token) → 403.** This is the
   default-deny inversion: today an absent token falls back to the
   company allowlist (`back-compat: absent or invalid tokens fall back
   to :anonymous and hit the company-scoped allowlist`, GEP-23 history
   2026-04-24). After this GEP, no resolved agent identity → no egress.
4. With a resolved `{company, agent}`, compute the **agent's effective
   ACL** and decide (next section).

Because every `:proxy` dispatch mints a token (GEP-23), legitimate
traffic always carries one; the back-compat anonymous path was the only
thing that relied on the company union, and it is exactly the hole
C-082 describes.

### Per-agent effective ACL + default-deny decision order

The proxy's decision for `(agent, host, port)` becomes:

```
1. port != 443                          -> 403            # unchanged
2. token unresolved (:anonymous)        -> 403            # default-deny (C-082)
3. host in agent.egress.deny            -> 403 (authoritative)   # C-080
4. host private/internal IP, ad-TLD     -> 403            # unchanged GEP-23
5. agent.egress.mode in [strict, smart]:
     -> run classifier for THIS host even if allowlisted   # C-080
        (classifier verdict can deny an otherwise-allowed host)
6. host in agent's effective allow set  -> open tunnel
     where effective allow = base_provider_allow ∪ agent.network_allow
     (NOT the company union of all agents' grants)          # C-082
7. otherwise                            -> classify (smart) or
                                           pending-approval sentinel (strict)
                                           or 403 (allow/deny mode)
```

Key inversions vs GEP-23:

- **Default-deny (step 2).** The base case is "deny" — reach requires a
  resolved agent *and* a positive match in *that agent's* set.
- **Deny is authoritative (step 3, before allow).** `egress.deny`
  vetoes even base/granted hosts.
- **Strict runs even on allowlisted hosts (step 5).** The agent's
  classifier sees the request regardless of allowlist membership, so
  strict can *narrow*.
- **Allow set is per-agent (step 6).** The proxy no longer consults the
  company-wide union; it consults `base ∪ this agent's network_allow`.
  Agent A's `payroll.internal` grant is not in Agent B's set.

### Where the per-agent ACL lives

`ProxyTokens` already keys on the dispatch's `agent`. The agent's
resolved `egress`/`network_allow` (already parsed into the spec at
dispatch time) is registered alongside the token at mint time — so the
proxy looks up the *policy* via the same `resolve/1` call, no extra file
read on the hot path:

```
ProxyTokens.register(token, %{
  company: co, agent: slug, dispatch_id: id, expires_at: t,
  egress: %{allow: MapSet, deny: MapSet, mode: :strict|:smart|:allow|:deny,
            smart_allow: str, smart_deny: str, smart_model: m}
})
```

`Glorbo.Network.Proxy` resolves `egress` from the token and decides
per-agent. `Company.Supervisor` stops building a company-union
allowlist for authorization (it may keep one purely for an *audit/UI*
"what could anyone reach" view, clearly labelled non-authoritative).

### Only honour `network_allow` from `:proxy` agents

`company_allowlist/2` (and its replacement) must skip `network_allow`
from agents whose `network:` is not `:proxy` — a `:loopback` or `:full`
agent's `network_allow` is meaningless and today silently widens the
set (C-082 secondary). The parser already knows each agent's
`network:`; gate the read on it.

### History cache keying

`Glorbo.Network.History` (GEP-23) caches decisions per company. With
per-agent authorization, a cached `:allow` for host `h` decided for
agent A must **not** authorize agent B. Cache keys gain the agent
dimension: `sha256(agent_slug <> host)` instead of `sha256(host)`, or a
nested `{agent → {host → decision}}` map. Director approvals likewise
record *which agent* the host was approved for.

## Migration / rollout

- **Breaking, pre-1.0, no kid gloves.** The anonymous-fallback path is
  removed: a `:proxy` dispatch with no resolvable token gets 403, full
  stop. In practice every GEP-23 `:proxy` dispatch already mints a
  token, so legitimate traffic is unaffected.
- Existing AGENT.md `network_allow` continues to parse; its *scope*
  changes from company-wide to per-declaring-agent. Directors who relied
  on one agent's grant leaking to siblings must add the grant to each
  agent that needs it. Document this in the egress docs + UAT.
- History cache: existing per-company entries are dropped on upgrade
  (re-derived on next request); they were keyed without the agent
  dimension and can't be safely re-attributed.
- `config :glorbo, :egress_proxy_enabled` gate unchanged.

## Failure modes

| Failure | Surface |
|---|---|
| Token resolves but agent's `egress` missing in registry | treat as default-deny → 403; log `egress.denied reason: no_policy` (fail closed) |
| Token expired mid-dispatch | `resolve/1` → `:anonymous` → 403; same as GEP-23 token expiry, now fail-closed instead of falling to company allowlist |
| Director approves a host for agent A | cached under agent A only; agent B re-prompts (correct isolation) |
| Classifier now runs on previously-allowlisted host (strict) | extra LLM calls for strict agents; bounded by GEP-23 history cache + budget cap |
| Proxy parser bug bypasses app-layer check | GEP-31 netns/veth kernel boundary still confines egress to the proxy; defense-in-depth (GEP-5) unchanged |
| Two agents share a `network_allow` host | each gets it in its own effective set — intended; isolation is "B can't reach A's *private* grant," not "no two agents may share a host" |

## Test strategy

- **Unit** (`Proxy` decision): default-deny on `:anonymous`;
  `egress.deny` vetoes a base-allowlisted host; strict runs classifier
  on an allowlisted host; per-agent allow set excludes a sibling's
  `network_allow`.
- **Unit** (`Company.Supervisor`/replacement): `network_allow` from a
  `:loopback`/`:full` agent is ignored.
- **Unit** (`History`): cache key includes agent; agent-A allow does not
  satisfy agent-B lookup.
- **Integration** (`Proxy` + `ProxyTokens`): registered token carries
  egress policy; CONNECT with agent-A token reaches A's grant, agent-B
  token to the same host → 403.
- **E2E (local, not CI):** two `:proxy` agents, one granted
  `internal.test`; sibling CONNECT to `internal.test` → 403; deny-list
  agent blocked from a base-allowlisted host.

## Open questions

- **Effective-ACL recomputation on AGENT.md edit mid-dispatch.** Token
  is minted at dispatch start; an edit during the dispatch isn't seen
  until the next dispatch. Acceptable (matches GEP-23 "changes via
  AGENT.md edit + watcher reload"), but worth stating.
- **Audit/UI "company reachable set" view.** Keep a non-authoritative
  union for the egress LiveView so the director can see the aggregate?
  Leaning yes, clearly labelled.
- **Smart-classifier model trust under per-agent.** GEP-23 D4 routes
  classification through the agent's own model; per-agent authz doesn't
  change that, but confirm the classifier dispatch is attributed to the
  *calling* agent's budget.

## Decision log

### D1. Default-deny: unresolved token → 403, remove the anonymous→company-allowlist fallback

- **Decided:** the proxy denies any request whose `Proxy-Authorization`
  token doesn't resolve to a `{company, agent}`; there is no fallback to
  a company-wide allowlist.
- **Alternatives:** keep the GEP-23 anonymous fallback (status quo);
  default-deny only when a config flag is set.
- **Why:** the operator's call — "default to deny, then check if the
  agent is allowed." The anonymous fallback is precisely the
  company-union hole C-082 describes. Every legitimate `:proxy` dispatch
  mints a token (GEP-23 D5), so default-deny costs nothing on the happy
  path. Operator decision dated 2026-05-22.

### D2. Caller-identity authz on one shared proxy, not one proxy per agent

- **Decided:** keep a single per-company proxy listener; authorize on
  the resolved token identity against a per-agent effective ACL.
- **Alternatives:** run a separate proxy instance/port per agent, each
  with its own allowlist (the other half of C-082's recommendation).
- **Why:** the token→identity resolution machinery already exists
  (GEP-23 D5, `ProxyTokens`); reusing it for authorization is a small,
  contained change. Per-agent listeners multiply ranch listeners, ports,
  and netns/veth plumbing (GEP-31) per concurrent agent, and the
  `HTTPS_PROXY` URL would have to be wired per-agent anyway — more
  surface for the same guarantee. Caller-identity authz is the
  minimum-surface way to get per-agent isolation. Per-agent listeners
  stay documented as the fallback if token-spoofing within a company
  ever becomes a concern (it can't today: the token is bwrap-private,
  32 bytes random, per-dispatch).

### D3. Strict/deny verdicts are authoritative — they narrow, not just widen

- **Decided:** `egress.deny` is checked before allow and vetoes
  base/granted hosts; `egress.mode: strict|smart` runs the classifier
  even on allowlisted hosts.
- **Alternatives:** keep allowlist-first (status quo); only let strict
  add hosts.
- **Why:** C-080. A "strict" mode that can't actually restrict the
  agent below the company baseline is misnamed and gives false
  assurance. Making the per-agent policy authoritative is what the
  feature name promises.

### D4. Per-agent effective ACL = base ∪ this agent's network_allow (no company union for authz)

- **Decided:** authorization consults `base_provider_allow ∪
  agent.network_allow` for the *calling* agent only; the company-wide
  union is not an authorization input.
- **Alternatives:** keep the company union (status quo); drop the base
  list too and require every agent to declare every host.
- **Why:** C-082's core fix — a per-agent grant must mean per-agent
  reach. Keeping the base provider list in each agent's set preserves
  the "LLMs work out of the box" ergonomics without leaking one agent's
  *private* grant to siblings.

### D5. Only honour `network_allow` from `:proxy` agents

- **Decided:** `network_allow` declared by `:loopback`/`:full` agents is
  ignored when building any allow set.
- **Alternatives:** honour it regardless (status quo).
- **Why:** C-082 secondary leak — a `:loopback` agent has no proxy path,
  so its `network_allow` is meaningless yet today widens the company
  set. Gating the read on `network: proxy` removes a free widening
  vector.

### D6. History cache is keyed per-agent

- **Decided:** decision-cache keys and director approvals carry the
  agent dimension; an allow for agent A does not authorize agent B.
- **Alternatives:** keep per-company cache (status quo).
- **Why:** a per-company cache would re-introduce the cross-agent leak
  through the cache even after the live decision is per-agent. Director
  approvals are per-agent for the same reason.

## Related

- GEP-23 — Egress proxy with host filtering and smart mode (the proxy +
  `egress:` frontmatter + per-dispatch token this GEP re-purposes). This
  GEP makes GEP-23 D5's token authoritative and inverts D-era
  allowlist-first ordering.
- GEP-31 — Network-namespace isolation for `:proxy` agents (the kernel
  boundary that forces traffic through the proxy; unchanged).
- GEP-5 — Sandboxing / "kernel is the policy engine"; this GEP
  strengthens the *application*-layer half of the defense-in-depth.
- GEP-19 — Director approval workflow (pending-approval sentinels, now
  per-agent).
- Finding C-080 — strict egress bypasses via global proxy allowlist.
- Finding C-082 — per-agent network allows applied company-wide.
