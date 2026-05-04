# GEP-45 Phase 2 — bench-htb stado smoke

End-to-end validation of the GEP-45 ACP transport against a real
`stado` binary. This is the "Phase 2 ships when this passes" gate.

## What it validates

The bench drives the full glorbo→stado ACP path:

```
Glorbo.CLI.Dispatcher.invoke/3   (provider.prompt_mode = :acp)
        ↓
Glorbo.Sandbox.Bwrap.start_acp/2 (bwrap'd Port without prompt-tempfile)
        ↓
Glorbo.CLI.Dispatcher.Acp.PortIO (Port → %Client.IO{})
        ↓
Glorbo.CLI.Dispatcher.Acp.Client (initialize → session/new → session/prompt → shutdown)
        ↓
real stado binary running `stado acp --tools` inside the bwrap namespace
```

It does NOT validate stado's own inference — only that the **glorbo
side** of the wiring carries the JSON-RPC handshake through cleanly
against a real ACP peer (not just the mock peer in
`test/glorbo/cli/dispatcher/acp/client_test.exs`).

## Pass conditions

Either outcome counts:

1. **Full success** — stado has a working backend (claude, ollama,
   lmstudio, etc.) and dispatch returns
   `{:ok, %{reply: text, session_id: _, ...}}` with non-empty text.
2. **Handshake-only success** — stado responded to `initialize` +
   `session/new`, then errored on `session/prompt` with
   `{:provider_returned_error, %{code: -32_602 | -32_603, message: ...}}`
   because no backend is configured.

The handshake completing is the load-bearing assertion. Reaching
"prompt errored cleanly" means: the framing works, the sandbox spawn
works, the state-machine drives correctly through three phases against
a real ACP server, and prompt-side errors round-trip through the
dispatcher's error categories.

## Pinning the stado binary

The bench uses a pinned snapshot under `.bench/bin/stado-pinned` so
the result is reproducible across stado rebuilds:

```bash
mkdir -p .bench/bin
cp -f $(which stado || echo /path/to/stado/stado) .bench/bin/stado-pinned
chmod +x .bench/bin/stado-pinned
```

`.bench/` is gitignored. The pin is operator-local; this doc is the
reproducibility contract.

## Running

```bash
# Default — uses .bench/bin/stado-pinned if present.
mix test --include stado_bench --include integration \
  test/integration/gep_45_stado_bench_test.exs

# Or point at a different stado:
STADO_BENCH_BIN=/usr/local/bin/stado mix test --include stado_bench \
  --include integration test/integration/gep_45_stado_bench_test.exs
```

Skips cleanly (returns `:ok`, no failure) when:

- `STADO_BENCH_BIN` is unset AND `.bench/bin/stado-pinned` is absent
- `bwrap` is not available on the host

## Sandbox binds

The bench scaffold mirrors what `Glorbo.Agent.Dispatch.build_invocation/3`
constructs in production:

| host path | sandbox path | mode | why |
|---|---|---|---|
| `<stado-pinned>` | `/tmp/glorbo-cli-stado-stado` | ro | the binary itself; without this the bwrap exec fails before initialize |
| `~/.config/stado` | `/workspace/.config/stado` | ro | stado config, including `defaults.provider` |
| `~/.local/share/stado` | `/workspace/.local/share/stado` | rw | stado's signing keys (`keys/agent.ed25519`) + session/task state |

Without the second auth_bind, stado refuses to start because it can't
load `agent.ed25519`. Without the third, stado can't write its session
trace and `session/prompt` would error before the handshake completes.

## Recorded run (2026-05-04)

Stado pinned: `v0.26.4-0.20260504135013-5f7455d61ced+dirty`
Host: Fedora Bazzite 6.17.7, bwrap 0.11.2

```
[gep_45_stado_bench_test] HANDSHAKE — stado handshake passed;
prompt errored as expected with no backend:
code=-32603 message="no provider configured"
.
1 test, 0 failures
```

**Result: PASS** (handshake-only).

stado's own doctor reports `Provider (unset — probes local at boot)` —
no anthropic/openai key configured, no ollama/lmstudio/llamacpp/vllm
running locally. Configuring `defaults.provider = "claude"` (or
starting an `ollama serve` against a small model) would lift this
result to "FULL".

## What this tells us about the next phase

GEP-45 Phase 2 acceptance criteria from the GEP:

> Smoke + bench: a `bench-htb` company with a stado-driven agent
> dispatches end-to-end against a real stado on the host, audit log
> captures the ACP message exchange.

Met for the dispatch path (the Dispatcher.invoke → ACP run loop end
of the contract). Open follow-ups for Phase 3:

- **Audit log capture of the ACP exchange.** Phase 1b's client
  surfaces `chunks` + `ignored_updates` counts but no per-frame audit
  emission. Phase 3 task: emit `cli.acp.{request,response,update}`
  audit lines so the operator can replay an ACP session from
  `~/.glorbo/audit/`.
- **Real `bench-htb` company on disk.** This bench scaffolds a tmp
  workspace per run; for a sustained dogfood we'd want a checked-in
  fixture company under `test/fixtures/companies/bench-htb/` with a
  pre-baked AGENT.md (`provider: stado`).
- **Stado backend wiring.** Operator concern, not glorbo's: tracking
  whether stado has anthropic/ollama configured is what stado's own
  doctor handles. Glorbo records the handshake-only fallback as a
  successful Phase 2 outcome.

## Bidirectional links

- **GEP-45** — this bench is the Phase 2 gate.
- `lib/glorbo/cli/dispatcher.ex` — ACP branch under
  `def invoke(%Provider{prompt_mode: :acp} ...)`.
- `lib/glorbo/sandbox/bwrap.ex` — `start_acp/2`.
- `lib/glorbo/cli/dispatcher/acp/{client,framing,message,port_io,rpc_error}.ex`
  — the ACP transport stack.
- `priv/providers/stado.toml` — built-in provider TOML.
