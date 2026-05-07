# Glorbo TODO

## ⚡ NEEDS IMPLEMENTATION (open items — please pick these up)

### F7: Handle `kind=approval` in ACP `session/update` — hangs on stado v0.46.0 ~~FIXED 2026-05-07~~

**Priority: HIGH.** stado v0.46.0 ships `stado_ui_approve` over ACP. Any turn where
a wasm plugin calls it emits `session/update {kind="approval"}` and waits for
`session/approval_response`. Glorbo currently ignores it → the turn hangs until
`phase_timeout_ms` fires (10 minutes). Every engagement that hits a plugin with an
approval gate silently stalls.

**Wire shape (stado v0.46.0):**
```json
{"kind": "approval", "requestId": "<uuid>", "title": "...", "body": "..."}
```
or wrapped:
```json
{"update": {"kind": "approval", "requestId": "<uuid>", "title": "...", "body": "..."}}
```

**Required response:**
```json
session/approval_response {"sessionId": "<id>", "requestId": "<uuid>", "allow": false, "cancelled": false}
```

**Files to change:**

`lib/glorbo/cli/dispatcher/acp/client.ex`

1. Add a helper to send the response:
```elixir
defp send_approval_response(state, request_id) do
  {id, state} = take_id(state)
  notification =
    Message.new_notification("session/approval_response", %{
      "sessionId" => state.session_id,
      "requestId" => request_id,
      "allow" => false,
      "cancelled" => false
    })
  case send_message(state, notification) do
    :ok -> {:ok, state}
    {:error, _} = err -> err
  end
end
```

2. In `drain_session_prompt/2` (line ~260), intercept approval notifications before
   they reach `absorb_update`. Add a new `{:notification, "session/update", params}`
   branch that checks `params["kind"] == "approval"` (or nested under `"update"`):
```elixir
{:ok, {:notification, "session/update", %{"kind" => "approval", "requestId" => req_id} = _params}, state} ->
  with {:ok, state} <- send_approval_response(state, req_id) do
    drain_session_prompt(state, prompt_id)
  end

{:ok, {:notification, "session/update", %{"update" => %{"kind" => "approval", "requestId" => req_id}}}, state} ->
  with {:ok, state} <- send_approval_response(state, req_id) do
    drain_session_prompt(state, prompt_id)
  end
```
Place these clauses before the generic `session/update` → `absorb_update` clause.

**Test:** unit test in `dispatcher/acp/client_test.exs` — inject a
`session/update kind=approval` into the IO seam and verify glorbo sends
`session/approval_response {allow: false, cancelled: false}` then continues draining.

---

### F6: Persist `sessionId` and resume across ACP dispatches ~~FIXED 2026-05-07~~

**Priority: MEDIUM.** stado v0.46.0 ships session resume. Without this, every
scanner→attacker→escalator hand-off starts a fresh stado session — the model
rebuilds context from scratch at each phase. With it, the session worktree carries
prior reasoning and tool-call history into the next agent turn.

**stado wire contract:**
- `session/new` response always includes `"sessionId": "<UUID>"`.
- Sending `session/new {"resumeSession": "<UUID>"}` attaches to the existing worktree.
- Must be a canonical UUID (prefix/description lookup is CLI-only).

**Files to change:**

`lib/glorbo/cli/dispatcher/acp/client.ex` — accept optional resume id in `run/3`:
```elixir
# In run/3 opts:
resume_session_id = Keyword.get(opts, :resume_session_id)

# Thread into phase_session_new:
{:ok, state} <- phase_session_new(state, resume_session_id),
```

Modify `phase_session_new/1` → `phase_session_new/2`:
```elixir
defp phase_session_new(state, resume_session_id \\ nil) do
  {id, state} = take_id(state)
  params =
    if resume_session_id,
      do: %{"resumeSession" => resume_session_id},
      else: %{}
  request = Message.new_request(id, "session/new", params)
  with :ok <- send_message(state, request),
       {:ok, msg, state} <- await_response(state, id, :session_new) do
    classify_session_new_response(msg, id, state)
  end
end
```

