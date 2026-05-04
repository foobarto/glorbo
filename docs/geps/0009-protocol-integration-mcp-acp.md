---
gep: 9
title: Protocol-Level Integration — MCP, ACP
author: Glorbo Maintainers <security@example.invalid>
status: Accepted
type: Informational
created: 2026-04-17
requires: [2, 4, 5]
see-also: [8]
extended-by: [29, 45]
history:
  - date: 2026-04-17
    status: Draft
    note: Forward-looking GEP. Captures the direction Glorbo would take for bidirectional / long-running / shared-runtime agent workflows if they become necessary. No implementation commitment.
  - date: 2026-04-22
    status: Accepted
    note: |
      Transitioned per D4. GEP-29 (Glorbo as MCP Server) is the first
      concrete Standards GEP built on this direction — covers the
      server side (Glorbo as MCP server over HTTP-SSE). This GEP
      remains the direction record; GEP-29 carries the implementation
      decisions.
---

# GEP-9: Protocol-Level Integration — MCP, ACP

## Purpose

Glorbo currently dispatches agents as **per-task, fire-and-forget**
CLI subprocesses under bwrap (GEP-4, GEP-5). That shape handles the
vast majority of workflows the product targets — a Director assigns
a task, an agent wakes, works, produces a reply file, exits. No
streaming, no co-presence, no shared runtime.

If and when workflows emerge that don't fit that shape — real-time
bidirectional interaction, long-running agents holding context over
minutes or hours, agent-to-agent direct dialogue with its own
protocol semantics — the answer is **protocol-level integration**,
not a return to container-hosted long-lived runtimes.

This GEP exists to record that direction so future readers
encountering "we need agents to do X that doesn't fit per-task
dispatch" don't reach for the wrong tool. It is deliberately
speculative: **no commitment to implement**. Think of it as a signpost.

## What this GEP does NOT do

- Does not propose an implementation.
- Does not commit to a specific protocol, timeline, or milestone.
- Does not describe an API surface.
- Does not authorise code changes.

A concrete MCP or ACP integration would be a separate Standards GEP
with its own design, migration plan, and decision log.

## The gap being named

Per-task dispatch is sufficient when:

- Each agent invocation is a complete unit of work.
- The Director (or another agent) asks, the agent replies, done.
- Context that matters gets written back to `agent.md` or task
  artifacts so the next invocation can read it.

Per-task dispatch is insufficient when:

1. **Bidirectional streaming.** The Director wants to say "stop,
   try this instead" while the agent is still thinking. The CLI
   tool already supports this kind of interactive loop, but Glorbo's
   per-task shape throws it away — the agent runs to exit before
   anyone can interject.
2. **Long-running presence.** An agent that watches an event stream
   (a log, a chat channel, an external API) and reacts over minutes
   or hours. Spawning and tearing down a CLI for every event is
   wrong shape; the agent should stay up.
3. **Agent-to-agent dialogue with protocol semantics.** Agents
   already exchange messages via inbox/outbox, but those are
   asynchronous file drops routed by Elixir. Some workflows —
   negotiation, delegation with acknowledgement, structured
   handoffs — want synchronous call-and-response with typed
   schemas.
4. **Shared tool servers.** A tool (retrieval, search, structured
   data access) that multiple agents call. In per-task dispatch,
   each agent's CLI re-initialises its own tool state; a shared
   tool server lets many agents hit the same warm backing.

None of these are current requirements. Glorbo's roadmap doesn't
have features that depend on them. This GEP is the placeholder for
if that changes.

## Candidate protocols

### MCP — Model Context Protocol

