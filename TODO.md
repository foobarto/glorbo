# Glorbo TODO

## Build / deployment

### D1: `mix release glorbo` hangs on interactive "Overwrite?" prompt ~~FIXED~~
`mix release glorbo` without `--overwrite` pauses on "Release X already exists.
Overwrite? [Yn]", blocking non-interactive CI/scripts.
**Fix:** `mix glorbo.release_guard` alias always appends `--overwrite`.

### D2: OTP release launcher doesn't support `glorbo run` ~~FIXED~~
`_build/prod/rel/glorbo/bin/glorbo` only exposes OTP verbs. The `glorbo run`
CLI verb requires the Burrito binary or `mix run`.
**Fix:** `rel/overlays/bin/glorbo-cli` wrapper bridges `glorbo-cli VERB ARGS...`
→ `bin/glorbo eval 'Glorbo.CLI.dispatch(argv)'`.

### D3: stado data dir auth_bind as sub-bind silently breaks stado git session
When `~/.local/share/stado` is mounted as a sub-bind inside `/workspace`
(the agent workspace bind), stado's `OpenSession` / `CreateSession` silently
fails to create a worktree — no executor, no tools.
**Root cause (unconfirmed):** suspected interaction between `os.OpenRoot("/workspace")`
and the overlaid sub-bind. `MkdirAllUnderUserConfig` uses `os.OpenRoot` for
no-symlink-escape enforcement; the sub-bind may confuse path traversal.
**Workaround:** remove the sub-bind; pre-sync stado data dir into the agent
workspace instead (F2 hook would automate this).
**Proper fix:** investigate why `os.OpenRoot` + sub-bind fails in
`MkdirAllNoSymlinkUnder`, or add an explicit `~/.local/state/stado` auth_bind
alongside the share bind (worktrees go to state, not share).

## Bugs

### B1: ACP `session/update` kind mismatch ~~FIXED~~
`absorb_update` only accepted `{"kind":"agent_message_chunk"}`. Some ACP
providers emit `{"kind":"text"}` — every update was silently dropped.
**Fix:** absorb_update accepts both `"text"` and `"agent_message_chunk"`.

### B2: ACP phase_timeout_ms too short (30s default) ~~FIXED~~
**Fix:** default raised to 600_000ms.

### B3: cli_auth_bind_flags ignores mode field — always --ro-bind ~~FIXED~~
Provider TOML `auth_binds` `mode = "rw"` was ignored; always `--ro-bind`.
**Fix:** mode threaded through; `cli_auth_bind_flags/1` emits `--bind` for `:rw`.

### B4: ACP dispatch path skips build_env — provider [env] vars never injected ~~FIXED~~
`invoke_acp` skipped `build_env`, so `[env]` entries in provider TOML were
never `--setenv`'d into bwrap for ACP providers.
**Fix:** `invoke_acp` calls `build_env` and merges result into `bwrap_opts.cli_env`.

### B5: Non-standard sandbox bind targets silently fail (no --dir) ~~FIXED~~
bwrap requires bind targets to exist. Missing `--dir` silently prevented mounts.
**Fix:** `cli_auth_bind_flags` emits `--dir <sandbox>` before bind for the
4-tuple `{host, sandbox, mode, :dir}` shape.

### B6: `allow_untracked_budget` key unknown to validator ~~FIXED~~
**Fix:** added to `optional` keys in `FileSpec.AgentMd`.

### B7: ACP port-close after MaxTurns misreported as {:provider_timeout} ~~FIXED~~
EOF/port-close before parsing the final error frame caused false `:provider_timeout`.
**Fix:** `final_drain/2` polls IO seam on EOF to harvest final bytes.

## Missing features

### F1: MCP server config in provider TOML or AGENT.md
No mechanism to inject an MCP server connection into a sandboxed CLI session.
Providers should declare `[[mcp_servers]]` entries glorbo wires into the CLI's
MCP client config before launch.

### F2: Pre-dispatch workspace prep hook
No hook to run a command before sandbox launch. Needed for syncing writable
data dirs, generating per-invocation credentials, staging files the agent
needs that can't be auth_bind'd rw.

### F3: Per-dispatch env override at CLI level
`glorbo run` has no `--env KEY=VALUE` flag for one-off secret injection.

### F4: Forward max_turns in ACP session/new
Expose a `max_turns:` field in provider TOML / task frontmatter that forwards
to `session/new {"maxTurns": N}` for providers without a CLI flag.

### F5: Handle kind=choice session/update events
`session/update {kind="choice"}` events are currently ignored (→ `cancelled=true`).
Glorbo needs a `drain_session_prompt` branch to surface choices and send
`session/choice_response`. For headless dispatches: send `cancelled=true`.

### F6: Wire session resume into ACP dispatcher
stado v0.46.0 ships `session/new {"resumeSession": "<UUID>"}` (per-call, canonical UUID
required) and `stado acp --resume <id-or-label>` (operator default).
**Needed:** after each successful ACP dispatch, persist `acp_result.session_id` keyed by
task slug (e.g. `<workspace>/.glorbo/sessions/<task-slug>.txt`). On next dispatch for same
task, pass `{"resumeSession": prior_session_id}` in `phase_session_new`. Read at dispatch
time; clear on explicit task reset.
**Impact:** recon→foothold→privesc chain shares a single session worktree across dispatches;
model sees prior reasoning at turn 1.

### F7: Handle kind=approval in session/update (NOW ACTIONABLE — stado v0.46.0)
`session/update {kind="approval", requestId, title, body}` requires
`session/approval_response {sessionId, requestId, allow: false, cancelled: false}`.
Same dispatch pattern as F5 (choice). For headless: always deny (allow=false, cancelled=false).
Without this, any stado plugin calling `stado_ui_approve` hangs until phase_timeout_ms fires.

### F8: ACP reply assembly should fall back to GLORBO_REPLY_PATH file
When ACP text events are empty but the model wrote to `$GLORBO_REPLY_PATH`
via a tool call, the reply is 0 bytes. After ACP completes, if `reply_text`
is empty and the reply_path file has content, use the file.

### F9: Handle kind=tool_summary in absorb_update (PRIORITY — blocks Kali pipeline) — FIXED 2026-05-07
stado v0.46.0 emits `session/update kind=tool_summary` at end of any turn with
≥1 tool call but 0 text deltas. **Confirmed wire format (camelCase):**
```json
{"sessionId":"<id>","kind":"tool_summary","toolCount":5,"lastTool":"shell__bash","lastError":false}
```
Also appears wrapped: `{"update": {"kind":"tool_summary",...}}`. Handle both shapes.
`lastError` is bool (ToolResult.IsError), not exit code.
**Needed in `lib/glorbo/cli/dispatcher/acp/client.ex`:**
1. Add `tool_summary: nil` to state map.
2. New `absorb_update` clauses for both wrapped/unwrapped `kind=tool_summary`.
3. At result-assembly, if reply empty and `tool_summary` non-nil, synthesize:
   `"[N tool call(s); last=shell__bash; ok]"`.
F9 supersedes F8 as primary fix. F8 (file fallback) stays as belt-and-suspenders.
