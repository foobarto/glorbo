---
gep: 31
title: Network-namespace isolation for `:proxy` agents
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-04-22
requires: [5, 23]
see-also: [4, 8, 22, 27]
history:
  - date: 2026-04-22
    status: Draft
    note: Initial draft — identifies the loopback-escape gap found during threatmodel work + UAT on 2026-04-22, proposes per-agent netns + pasta as the enforcement mechanism.
---

# GEP-31: Network-namespace isolation for `:proxy` agents

## Problem

After renaming `:api_only` → `:proxy` (atomic cut, 2026-04-22), the
network policy still doesn't *enforce* the name. An agent with
`network: proxy` runs inside the **host's network namespace** and
gets `HTTPS_PROXY` / `HTTP_PROXY` env vars as the only signal that
it "should" use the proxy. A CLI that respects proxy env vars (well-
behaved Claude Code, Codex, Gemini CLIs today) is steered correctly.
A CLI that ignores them — or any raw `:gen_tcp.connect/3` equivalent
inside a misbehaving tool — has full network reach:

- `connect(127.0.0.1, 4000)` lands on the Glorbo dashboard/MCP.
- `connect(10.0.0.5, 22)` reaches RFC1918 hosts on the operator's LAN.
- `connect(8.8.8.8, 53)` exfiltrates data over DNS to any public host.

Threatmodel finding from the same session: the MCP endpoint can be
gated with a dashboard token (T11 fix), and the proxy now rejects
private-IP destinations even when they're explicitly in the
allowlist (T8 fix) — but both defenses presume the agent actually
uses the proxy. An agent bypassing the proxy sidesteps both.

The UAT question that surfaced this cleanly: *"when an agent is
only allowed to talk to loopback, can it then access Glorbo's web
interface or MCP?"* — and the honest answer today is **yes**,
because "only allowed to talk to loopback" is a polite request, not
a kernel-enforced constraint.

## Goals

1. `network: proxy` becomes **kernel-enforced**: the agent process
   literally cannot open a socket to anything except the proxy.
2. `connect(127.0.0.1, *)` from the agent fails with EHOSTUNREACH
   (or equivalent), even though the host has services listening on
   loopback.
3. The Glorbo dashboard + MCP endpoint are unreachable from the
   agent side, regardless of what IP they bind to on the host.
4. Proxy behavior (HTTPS CONNECT on 443, allowlist + smart mode)
   stays unchanged from GEP-23 — this GEP only changes *how* the
   agent reaches the proxy, not *what the proxy does*.
5. No new root privilege requirement. Glorbo runs as an
   unprivileged user today and that stays true.

## Non-goals

- Replacing bwrap with podman/Docker (GEP-5 handled that
  decision; netns isolation is orthogonal).
- Changing the semantics of `network: none` (already kernel-
  enforced via `--unshare-net`).
- Filtering DNS — resolution happens inside the agent's netns via
  whatever DNS the netns has access to. If pasta exposes only the
  proxy port, DNS over UDP/53 fails and the agent must rely on
  the proxy's HTTP CONNECT (hostname-based) path. Acceptable.

## Decision

Use **`pasta` (from the `passt` project)** as the userspace network
stack for each agent on `network: proxy`. Pasta is designed for
unprivileged per-process netns bridging and supports port-level
allowlisting.

### Proposed architecture

```
           ┌─────────────────────────────────────┐
           │ host netns                          │
           │  127.0.0.1:<PROXY_PORT> ◄─── pasta  │
           │  127.0.0.1:4000         (Glorbo UI) │
           └─────────────────▲───────────────────┘
                             │
                             │ pasta forwards only
                             │ <PROXY_PORT> → agent netns
                             │
           ┌─────────────────▼───────────────────┐
           │ agent netns (per-dispatch)          │
           │  127.0.0.222:<PROXY_PORT> ◄ pasta   │
           │  HTTPS_PROXY=http://127.0.0.222:<P> │
           │                                     │
           │  (nothing else reachable)           │
           └─────────────────────────────────────┘
```

