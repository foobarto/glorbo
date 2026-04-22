# Connecting external MCP clients to Glorbo

Glorbo exposes a **Model Context Protocol 2025-06-18** server at
`http://localhost:4000/mcp` when `phx.server` is running. The
transport is MCP's Streamable HTTP profile — one URL handles both
JSON-RPC POST requests and server-sent-event subscriptions.

This doc covers hooking up **Claude Code**, **Cursor**, and any other
MCP-aware client to a running Glorbo instance.

## What's exposed

- **23 tools** (`tools/list`) — 1:1 with Glorbo's web UI: list /
  get / create for companies, agents, tasks, proposals, channels,
  audit; write actions like `post_message`, `approve_task`,
  `capture_brain_dump`, `force_agent_heartbeat`.
- **4 resource families** (`resources/list` + `resources/read`):
  - `glorbo://audit/<company>`
  - `glorbo://approvals/<company>`
  - `glorbo://proposals/<company>`
  - `glorbo://chat/<company>/<channel>`
- **Subscriptions** (`resources/subscribe`) — SSE-pushed
  `notifications/resources/updated` whenever the filesystem or audit
  log changes underneath a subscribed URI.

## Security posture

- Binds to `127.0.0.1` only. No remote access.
- No authentication. The kernel-level company isolation from GEP-5
  still applies inside tool dispatch; the MCP surface has the same
  permissions as the web UI.
- `Origin` header is allowlisted (`localhost`, `127.0.0.1`, `::1`) to
  close the DNS-rebinding attack.
- `MCP-Protocol-Version` header is validated on every non-initialize
  request.

Treat the MCP endpoint the same way you'd treat the web UI on
`:4000` — if the port is open to something you don't trust, so is
everything behind it.

## Claude Code

Easiest route — let the CLI do the config for you:

```bash
# user-scope (available in every project)
claude mcp add --scope user --transport http glorbo http://localhost:4000/mcp

# project-scope (only this repo)
claude mcp add --scope project --transport http glorbo http://localhost:4000/mcp
```

Or edit the config files directly:

- **User scope** — entry under `mcpServers` in `~/.claude.json`
- **Project scope** — dedicated `.mcp.json` at the project root

```json
{
  "mcpServers": {
    "glorbo": {
      "type": "http",
      "url": "http://localhost:4000/mcp"
    }
  }
}
```

Restart Claude Code. The tools appear as `mcp__glorbo__*` (e.g.
`mcp__glorbo__list_companies`). Check with `/mcp` inside Claude Code
to confirm the server connected.

## Cursor / other Streamable-HTTP clients

Any MCP client that speaks the 2025-06-18 Streamable HTTP profile
should accept a URL-only config. Point it at
`http://localhost:4000/mcp`; no auth, no extra headers needed. The
server responds with the full capability set on `initialize`.

## Smoke test

`scripts/mcp-smoke.sh` exercises the full protocol end-to-end:
initialize → tools/list → tools/call → resources/list →
resources/subscribe → open SSE → trigger change → verify
notification → DELETE. Useful when:

- debugging a client integration that isn't behaving,
- validating a fresh build before shipping,
- or just convincing yourself the whole stack works.

**Prerequisites:**

- `mix phx.server` running locally (default port 4000).
- At least one company exists under `~/.glorbo/companies/`.
- That company has at least one channel (the seeded `acme` company
  ships with `dm-director--ceo`, so a fresh install works out of
  the box).
- `curl` and `jq` on `$PATH`.

```bash
mix phx.server                    # in one terminal
bash scripts/mcp-smoke.sh         # in another

# override port (if phx.server is on a non-default port):
MCP_URL=http://localhost:4001/mcp bash scripts/mcp-smoke.sh
```

The script picks the first chat URI it finds in `resources/list`
and runs subscribe+trigger against whichever company that channel
belongs to — no per-run configuration needed. Prints a per-step
✓ / ✗ line; exits non-zero on any protocol failure.

## Custom actor tagging

Every write action on the MCP surface is audited as `mcp:<client>`
where `<client>` comes from the `Mcp-Client-Name` header (normalized
to a slug). If you want your client to show up as
`mcp:claude-code` in audit logs rather than `mcp:unknown`, set that
header on every request:

```
Mcp-Client-Name: claude-code
```

Claude Code does this automatically. For hand-crafted clients or
`curl` scripts, include it alongside `content-type`.

## Troubleshooting

- **500 Internal Server Error on initialize** — the running
  `phx.server` is older than the code. Restart it.
- **403 Forbidden** — your `Origin` header is set to something
  outside the allowlist. If you're hand-crafting requests, drop the
  `Origin` header entirely; native clients get a pass.
- **400 Invalid Request on POST** — almost always a missing
  `Mcp-Session-Id` header (after the first request) or a missing
  `MCP-Protocol-Version` header with an unsupported version.
- **`resources/subscribe` returns `-32002 No active session`** —
  the client skipped the `initialize` handshake, or your session
  expired and needs to be re-created.

## Protocol details

See GEP-29 (`docs/geps/0029-mcp-server-for-glorbo.md`) for the full
design + decision log. The spec itself lives at
<https://modelcontextprotocol.io/specification/2025-06-18>.