`lib/glorbo/cli/dispatcher.ex` — persist and restore session id around `run_acp`:

Before calling `run_acp`, read the prior session id:
```elixir
sessions_dir = Path.join(reply_dir, "../sessions") |> Path.expand()
session_file = Path.join(sessions_dir, "#{invocation_id}.txt")
# keyed by task slug, not invocation — use task_slug from ctx or provider name
task_session_file = Path.join(sessions_dir, "#{ctx.task_slug}.txt")
prior_session_id = case File.read(task_session_file) do
  {:ok, id} -> String.trim(id)
  _ -> nil
end
acp_opts = if prior_session_id, do: [resume_session_id: prior_session_id], else: []
```

After `run_acp` succeeds, persist the returned session id:
```elixir
if acp_result.session_id do
  File.mkdir_p!(sessions_dir)
  File.write!(task_session_file, acp_result.session_id)
end
```

Note: `ctx.task_slug` may need to be threaded in from the task frontmatter. If not
already available, use `provider.name <> "/" <> invocation_id` as a fallback key that
at least de-duplicates per-provider within a session.

**Test:** integration-style test that dispatches twice to the same mock ACP server,
verifying the second `session/new` carries `"resumeSession"` equal to the `sessionId`
returned by the first.

---

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
### B2: ACP phase_timeout_ms too short (30s default) ~~FIXED~~
### B3: cli_auth_bind_flags ignores mode field — always --ro-bind ~~FIXED~~
### B4: ACP dispatch path skips build_env — provider [env] vars never injected ~~FIXED~~
### B5: Non-standard sandbox bind targets silently fail (no --dir) ~~FIXED~~
### B6: `allow_untracked_budget` key unknown to validator ~~FIXED~~
### B7: ACP port-close after MaxTurns misreported as {:provider_timeout} ~~FIXED~~

## Deferred features (needs design / GEP before code)

### F1: MCP server config in provider TOML or AGENT.md
No mechanism to inject an MCP server connection into a sandboxed CLI session.
Providers should declare `[[mcp_servers]]` entries glorbo wires into the CLI's
MCP client config before launch. Needs GEP for config shape + permission model.

### F2: Pre-dispatch workspace prep hook
No hook to run a command before sandbox launch. Needed for syncing writable
data dirs, generating per-invocation credentials, staging files the agent
needs that can't be auth_bind'd rw. Needs GEP for shell-command-in-config
permission model.

### F3: Per-dispatch env override at CLI level
`glorbo run` has no `--env KEY=VALUE` flag for one-off secret injection.

### F4: Forward max_turns in ACP session/new
Expose a `max_turns:` field in provider TOML / task frontmatter that forwards
to `session/new {"maxTurns": N}` for providers without a CLI flag. stado already
uses `--no-turn-limit` CLI flag; this is for non-stado ACP providers.

### F5: Handle kind=choice session/update events
`session/update {kind="choice"}` events are currently ignored (→ cancelled).
Glorbo needs a `drain_session_prompt` branch to surface choices and send
`session/choice_response`. For headless dispatches: send `cancelled=true`.
Same pattern as F7 (approval) — implement together.

### F8: ACP reply assembly should fall back to GLORBO_REPLY_PATH file
Belt-and-suspenders fallback for providers that write to `$GLORBO_REPLY_PATH`
but emit no text chunks and no `kind=tool_summary`. After ACP completes, if
`reply_text` is empty and the reply_path file has content, use the file.
Low priority now that F9 covers the stado/Kimi K2.6 case.

### F9: Handle kind=tool_summary in absorb_update ~~FIXED 2026-05-07~~
stado v0.46.0 `kind=tool_summary` captured; synthesizes `"[N tool call(s); last=X; ok]"`
when no text chunks arrived.
