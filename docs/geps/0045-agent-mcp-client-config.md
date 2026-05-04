---
gep: 0045
title: Agent-level MCP-server consumer config injection (Stado as validation target)
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-05-04
requires: [4, 5, 8]
see-also: [9, 23, 29]
history:
  - date: 2026-05-04
    status: Draft
    note: |
      Initial draft after the htb-writeups dogfood pass surfaced
      stado-as-MCP-server as the preferred integration shape over a
      stado-as-CLI-provider adapter. Captures the decision tree the
      design has to walk: schema field, sandbox bind extension, per-
      CLI config-injection format, lifecycle (long-running vs.
      stdio-spawned). Phase 0 = this GEP; implementation deferred
      to Phase 1+.
---

# GEP-45: Agent-level MCP-server consumer config injection

## Problem

Glorbo agents are spawned as one-shot CLI subprocesses
(`claude-code`, `codex`, `gemini-cli`, `opencode`) under bwrap, with
the per-CLI auth dir (`~/.claude/`, `~/.codex/`, etc.) bound into the
sandbox so the CLI sees its own config. Each of those CLIs can
*itself* talk to MCP servers — claude-code reads
`~/.claude/settings.json`'s `mcpServers:` block, codex reads
`mcpServers` in `~/.codex/config.toml`, etc. — but the auth-bind
mechanism only binds the auth dir read-only. A user who adds an MCP
server entry to their host config sees:

  * **The settings file inside the sandbox is correct** (it's the
    same file, ro-bound).
  * **Spawn fails.** Claude Code (and friends) try to launch the
    declared MCP server as a subprocess (`stado mcp-server`,
    `npx -y @modelcontextprotocol/server-postgres`, etc.). The
    binary is absent from the sandbox PATH, and the MCP server's
    own config dir (`~/.config/stado/`, `~/.npm/`) isn't bound.
  * **Network is wrong.** `network: loopback` doesn't reach an
    HTTP-SSE MCP server bound to `127.0.0.1:<port>` on the host.
    `network: proxy` blocks raw TCP. The agent can only reach
    host-local services via specific bind extensions, and
    glorbo doesn't currently express that.

The dogfood report from the htb-writeups workflow integration:

> "stado isn't in [glorbo's provider list] yet... Either: Add a
> stado provider adapter (matches the pattern of codex, gemini in
> glorbo). Or expose stado as MCP and have glorbo agents talk to
> it via MCP."

User preference (memory note 2026-05-04):

> "tbh best way to use stado is with MCP or ACP rather than via
> stdio prompt"

So the answer is path 2 — but path 2 is currently impossible without
new glorbo-side scaffolding for "the agent talks to an external MCP
server."

This GEP designs that scaffolding. Stado is the validation case;
the mechanism is generic.

## Non-goals

- **Not a stado-specific provider adapter.** GEP-8's CLI provider
  pattern (codex, gemini-cli) is the wrong shape per the user's
  preference and the dogfood note's framing.
- **Not a replacement for GEP-29.** GEP-29 covers Glorbo *as* an
  MCP server (consumed by external clients). This GEP is the
  symmetric direction: Glorbo agents *as* MCP clients to external
  servers.
- **Not a replacement for the in-tree MCP tools.**
  `lib/glorbo_web/mcp/tools/` is the inbound surface; agents
  outbound to other MCP servers is what this GEP adds.
- **Not changing the CLI provider mechanism.** Agents still pick
  `provider: claude-code` (or any other GEP-8 provider). MCP
  servers are an additive layer on top.

## Proposal

### Schema — `mcp_servers:` field on `AGENT.md`

`agent/v1` gains an optional `mcp_servers:` field — a list of named
MCP server kits the agent should be wired up with. Each entry is a
string referencing an entry in a new MCP-server registry.

```yaml
---
kind: agent/v1
slug: ceo
provider: claude-code
network: loopback
mcp_servers:
  - stado
  - postgres-readonly
---
```

The AGENT.md key order grows by one slot (after `skills`, before
`permissions`). FileSpec validator rejects unknown values with a
diagnostic listing available kits. Empty list (or absent field)
means no external MCP servers — current behavior.

### Registry — `priv/mcp_servers/<name>.toml`

Each MCP server kit declares everything the sandbox needs:

