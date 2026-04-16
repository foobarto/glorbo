# Example Company: acme — Next Steps

`glorbo init` scaffolded an `acme` company with a CEO agent. To actually run
LLM inference offline, you (the Director) start Ollama with a Unix-socket
binding so the `network: none` container can reach it via a bind-mount.

This document resolves **Q-A2** from Phase 2: Phase 2 establishes the socket
directory layout and prints this recipe as a "Next steps" hint after `init`;
the Director (that is, you, the human operator) runs these commands. The
actual Glorbo Director process that auto-starts this is a Phase 3 deliverable.

## 1. Start Ollama with a Unix socket

```bash
mkdir -p /tmp
OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve &
```

Leave this running in a terminal (or wrap it in a systemd unit yourself —
Glorbo does not manage Ollama's daemon lifecycle per D-06).

## 2. Pull a small model

```bash
ollama pull llama3.2:1b
```

The `acme/ceo` agent's `agent.md` pins `provider: ollama` and `model:
llama3.2:1b` as the v1 safe default.

## 3. Verify offline inference (airplane-mode ritual)

```bash
# Disable host networking to prove the inference path is fully local.
sudo nmcli networking off

# Run the airplane-mode integration test.
mix test test/integration/airplane_mode_test.exs --include airplane

# Re-enable networking when done.
sudo nmcli networking on
```

The test:

1. Starts a persistent container for `acme/ceo` with a `--volume
   /tmp/ollama.sock:/tmp/ollama.sock:Z,rw` bind-mount.
2. POSTs a trivial `/run` request with `provider=ollama`, `model=llama3.2:1b`.
3. Asserts a non-empty completion returns within 10 seconds.

## 4. Known issue (Phase 2)

- **ollama-python client UDS support** (Q-A3): the worker in `glorbo-runtime`
  calls `litellm.completion` exclusively (D-40), not `ollama` directly.
  If `litellm`'s Ollama provider turns out to require TCP loopback instead
  of UDS, the fallback is an `httpx`-over-UDS shim in
  `containers/glorbo-runtime/worker/dispatch.py` — a small edit to route
  requests through a manual UDS connection. Verify at first airplane-mode
  run; record disposition in Plan 04's SUMMARY.

## 5. Tearing down

```bash
# Stop the ollama daemon (whatever PID you backgrounded in step 1)
pkill -f "ollama serve"

# Remove the example company entirely if desired
rm -rf ~/.glorbo/companies/acme
```

`acme/` is just a directory — deleting it leaves the rest of your Glorbo
install untouched. Core Value: it's just a directory.
