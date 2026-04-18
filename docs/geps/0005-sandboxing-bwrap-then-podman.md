---
gep: 5
title: Sandboxing — bwrap
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Informational
created: 2026-04-17
implemented-in: v0.0.1
requires: [2]
see-also: [3, 4, 9, 12]
extended-by: [16]
history:
  - date: 2026-04-17
    status: Draft
    note: Initial retrofit from DESIGN.md §4.4 and §7. Original framing was two-tier (bwrap + Podman).
  - date: 2026-04-17
    status: Accepted
    note: Two-tier framing accepted, then immediately reconsidered on the same day (see next entry).
  - date: 2026-04-17
    status: Accepted
    note: Revised in-place under the GEP-1 bootstrap carve-out to drop the planned Podman tier. The Python-worker justification that carried Podman's value died with the CLI-wrapping pivot (GEP-4); see §"Why Podman was considered and dropped" and D6. Bidirectional / long-running agent needs are routed to GEP-9 (MCP/ACP direction) rather than containers.
  - date: 2026-04-17
    status: Implemented
    version: v0.0.1
    note: bwrap is the sole kernel-layer isolator and has been since v0.0.1 shipped. Status flipped to Implemented now that the Podman overhang is gone.
---

# GEP-5: Sandboxing — bwrap

## Purpose

Glorbo enforces agent permissions at the **kernel layer**, not just in
application code. This GEP records the sandboxing story: `bwrap` mount
namespaces are the sole kernel-layer isolator. The original plan
carried a second tier (Podman containers) inherited from the
pre-pivot architecture; that tier is no longer in scope — see
§"Why Podman was considered and dropped" and GEP-9.

This is Informational — it documents the decisions shipped in
v0.0.1 and still correct in v0.0.2.

## The principle: permissions enforced below the application

Every `agent.md` declares permissions in a three-part syntax
(`resource:action:scope`). Enforcement happens at **two layers**:

1. **Application.** The Elixir Router validates every cross-directory
   message transfer, approval gate, and tool invocation against the
   declaration.
2. **Kernel.** The Linux kernel makes the declaration physically
   true. The filesystem an agent can see is exactly the filesystem
   the agent is allowed to touch — via bwrap mount namespaces.

The two layers are not redundant; they fail independently. An
application-layer bug that lets a malformed request through still
hits a kernel layer that refuses to serve files outside the mount
view. A kernel-layer misconfiguration still has application checks
above it. Defence in depth.

Contrast: a typical web service that enforces auth only in
application code. If app code has a hole, every row in the DB is
reachable. Glorbo's model makes "everything mounted = everything
allowed"; the sandbox view *is* the permission grant.

## bwrap as the kernel layer

[`bwrap` (bubblewrap)](https://github.com/containers/bubblewrap) is
the kernel-layer isolator. It's suid-root on most Linuxes (or
userns-based on Fedora/Silverblue), and produces an unprivileged
sandbox tree from a set of namespace flags + bind mounts.

### Shape of an invocation

Every CLI-tool invocation runs in a **fresh** bwrap tree that dies
with its parent. No standing sandbox, no long-lived namespace, no
privileged daemon. The tree is built from the agent's
`permissions:` and `network:` declarations and torn down at exit.

**Base namespaces (every invocation):**

- `--die-with-parent` — sandbox dies when the Elixir process dies.
- `--unshare-user-try --unshare-ipc --unshare-pid --unshare-uts
  --unshare-cgroup-try` — full namespace isolation.
- `--new-session --cap-drop ALL` — no capabilities, no terminal
  inheritance.
- `--proc /proc --dev /dev --tmpfs /tmp` — minimum viable kernel
  interface.

**Filesystem view (derived per agent):**

```
--ro-bind /usr /usr   (and /bin /lib /lib64 /etc)
  → CLI tools and system libraries are visible, read-only.
--bind <co>/agents/<me>/workspace /workspace
  → agent's scratch space, read/write.
--ro-bind <co>/agents/<me>/inbox /inbox
  → agent's own queue, read-only.
--bind <co>/agents/<me>/outbox /outbox
  → agent's own outbox, write (effectively write-only in practice).
--ro-bind <co>/projects /projects              # if projects:read:*
--bind    <co>/projects/<name> /projects/<name>  # if projects:write:<name>
--ro-bind <co>/channels /channels              # if chat:read:*
```

**Critical property:** anything not in the mount list is not in the
sandbox's view of the filesystem. Sibling agents' directories are not
mounted. Other companies' directories are not mounted. The host home
is not mounted. `ls /` inside the sandbox shows only what was
explicitly bind-mounted.

### Network policy

Three levels, declared per-agent:

- **`network: none`** (default) — `--unshare-net`. The sandbox has no
  network namespace inheritance. Kernel-enforced: the agent literally
  has no IP stack.
- **`network: api-only`** — shared netns + `HTTP_PROXY`/`HTTPS_PROXY`
  pointing at a Glorbo-managed allowlist CONNECT proxy. The proxy
  only permits hosts in the agent's declaration. v0.0.1 is
  advisory-only at the kernel layer (a determined agent could ignore
  `HTTP_PROXY`); a netns + nftables hardening iteration is planned.