[Model Context Protocol](https://modelcontextprotocol.io) is an
Anthropic-initiated open standard that the major CLI tools already
speak natively:

- **Claude Code** — first-class MCP server + client support.
- **Gemini CLI** — MCP-compatible.
- **Codex CLI** — MCP support shipping.
- **OpenCode, Hermes, and other OSS tools** — generally MCP-aware.

MCP defines a client-server shape where an MCP **client** (the LLM
CLI) can call tools and resources exposed by MCP **servers**. Servers
are long-lived processes; clients are per-invocation. The split is
orthogonal to Glorbo's dispatch model — Glorbo could be an MCP
server exposing resources (inbox, outbox, channels, audit log) that
agents' CLI tools connect to as clients.

**What MCP would buy Glorbo:**

- **Shared tool servers.** An "inbox-reader" MCP server that lets any
  agent read its own inbox via a standard protocol, rather than
  bind-mounting directory paths.
- **Typed resource access.** Replace "here's a mounted directory" with
  "here's a resource URL with a schema." Better for agents that want
  structured metadata about what's available.
- **Reuse of upstream CLI plumbing.** Every supported CLI already
  knows how to talk to MCP servers. Glorbo doesn't have to invent a
  new protocol.

**Hazards:**

- MCP is young; the spec is evolving. Premature commitment risks
  churn.
- Adds a new process type (MCP server) to the supervision tree.
- Tooling around authN/authZ for MCP servers is still settling;
  Glorbo would have to be careful not to leak across agent
  boundaries.

### ACP — Agent Communication Protocol (speculative)

"ACP" is a placeholder term for whatever agent-to-agent protocol
standard emerges. As of this GEP's creation there is no single
dominant standard; candidates include:

- Anthropic's own extensions to MCP for multi-agent coordination.
- IBM's Agent Communication Protocol work.
- W3C-style standardisation efforts that may or may not crystallise.

Glorbo is not tracking a specific one. The category exists; the
standard does not yet.

**Point is:** when Glorbo needs to route messages between agents as
structured protocol calls rather than file drops, that's an ACP-shape
problem. We'd adopt whatever's winning in the ecosystem at that
point rather than inventing Glorbo-specific wire format.

## Why protocols, not containers

The natural question: "isn't a long-lived agent runtime what Podman
would have given us? Didn't we reject that in GEP-5?"

Yes and no:

- **What Podman offered:** per-company persistent container hosting
  a Python worker that dispatches to LLM providers via SDKs.
- **What protocols offer:** a wire format over which existing CLI
  tools can speak, with servers that can be written in any language
  and run as ordinary supervised processes — Elixir GenServers, for
  instance.

The Podman plan entangled three separable things: (a) a persistent
runtime, (b) a Python dependency layer, and (c) a container boundary.
A protocol-based approach unbundles them: persistent servers in
Elixir (no Python), speaking a standard protocol (no custom SDK),
without needing a container runtime (no image maintenance).

If Glorbo ever grows the need for long-lived agent presence, protocol
servers running as ordinary Elixir processes — supervised,
hot-code-upgraded, crash-isolated by OTP — are a cleaner fit than
containers.

## Relationship to the current design

- **GEP-2** (architecture) stays intact. MCP/ACP would be a new layer,
  not a replacement for any pillar.
- **GEP-4** (CLI-wrapping) stays intact. CLIs still drive agent
  behaviour; MCP is orthogonal to how they're invoked.
- **GEP-5** (bwrap sandboxing) stays intact. MCP servers run as
  Glorbo processes on the host; CLI clients still sandbox under
  bwrap for their per-invocation work.
- **GEP-8** (provider registry) stays intact. An agent's provider is
  still "which CLI tool dispatches this agent."

Nothing in the current architecture precludes MCP adoption. When it
becomes useful, a new Standards GEP will work out the implementation.

## Signals that would motivate a concrete proposal

This GEP becomes action-worthy if one of these shows up in the
roadmap:

- A feature asking for real-time dashboard ↔ agent co-piloting (user
  types, agent reacts mid-stream).
- An agent that needs to subscribe to an external event stream with
  sub-second latency.
- Multi-agent workflows where structured negotiation (not file-drop
  message passing) is the natural shape.
- A shared expensive tool (embeddings index, retrieval backend) that
  several agents want to share state across.

Until one of those lands, the per-task CLI model is enough.

## Decision log

### D1. Future bidirectional needs routed to protocols, not containers

- **Decided:** when Glorbo needs long-lived agent presence or
  bidirectional interaction, the design direction is protocol-level
  integration (MCP and ACP-shape standards), not a return to
  container runtimes.
- **Alternatives:** reintroduce Podman with a long-lived worker;
  build a custom Glorbo-specific wire protocol; keep per-task
  dispatch even for poorly fitting workflows.
- **Why:** containers would re-introduce the complexity GEP-5 D6
  rejected (image maintenance, bootstrap, Silverblue-unfriendly
  cache) without solving the "how do agents talk" problem — they'd
  just give us a place to run a long-lived process. Protocols give
  us the wire format directly, work with existing CLIs, and can be
  hosted as ordinary supervised Elixir processes. A custom Glorbo
  protocol would be yet another standard to maintain; MCP already
  has the ecosystem.

### D2. No commitment to implement

- **Decided:** this GEP is speculative and forward-looking. No
  implementation work is authorised by its acceptance.
- **Alternatives:** commit to MCP support in v0.0.3 or v0.1; defer
  the GEP entirely until a concrete need arises.
- **Why:** premature implementation risks building against a spec
  that's still settling. But not having the direction captured
  anywhere risks future readers (or future me) reaching for the
  wrong tool when an actual bidirectional need shows up. A Draft
  Informational GEP is the right shape: it says "this is where
  we'd go, if/when."

### D3. Name MCP specifically, leave ACP as a placeholder

- **Decided:** MCP is named with concrete vendor support; ACP is
  named as a category, not a specific protocol.
- **Alternatives:** avoid naming any protocol; commit to a specific
  ACP standard now.
- **Why:** MCP is real, deployed, and the major CLIs Glorbo wraps
  speak it. Treating it as a concrete candidate is honest. ACP is
  genuinely unsettled; pretending to pick one would be false
  precision. Naming the category reserves the conceptual slot.

### D4. Keep the GEP as Draft indefinitely until a concrete need arises

- **Decided:** the GEP stays `status: Draft` until the signals in
  §"Signals" appear. At that point, a new Standards GEP proposes a
  concrete implementation, and this GEP transitions to Accepted (as
  the retroactive design rationale) or Superseded (if the new GEP
  does different things).
- **Alternatives:** accept now; let it go stale in Draft.
- **Why:** accepting a speculative GEP sets expectations this GEP
  explicitly disclaims ("no implementation commitment"). Draft is
  the honest status for "direction we'd take if." Stale Draft GEPs
  are fine in the repo — they document considered directions.

## Related

- **GEP-2** — architecture overview; this GEP is an opt-in extension,
  not a modification.
- **GEP-4** — CLI-tool agents; MCP clients are the CLIs Glorbo
  already dispatches, so this composes rather than replacing.
- **GEP-5** — bwrap sandboxing; explicitly names protocol-level
  integration as the preferred answer to future bidirectional
  needs instead of returning to a container tier. D6 in that GEP
  is the sibling decision to this one.
- **GEP-8** — provider registry; unaffected by MCP adoption. Each
  provider is still "a CLI tool that gets invoked."
- [Model Context Protocol specification](https://modelcontextprotocol.io)
  — the concrete standard this GEP names.