```toml
# priv/mcp_servers/stado.toml
name        = "stado"
description = "Stado bundled toolset over MCP (webfetch, ripgrep, ast-grep, fs, lsp)"

# How the CLI launches the MCP server. `stdio` = client spawns the
# binary as a subprocess and talks JSON-RPC over stdin/stdout (the
# canonical MCP transport). `http` = HTTP-SSE; the binary runs
# long-running on the host, sandbox forwards via loopback.
transport = "stdio"

# Binary that the sandboxed CLI will exec. Resolved via PATH at
# config-load time, then bound at /tmp/glorbo-mcp-stado-<basename>.
binary = "stado"
args   = ["mcp-server"]

# Auth / config dirs that need to be bound into the sandbox so the
# MCP server itself can read its config.
[[auth_binds]]
host    = "~/.config/stado"
sandbox = "/workspace/.config/stado"
mode    = "ro"
```

### Per-CLI config injection

When an agent declaring `mcp_servers: [stado]` dispatches with
`provider: claude-code`, glorbo:

1. Resolves the `stado` kit from the registry.
2. Adds the kit's auth_binds + binary bind to the bwrap command.
3. **Layers** an MCP server entry into the agent's claude config
   inside the sandbox. Two strategy options:

   **(a) Overlay file.** Glorbo writes
   `<workspace>/.glorbo-claude-overlay.json` declaring the
   `mcpServers` block, and binds it OVER `/workspace/.claude/settings.json`
   via a `--bind` (rw → ro) so claude-code reads the merged version.
   Risk: clobbers user's existing settings. Need to merge.

   **(b) `--mcp-config <path>` flag.** If claude-code supports an
   explicit MCP config arg (it does, per the dogfood doc's
   reference), glorbo writes the file and passes the flag in
   `args:`. Cleaner — no overlay, no merge, no risk to user's
   global config.

Decision log entry D1 records the choice — leaning **(b)** since
it sidesteps the merge problem entirely.

For codex / gemini-cli / opencode, the analogous flag (or config
shape) is provider-specific; each kit lists per-CLI injection
instructions in the registry TOML. First implementation lands
claude-code only; other CLIs are Phase 3.

### Sandbox bind composition

`Glorbo.Agent.Dispatch.build_invocation/3` already composes binds in
a fixed order: permission-mapped + provider auth_binds + native
credentials + CLI binary. New step inserted before the CLI-binary
bind:

```
permission_mapped
++ provider_auth_binds
++ native_credentials_binds
++ mcp_server_binds       # ← new
++ [cli_binary_bind]
```

`mcp_server_binds/1` walks the agent's `mcp_servers:` list,
resolves each kit, and returns its auth_binds + binary bind as a
flat list. Path collisions (two kits both wanting
`/workspace/.config/...`) are a hard error at dispatch time.

### Lifecycle

stdio-transport MCP servers are spawned by the outer CLI itself
(claude-code launches `stado mcp-server` as a subprocess via the
client SDK). Glorbo doesn't manage the MCP server's process
lifetime; it just needs to be exec'able from inside the sandbox
with correct binds. This is the simplest, most robust shape and
matches how external MCP servers usually run.

For HTTP-SSE transport (later kits), the MCP server runs
long-running on the host. Glorbo binds a loopback port through to
the sandbox via the existing `network: proxy` mechanism (GEP-23)
plus an explicit network_allow entry. Detailed design deferred to
Phase 4+ — stdio is enough for stado.

### Network policy compatibility

`network: loopback` is sufficient for stdio MCP servers — the
client and server communicate via stdio pipes, not network. No
network policy change needed.

`network: proxy` and `network: full` continue to behave as before;
stdio MCP doesn't interact with them.

For HTTP-SSE MCP (out of scope for this GEP), the policy gains a
new value `mcp_loopback` or similar. Deferred.

## Phases

| Phase | Deliverable | Status |
|-------|-------------|--------|
| 0 | This GEP (Draft → Accepted) | In progress |
| 1 | `Glorbo.MCP.Server.Registry` (loader for `priv/mcp_servers/*.toml`); FileSpec gains `mcp_servers:` field with registry-backed enum validation; AGENT.md spec doc updated; `priv/mcp_servers/stado.toml` ships as the first kit. No dispatch wiring yet — declaration only. | Pending |
| 2 | `Glorbo.Agent.Dispatch` calls into `MCP.Server.Registry` to compose binds + inject `--mcp-config` for claude-code provider. Stado-with-claude-code agent dispatches end-to-end. | Pending |
| 3 | Codex / gemini-cli / opencode injection paths. | Pending |
| 4 | HTTP-SSE transport + loopback network policy bridge. | Deferred |

