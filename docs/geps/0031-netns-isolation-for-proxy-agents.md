---
gep: 31
title: "Network-namespace isolation for `:proxy` agents"
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-22
requires: [5, 23]
see-also: [4, 8, 22, 27, 32]
extended-by: [50]
history:
  - date: 2026-04-22
    status: Draft
    note: Initial draft — identifies the loopback-escape gap found during threatmodel work + UAT on 2026-04-22, proposes per-agent netns + pasta as the enforcement mechanism.
  - date: 2026-04-23
    status: Draft
    note: "Tighten rollout semantics: no pre-1.0 flags, Linux `network: proxy` becomes enforced-or-refused, and product framing stays \"security-minded\" rather than \"security tool\"."
  - date: 2026-04-23
    status: Implemented
    note: "Implementation landed on the same day: Linux `network: proxy` now wraps `bwrap` in `pasta --splice-only` with only the proxy port forwarded, doctor checks `pasta`, and proxy dispatches are refused when the prerequisite is missing."
  - date: 2026-04-23
    status: Implemented
    note: "Pasta probe tightened: `Glorbo.Sandbox.Bwrap.pasta_availability/0` + doctor's `check_pasta/1` + test-helper `pasta_available?/0` now all scan `pasta --help` for `--splice-only` before declaring pasta usable. Older `passt` packages (e.g. the one on GHA ubuntu-24.04) answer `pasta --version` fine but don't recognise `--splice-only`, which silently broke proxy dispatch and caused integration-test diff noise. Now doctor flags the upgrade requirement explicitly and integration tests skip cleanly on hosts that predate the flag."
  - date: 2026-07-10
    status: Implemented
    note: "CI and release gates now build upstream passt tag `2026_06_11.a9c61ff` from source because Ubuntu 24.04's packaged pasta lacks `--splice-only`; the pinned build and exact-path AppArmor userns profiles for bwrap/pasta keep the proxy-netns security integration tests active instead of silently skipping or failing under the runner's userns restriction."
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

## Product posture

Glorbo is **not** a hardened security product or a multi-tenant
containment system. It is a user-friendly local automation tool that
tries to stay security-minded and honest about its boundaries.

That framing cuts *toward* stricter semantics here, not away from
them. A friendly tool should not present `network: proxy` as if it
were a boundary when it is only a convention. After this GEP,
`network: proxy` on Linux should either mean "proxy-only, kernel-
enforced" or be unavailable. No silent downgrade, no rollout flag,
no "best effort" wording standing in for a real guarantee.

## Design

Use **`pasta` (from the `passt` project)** as the userspace network
stack for each agent on `network: proxy`. Pasta is designed for
unprivileged per-process netns bridging and supports port-level
allowlisting.

### Implemented architecture

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
           │  127.0.0.1:<PROXY_PORT> ◄ pasta     │
           │  HTTPS_PROXY=http://127.0.0.1:<P>   │
           │                                     │
           │  (nothing else reachable)           │
           └─────────────────────────────────────┘
```

1. `Agent.Dispatch` resolves the per-company proxy listener and passes
   its loopback URL into `Glorbo.Sandbox.Bwrap.start/2`.
2. On Linux, `Bwrap.start/2` normalizes that URL to
   `http://127.0.0.1:<PROXY_PORT>` and launches `/bin/sh` via
   `pasta -q -f --runas <uid>:<gid> --splice-only -t none -u none -T <PROXY_PORT> -U none -- ...`.
3. `pasta --splice-only` creates a private netns with loopback-only
   forwarding; the only reachable host listener is the forwarded proxy
   port.
4. `bwrap` still owns the filesystem sandbox inside that netns. We do
   not replace bwrap; we wrap it.
5. Any direct `connect(127.0.0.1, other_port)` from the agent fails,
   while `curl --proxy "$HTTPS_PROXY"` still reaches the Glorbo proxy.

### Fallback when `pasta` isn't installed

`Glorbo.Sandbox.Unsandboxed` (added by GEP-5 D7 for macOS) already
establishes the pattern of "refuse to start protected dispatches
and audit a degraded-mode event" when the kernel primitives are
absent. Mirror it: the `Doctor` check adds `pasta --version`, and if
unavailable:

- On Linux: `network: proxy` dispatches are **refused**. Emit an
  `agent.netns_unavailable` audit event, surface a loud doctor
  warning/install hint, and tell the operator to install `pasta`.
  `network: none` and `network: open` remain available.
- On macOS: not applicable — macOS runs unsandboxed (GEP-5 D6) and
  inherits this limitation. Future work (GEP-TBD) can investigate
  `pf` firewall rules or Network Extension hooks, but this GEP does
  not promise equivalent enforcement there.

This is deliberately fail-closed. Glorbo is not trying to sell
"security theater"; if a policy sounds like a boundary, the runtime
should either enforce it or refuse it.

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