1. `bwrap` launches the agent with `--unshare-net` (already part of
   the `network: none` codepath; extend to `network: proxy`).
2. Before the agent CLI runs, `pasta` wraps the process (or we enter
   the netns from an outer process and launch pasta there). Pasta
   accepts `--tcp-ports 443` / `--tcp-ns <ns>` and only forwards the
   specific port back to the host.
3. Inside the agent netns, a single TCP listener is reachable at
   `127.0.0.222:<PROXY_PORT>` (the choice of `.222` is arbitrary
   but consistent — see D-4).
4. The agent's `HTTPS_PROXY` env var points at that address.
5. Any `connect(host, port)` from the agent goes through the
   netns's routing table — which has **no default route** except
   through pasta, which only honours the forwarded port.

### Fallback when `pasta` isn't installed

`Glorbo.Sandbox.Unsandboxed` (added by GEP-5 D7 for macOS) already
establishes the pattern of "refuse to start protected dispatches
and audit a degraded-mode event" when the kernel primitives are
absent. Mirror it: the `Doctor` check adds `pasta --version`, and if
unavailable:

- On Linux: emit `agent.netns_unavailable` audit event at company
  boot, log a big warning, fall back to **today's** behavior (shared
  netns + env vars). Operator sees a persistent banner in the
  dashboard until pasta is installed.
- On macOS: not applicable — macOS runs unsandboxed (GEP-5 D6) and
  inherits this limitation. Future work (GEP-TBD) can investigate
  pf firewall rules or Network Extension hooks.

This keeps installation friction low (pasta is a `dnf/apt install`
away on every major distro that has Glorbo users) while preventing
a silent security downgrade.

## Decision log

- **D-1 (accept):** Use pasta over slirp4netns. Both provide
  unprivileged netns bridging, but pasta's `--tcp-ports` is a
  first-class feature designed for per-port forwarding; slirp4netns
  requires layered nftables rules to get the same outcome. Pasta is
  also the upstream direction (Red Hat / Kubernetes ecosystem are
  migrating to it).

- **D-2 (accept):** Per-dispatch netns, not per-agent. The netns
  exists only for the lifetime of one `Dispatch.execute/3` run. This
  matches the existing `bwrap` invocation model (one process per
  dispatch) and means netns teardown is free (process exit). Ruled
  out per-agent persistent netns because it requires lifecycle
  tracking we don't have reason to add.