Bench validation (Phase 2): a `bench-htb` company with one agent
declaring `provider: claude-code` + `mcp_servers: [stado]` actually
calls `webfetch` via stado-mcp-server during a real dispatch. The
audit log shows the tool calls.

## Decision log

### D1 — Config injection strategy: overlay file vs `--mcp-config` flag

**Status:** Open (lean to flag).

`--mcp-config` cleanly sidesteps the merge problem (user's global
config is untouched) and matches how claude-code's documentation
describes MCP wiring for non-default cases. Overlay would be
necessary only if some CLI doesn't support an explicit-config flag;
per-CLI investigation in Phase 3 will surface those. Until then,
flag-based for claude-code.

### D2 — Per-agent vs per-company vs per-host MCP-server registry

**Status:** Decided — per-agent declaration, host-shipped registry.

The registry of *available* kits ships with glorbo (in
`priv/mcp_servers/`). Each agent opts in via its `mcp_servers:`
list. Director can override / extend by dropping kits into
`~/.glorbo/mcp_servers/<name>.toml` (like the existing user provider
override pattern in GEP-8 §2.3). Per-company is unnecessary: a kit
that should only apply to one company is just a kit with that
company's configured allowlist on its host-side server, not a glorbo
concern.

### D3 — Auth bind precedence when kit conflicts with provider

**Status:** Hard-fail at dispatch.

If `priv/providers/claude-code.toml` binds `/workspace/.claude` and a
kit also binds `/workspace/.claude`, dispatch returns
`{:error, :sandbox_path_collision, [...]}`. Operators reorganize
the kit (sandbox path = `/workspace/.config/stado` — different
prefix). Soft-merge is too easy to get wrong.

### D4 — Validation: kit name must exist in registry

**Status:** Yes, hard-fail at FileSpec validation.

`mcp_servers: [foo, bar]` where `bar` isn't in the registry returns
a FileSpec error referencing the missing kit + the available list,
same shape as `provider:` validation. No silent skip.

### D5 — Why not GEP-9 / GEP-29 instead?

**Status:** Decided — separate concern.

GEP-9 is the direction record for protocol-level integration;
GEP-29 is the inbound side (Glorbo as MCP server). This GEP is the
outbound side (Glorbo agents as MCP clients of external servers).
The three concerns share the protocol but not the architecture
surface, so a dedicated standards GEP is cleaner than extending
either.

### D6 — Stado as the validation target

**Status:** Decided.

Stado is the user's own actively-developed tool; the dogfood doc
already specifies the integration; both the user and the project
have skin in the game. First-party validation case is more honest
than picking some third-party MCP server.

## Open questions

These are deferred to Phase 1+ design / implementation:

1. How does claude-code react to a missing `--mcp-config` value
   (typo, wrong path)? Logged warn, hard-fail, silent skip? Affects
   the dispatch error surface.

2. Stado's MCP server outputs progress / log lines on stderr. Does
   any of that leak into the agent's reply file? Need to test
   under realistic load.

3. GEP-23 (per-agent allowlist extensions) interacts with kit-
   declared binds — kit might want to bind paths the agent's
   permissions wouldn't otherwise allow. Two interpretations:
   (a) kit binds win (the agent opted in by declaring the kit);
   (b) permissions win (security posture is the agent's
   declarations). Lean (a), but capture the decision before code.

4. Multiple kits declaring overlapping host-binary names (e.g.
   two MCP kits both wanting to bind `stado` to different sandbox
   paths). Phase 1 hard-fails; later phases might reconcile.

## Bidirectional links

- **GEP-8** — provider registry pattern that this GEP mirrors for
  MCP server kits.
- **GEP-9** — direction record that frames this work as the
  outbound symmetric to GEP-29.
- **GEP-23** — sandbox network policy + per-agent allowlist
  extensions; HTTP-SSE phase will interact heavily.
- **GEP-29** — Glorbo as MCP server (inbound). This GEP is the
  outbound counterpart.
