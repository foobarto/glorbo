# Glorbo TODO — Issues found during HTB engagement testing (2026-05-07)

## Bugs

### B1: ACP `session/update` kind mismatch
**Status: FIXED** (`lib/glorbo/cli/dispatcher/acp/client.ex`)
`absorb_update` only accepted `{"kind":"agent_message_chunk"}`. stado (and
potentially other ACP providers) emit `{"kind":"text"}` for text delta events.
Every update was silently dropped → 0-byte reply files.
**Fix:** absorb_update now accepts both `"text"` and `"agent_message_chunk"` kinds.

### B2: ACP phase_timeout_ms too short (30s default)
**Status: FIXED** (`lib/glorbo/cli/dispatcher/acp/client.ex`)
30 seconds is insufficient for multi-turn tool-calling sessions.
**Fix:** default raised to 600_000ms (10 min).

### B3: cli_auth_bind_flags ignores mode field — always --ro-bind
**Status: FIXED** (`lib/glorbo/sandbox/bwrap.ex`, `lib/glorbo/agent/dispatch.ex`)
Provider TOML `auth_binds` declare `mode = "ro" | "rw"` but the flag was
always `--ro-bind`. Broke any provider that needs to write through an auth bind
(session state, temp files).
**Fix:** mode threaded through `resolve_auth_binds/1`; `cli_auth_bind_flags/1`
now emits `--bind` for `:rw`.

### B4: ACP dispatch path skips build_env — provider [env] vars never injected
**Status: OPEN** (`lib/glorbo/cli/dispatcher.ex` → `invoke_acp/3`)
`invoke_acp` skips `build_env` entirely. Env vars in a provider TOML `[env]`
section are never `--setenv`'d into bwrap for ACP providers.
The stdin path (`invoke/3`) correctly calls `build_env`.
**Fix:** `invoke_acp` should call `build_env` and pass the result to `Bwrap.start_acp`.

### B5: Non-standard sandbox bind targets silently fail (no --dir)
**Status: OPEN** (workaround: use subdirs of `/workspace`)
bwrap requires bind targets to already exist in the namespace. Paths outside
the pre-created dirs (`/workspace`, `/inbox`, `/outbox`, etc.) need `--dir`
before the bind. Missing `--dir` → bind silently doesn't mount.
**Fix:** `cli_auth_bind_flags` should emit `--dir <sandbox_path>` before the
`--bind/--ro-bind` for any sandbox path that isn't an established system dir.

### B6: GEP file format validator schema missing `allow_untracked_budget` key
**Status: MINOR** (warn only, runtime works)
`glorbo validate` reports `unknown_key` for `allow_untracked_budget` even
though the agent parser and dispatch code handle it correctly.
**Fix:** add the key to the FileSpec schema in `lib/gep/validator.ex`.

## Missing features

### F1: MCP server config in provider TOML or AGENT.md
When glorbo dispatches a CLI provider (e.g. claude-code), there is no
mechanism to inject an MCP server connection into the sandboxed CLI session.
Providers should be able to declare `[[mcp_servers]]` entries that glorbo
wires into the CLI's MCP client config before launch — enabling CLI agents
to call stado tools, glorbo tools, etc. natively without manual plumbing.

### F2: Pre-dispatch workspace prep hook
No hook to run a command before sandbox launch. Needed for: syncing writable
data dirs into the agent workspace, generating per-invocation credentials,
staging files the agent needs but that can't be auth_bind'd rw.
A `pre_dispatch:` shell command field in provider TOML or AGENT.md would cover this.

### F3: Per-dispatch env override at CLI level
`glorbo run <co>/<agent> <task>` has no `--env KEY=VALUE` flag.
Useful for one-off secret injection without modifying AGENT.md or provider TOML.

### F4: Glorbo should forward max_turns in ACP session/new
When dispatching an ACP provider, glorbo hard-uses whatever default the
provider binary has. The ACP protocol allows `session/new` params — glorbo
should expose a way (provider TOML or task frontmatter) to set `max_turns`
and forward it to the provider in the `session/new` request.