- **D-3 (accept):** The agent-side proxy bind address is
  `127.0.0.222:<PROXY_PORT>`. Arbitrary choice within 127.0.0.0/8
  that's visually distinct from 127.0.0.1 and easy to grep for in
  audit trails. Pasta's forwarding is a simple `--tcp-ports
  <PROXY_PORT>` with a per-netns SNAT to `127.0.0.222`. Using `.1`
  would work but confuses debugging ("is this my host or the sandbox
  seeing 127.0.0.1?").

- **D-4 (accept):** The host-side proxy listener moves to a
  non-default loopback address (e.g. `127.0.0.222`). Even though
  kernel enforcement is the primary defense, obscuring the proxy
  port from the default `127.0.0.1:4000` neighborhood raises the
  bar against accidental collisions with other local services and
  makes netfilter/capture rules clearer ("traffic to 127.0.0.222 is
  the proxy").

- **D-5 (accept, reluctant):** No equivalent enforcement on macOS.
  pasta is Linux-only; macOS lacks user-namespace netns support.
  Document the gap in `docs/verifying-releases.md` and the dashboard
  "degraded sandbox" banner. Future work: evaluate
  `packetfilter`/`NENetworkFilter` on macOS in a dedicated GEP if
  macOS adoption grows.

- **D-6 (reject):** *iptables/nftables in the agent netns.* Works,
  but requires CAP_NET_ADMIN at netns setup. The pasta path uses a
  userspace stack inside the netns, which needs no privilege
  beyond `CLONE_NEWNET` + `CLONE_NEWUSER` (already granted by
  bwrap's `--unshare-user-try`). Keeps the "no suid/root" property.

- **D-7 (reject):** *Blocking all `127.0.0.0/8` from the agent.* We
  want the agent to use the proxy *through* a loopback address, so
  blocking the whole block is too aggressive. Port-level filtering
  via pasta is the right granularity.

- **D-8 (accept):** **Test discipline.** Every `:proxy` integration
  test must include a "can the agent reach 127.0.0.1:4000?" negative
  assertion, verified at `connect()` level (EHOSTUNREACH /
  ECONNREFUSED), not just at the HTTP layer. Prevents regression
  where someone accidentally reintroduces the proxy env var hint
  without the netns enforcement.

- **D-9 (accept):** Existing tests that started Glorbo-flavoured
  companies with `:proxy` agents and relied on them reaching
  127.0.0.1 need to be audited. On-disk mocks stay fine; anything
  that HTTP-calls from the agent process back to a test HTTP server
  on the host breaks — intentionally.

## Load-bearing invariants after this GEP

- **`network: proxy` means "can only reach the proxy".** Policy and
  kernel enforcement converge on the same guarantee.
- **The Glorbo dashboard is unreachable from sandboxed agents.** No
  matter what port it binds to, agents on `:proxy` can't issue
  authenticated or unauthenticated requests to `/mcp` or any web
  route.
- **Proxy allowlist remains the only egress policy.** Everything
  GEP-23 said about how the proxy decides allow/deny/smart stays
  true; GEP-31 just makes the proxy the only path out.

## Migration notes

- Pre-1.0 (≤ v0.0.4): atomic cut, no deprecation window. Existing
  `:proxy` (née `:api_only`) agents get netns enforcement the
  moment they start under a Glorbo build that includes this GEP.
- New `Doctor` check reports pasta status + version. `glorbo
  doctor --fix` cannot install pasta (package-manager action), but
  can print the platform-appropriate install command.
- Company supervisor emits `agent.netns_unavailable` audit event
  once per boot when pasta is missing, so operators know they're in
  degraded mode.

## Rollout phases

1. **Phase A — plumbing (no behavior change):** add pasta detection
   to `Doctor`; plumb a `netns_enforced?: bool` flag through
   `Sandbox.Bwrap.run/2`'s opts; add the `agent.netns_unavailable`
   audit emit. No user-visible behavior yet.

2. **Phase B — enforcement behind a flag:** add `GLORBO_NETNS=1`
   opt-in env var that enables the pasta invocation path for
   `:proxy` agents. Ship behind the flag in one release so users can
   smoke-test without breaking workflows.

3. **Phase C — flip to default:** make netns enforcement the default
   on Linux when pasta is present. `GLORBO_NETNS=0` opts out for
   emergency rollback.

4. **Phase D — drop the flag:** once C has been stable for one
   release, drop `GLORBO_NETNS` entirely. The only knob left is
   "pasta installed or not".

5. **Phase E — macOS investigation:** separate GEP. Evaluates
   `packetfilter` rules as a weaker-but-nonzero substitute.

## Open questions

- **Q1:** Does pasta's `--tcp-ports` accept a host-side IP filter, or
  only a port number? Need to verify whether we can force the
  forward to bind `127.0.0.222` rather than `127.0.0.1` on the agent
  side without extra nft rules. (Reading the man page suggests yes
  via `--map-host-loopback`.)
- **Q2:** Performance overhead of pasta on high-throughput
  scenarios (long-context LLM streaming). Expected negligible
  (<5% vs direct netns) based on Red Hat benchmarks, but needs
  measurement once plumbing lands.
- **Q3:** Interaction with `GEP-27` path requests. Path-request
  file mounts are filesystem-level and unrelated to netns, so no
  interaction expected — confirm with an integration test.