- **`network: open`** — host netns inherited (no `--unshare-net`).
  Explicit opt-in; no sandboxing at the network layer.

### Company isolation by construction

Agents belonging to company A never have company B's directory
mounted in their sandbox. There is no path *inside* the sandbox that
could reach another company's data. Enforcement is "the mount simply
doesn't exist," which is stronger than any application-level check.

### Why bwrap is the right fit

- **No daemon, no root service, no moving parts.** Every invocation
  is a fresh short-lived process tree. A daemon-less model matches
  Glorbo's "one binary, one directory" philosophy.
- **Fast.** Sandbox creation is sub-10ms on modern kernels. Agents
  spawn and exit per task; this wouldn't be practical with
  container-startup overhead.
- **Low system dependencies.** `bwrap` is packaged in every major
  distro and builds cleanly from source. Container runtimes are
  heavier to bootstrap and have cgroup/systemd dependencies that
  complicate Silverblue-style installations.
- **Per-invocation config.** Mounts are derived from agent
  declarations at invocation time. There's no "image" to rebuild.

## Why Podman was considered and dropped

The original architecture (pre-GEP) planned a **second tier** of
isolation: per-company Podman containers, per-agent Linux users
inside, POSIX ACLs enforcing permissions on the mounted company
directory. The v0.0.3 roadmap was to "restore the container runtime"
and run the Python agent worker inside it.

That plan carried over two assumptions:

1. **Glorbo would ship its own Python agent runtime** (`glorbo-runtime`
   OCI image with `litellm`, `anthropic`, `openai`, `ollama`, …) as
   the primary dispatch mechanism.
2. **Per-agent Linux users + ACLs** offered meaningfully stronger
   isolation than bwrap's mount-namespace approach.

GEP-4 (CLI-wrapping pivot) invalidated the first assumption: Glorbo
doesn't ship an LLM client; it wraps existing CLIs. There is no
Python runtime to host.

The second assumption survives on its own merits but is weaker:
bwrap's mount-list-is-the-grant model already prevents unauthorised
filesystem access. Swapping to ACLs buys a more conventional identity
story (real Linux UIDs per agent) but no new enforcement property —
the permission gate is already physical.