- **D-3 (accept):** Keep the agent-side proxy address at
  `127.0.0.1:<PROXY_PORT>`. The important property is "only this port
  is forwarded", not "special loopback IP". A standard loopback
  address keeps CLI/tool compatibility simple and matched the real
  `pasta` behaviour validated during implementation.

- **D-4 (reject):** Move the host-side proxy listener to a special
  loopback alias such as `127.0.0.222`. Rejected as unnecessary once
  `pasta --splice-only -T <PROXY_PORT>` proved sufficient: kernel
  enforcement comes from the private netns and single-port forwarding,
  not from obscuring the host-side bind address.

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

- **D-10 (accept):** **No rollout flags pre-1.0.** Linux
  `network: proxy` semantics change atomically from "advisory env
  vars" to "enforced via netns+pasta or refused". Ruled out staged
  `GLORBO_NETNS=1/0` rollout because it prolongs misleading policy
  semantics and adds a second runtime path we already know we want
  to delete.

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

- Pre-1.0: atomic cut, no deprecation window and no rollout flags.
  Existing `:proxy` (née `:api_only`) agents switch from advisory
  behavior to enforced-or-refused the moment they run under a build
  that includes this GEP.
- On Linux, hosts that run `network: proxy` agents must have
  `pasta` installed. Missing `pasta` is a hard prerequisite failure
  for those dispatches, not a degraded fallback to shared-netns
  behavior.
- New `Doctor` check reports `pasta` status + version and can print
  the platform-appropriate install command, but it does not install
  packages itself.
- `Agent.Dispatch` emits a once-per-company `agent.netns_unavailable`
  audit event when Linux `network: proxy` dispatches are refused for a
  missing `pasta` prerequisite, so the operator sees a concrete failure
  instead of a silent downgrade.

## Implementation shape

1. Add `pasta` detection to `Doctor` and fail closed for Linux
   `network: proxy` dispatches when it is missing.
2. Extend the `bwrap` launcher so `:proxy` wraps the existing bwrap
   command in `pasta --splice-only` with only the proxy port exposed.
3. Rewrite the proxy integration tests to assert negative reachability
   of host loopback services, not just happy-path proxy use.
4. Update dashboard/docs copy so `network: proxy` is described as
   enforced on Linux and unavailable there when prerequisites are
   missing.

## Open questions

- **Q1:** Performance overhead of pasta on high-throughput
  scenarios (long-context LLM streaming). Expected negligible
  (<5% vs direct netns) based on Red Hat benchmarks, but needs
  measurement once plumbing lands.
- **Q2:** Interaction with `GEP-27` path requests. Path-request
  file mounts are filesystem-level and unrelated to netns, so no
  interaction expected — confirm with an integration test.

## Implementation reconciliation (2026-06-14)

This is an append-only record (GEP-1: an Accepted/Implemented GEP's body is not rewritten in place; deviations from the original text are recorded here instead).

- **D-8 loopback-unreachability test runs only when `pasta --splice-only` is present, which CI lacks — known-gap.** GEP D-8 (lines 202–207) mandates a `connect()`-level negative assertion that the agent cannot reach `127.0.0.1:4000` on every `:proxy` integration test. The only such test is `test/integration/sandbox_network_proxy_test.exs:133` ("IP2"), and the whole module is load-time-gated by `@moduletag skip` when `BwrapHelpers.pasta_available?/0` is false (lines 19–21). CI runs on `ubuntu-24.04` (.github/workflows/ci.yml:39) with no `passt`/`pasta` install step anywhere under `.github/`, so this security invariant is never exercised in CI — it skips cleanly and gates nothing. Confirmed; fix is to install a `passt` with `--splice-only` in CI or add a unit-level argv assertion of the `pasta --splice-only -T <port>` launcher line.

- **Fail-closed `agent.netns_unavailable` refusal path has zero test coverage — known-gap.** The GEP's fail-closed guarantee (lines 143–154, 247–250, Implementation shape #1) is implemented in `lib/glorbo/agent/dispatch.ex`: `proxy_netns_unavailable?/1` (1345–1348) refuses Linux `network: proxy` dispatch with `{:error, :netns_unavailable}` and emits a once-per-company `agent.netns_unavailable` audit via `emit_netns_unavailable_audit_once/1` (1406–1429) when `Bwrap.pasta_availability/0` is not `:ok` (1311–1313). A `grep -rn netns_unavailable test/` returns zero matches — neither the refusal return value, the short-circuit (no `Bwrap.start` call), nor the single-audit-emission behavior is tested. Confirmed; fix is a dispatch-level unit test stubbing `pasta_availability/0` to `{:error, :unavailable}` on a `linux?()` host and asserting the `{:error, :netns_unavailable}` return plus exactly one audit entry.