With the Python-worker rationale gone and ACL benefits marginal for
the current single-user Director model, the Podman tier stops being
worth the cost (image maintenance, bootstrap complexity,
Silverblue-unfriendly cache, philosophy drift from "one binary, one
directory"). **Podman is dropped.** See D6 for the full rationale.

Future bidirectional / long-running agent needs — the kinds of
workflow that might once have motivated a persistent container
runtime — are expected to be answered by **protocol-level
integration** (MCP, ACP) rather than a container tier. See GEP-9.

## What the sandbox does NOT do

- **It does not validate prompts.** An agent's sandbox permissions
  restrict what the agent's filesystem writes can touch; they don't
  restrict what the agent *thinks* or *decides*. Prompt-injection or
  malicious task content is an application-layer concern.
- **It does not prevent resource exhaustion.** An agent with
  workspace write access can fill its workspace. Disk quotas and
  budget caps (application-layer) catch this, not the sandbox.
- **It does not protect against kernel vulnerabilities.** bwrap
  relies on correct kernel namespace implementations. A kernel bug
  breaks the sandbox. This is an accepted single-point-of-failure —
  Glorbo's threat model doesn't include nation-state attackers with
  kernel 0-days.
- **It does not isolate CPU or memory.** cgroups are available and
  could be wired in, but this is not done in v0.0.1/v0.0.2.

These are in-scope for future GEPs, not for this one.

## Relationship to the other invariants

- **Filesystem as source of truth (GEP-3):** the sandbox's mount view
  *is* the permission enforcement. Because the authoritative state is
  files, kernel filesystem permissions are the enforcement
  mechanism. This composition only works because Glorbo put user
  state on disk rather than in SQLite.
- **CLI-tool agents (GEP-4):** every CLI subprocess runs inside the
  bwrap sandbox. Auth directories are bind-mounted read-only; session
  writes are redirected to the agent's workspace via env-var
  override. The sandbox is what makes per-agent auth isolation
  possible despite a single host-level login per provider.
- **Inbox/outbox flow (GEP-2 pillar 4):** agents can't reach each
  other's inboxes because the bind-mount list doesn't include them.
  Cross-agent transfer is physically impossible without going through
  the Elixir Router.

## Decision log

### D1. Two-tier enforcement (application + kernel)

- **Decided:** permissions in `agent.md` are enforced both by Elixir
  application code and by the kernel (bwrap mounts).
- **Alternatives:** application-only checks; kernel-only (no
  application validation); rely on LLM-level prompt restrictions.
- **Why:** layered enforcement fails independently. A bug in the
  Router still hits the kernel layer; a misconfigured sandbox still
  hits the Router. Application-only is fragile (one bug == breach);
  kernel-only provides bad error messages to operators. Prompt-level
  "restrictions" are suggestions and have no enforcement properties
  at all.

### D2. bwrap, not containers

- **Decided:** v0.0.1 ships with bwrap as the sole kernel-layer
  isolator, not Podman/Docker.
- **Alternatives:** start with Podman (the pre-pivot plan); use
  chroot; use unprivileged user namespaces directly; firejail.
- **Why:** bwrap is fast (sub-10ms sandbox creation), daemon-less,
  and ships in every major distro. Containers add startup overhead
  that matters when agents spawn per-task. Chroot is insufficient
  for network isolation. Firejail has a more complex model than we
  need. Direct userns is bwrap without the helpful wrapper. bwrap
  hits the sweet spot for Glorbo's use case.

### D3. Per-invocation sandboxes, not long-lived

- **Decided:** every agent task creates a fresh bwrap tree that
  dies with the Elixir parent.
- **Alternatives:** a long-lived sandbox per agent, reused across
  invocations.
- **Why:** fresh sandboxes eliminate state leakage between tasks.
  Cost (sandbox creation overhead) is negligible at bwrap's speed.
  Simplifies mental model: "each task is isolated in space and
  time." If rapid-fire streaming ever motivates something longer-
  lived, protocol-level options (GEP-9) are a better fit than
  standing containers.

### D4. Network as declarative, kernel-enforced for `none`

- **Decided:** `network: none` sets `--unshare-net`, kernel-enforced.
  `network: api-only` is advisory via `HTTP_PROXY` in v0.0.1, with
  netns + nftables hardening planned.
- **Alternatives:** always open network; always via proxy; require
  per-host proxy; firewall at the host level.
- **Why:** "no network" is a common case (most agents don't need
  internet) and deserves the strongest available enforcement. API-
  allowlist is a real use case but kernel-level enforcement requires
  a per-invocation netns + nftables ruleset, which is heavier. The
  advisory tier ships with v0.0.1 as a pragmatic trade-off; the
  hardening iteration is queued.

### D5. Company isolation via non-mount, not via ACL

- **Decided:** company A agents do not have company B's directory in
  their sandbox mount list at all.
- **Alternatives:** mount everything, enforce via ACL or application
  checks; mount read-only and rely on write-protect; use SELinux
  labels.
- **Why:** "not mounted" is the strongest possible isolation — there
  is no path inside the sandbox that could reach another company's
  data. Mounts + ACLs add a moving part that can be misconfigured.
  SELinux adds a platform dependency (no SELinux on Silverblue,
  limited on distroless systems).

### D6. Drop the planned Podman tier

- **Decided:** the originally planned v0.0.3 Podman tier is removed
  from the architecture. bwrap remains the sole kernel-layer
  isolator. `glorbo-runtime` image, per-agent Linux users,
  per-company persistent containers — all off the roadmap.
- **Alternatives:** keep the v0.0.3 Podman restoration plan as-is;
  demote to an optional "v0.1+ multi-tenant deployment" mode; re-
  scope to a smaller container-based hardening story without the
  Python runtime.
- **Why:** the principal justification for Podman was hosting a
  Python agent runtime (`litellm` dispatch to anthropic/openai/
  ollama/huggingface). GEP-4's CLI-wrapping pivot removed that need
  entirely — Glorbo does not run Python and does not dispatch via
  SDKs. Without the Python worker, Podman's remaining benefits
  (per-agent Linux users, bundled CLI image, persistent per-company
  runtime) are nice-to-have but do not justify the maintenance cost
  of an OCI image, image cache directory, bootstrap complexity on
  Silverblue-style hosts, and divergence from "one binary, one
  directory" philosophy. Future bidirectional or long-running agent
  needs — the strongest remaining argument for persistent runtime —
  are better answered at the protocol layer (MCP / ACP; see GEP-9)
  than at the container layer.

### D7. Leave room for containers if a genuine need arises

- **Decided:** dropping Podman is a product decision, not a ban.
  A future deployment scenario (multi-user shared host, team
  co-location, hardened untrusted workload) can re-introduce
  containers via a dedicated GEP that supersedes this one.
- **Alternatives:** ban containers outright; commit to never
  adding them.
- **Why:** decisions aren't permanent; the record of why we made
  them is. If an actual use case justifies containers, revisiting
  via supersession is cheap. Banning outright would be posture,
  not engineering.

## Related

- **GEP-2** — architectural overview (see "The kernel is the policy
  engine" pillar).
- **GEP-3** — filesystem as source of truth (composition of filesystem
  authority + filesystem permissions).
- **GEP-4** — CLI-tool agents (every CLI invocation runs inside this
  sandbox; the pivot that removed Podman's main justification).
- **GEP-9** — protocol-level integration (MCP / ACP) for future
  bidirectional and long-running agent needs.
- `DESIGN.md` §4.4 — the living reference; historical Podman content
  preserved with a reversal note at the top.
- Git history (pre-2026-04-17) — `.planning/deferred/container-
  runtime-v0.0.2/` contained the detailed restoration plan that this
  GEP's D6 reversed. Use `git log --all --diff-filter=D --
  .planning/deferred/` to recover the file list if needed.
