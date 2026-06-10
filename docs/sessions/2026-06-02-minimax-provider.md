# 2026-06-02 — MiniMax native provider + local build

## Task picked

Add support for the MiniMax model family — `minimax-m2.x` (with the
`-highspeed` option) and `minimax-m3` — then compile + install the latest
local build.

## What shipped

New built-in native provider `priv/providers/minimax.toml`:

- `kind = native`, OpenAI-compatible endpoint `https://api.minimax.io/v1`,
  `auth = bearer`, `usage_parser = native-v1` — routes through the existing
  GEP-32 native harness exactly like `openai` / `openrouter` (no CLI binary).
- Static model catalog (verified against MiniMax's live release-notes +
  API docs, June 2026): `MiniMax-M3`, `MiniMax-M2.7`,
  `MiniMax-M2.7-highspeed`, `MiniMax-M2.5`, `MiniMax-M2.5-highspeed`.
- Credentials: `~/.local/etc/glorbo/credentials/minimax.toml` (`api_key`).
- Select with `provider: minimax` + `model: MiniMax-M2.7` in `AGENT.md`.

Docs/tests:

- `builtin_providers_test.exs`: count 12 → 13, `minimax` in the native set,
  dedicated shape test (endpoint/auth/usage/static catalog).
- README native-provider section + feature bullet.
- CHANGELOG `[Unreleased] → Added`.

## Design calls I made without you

- **A dedicated native provider, not an entry in an existing broker's list.**
  MiniMax exposes its own OpenAI-compatible API, so a first-class `minimax`
  provider (mirroring `openai`/`openrouter`) is the idiomatic GEP-32 fit and
  gets real `native-v1` usage tracking. Adding aliases to `stado`/`opencode`
  would have been untracked and indirect.
- **`shape = static`, not a `/v1/models` probe.** MiniMax doesn't advertise
  an OpenAI-style models endpoint we depend on, and the user named specific
  models — a static list surfaces them deterministically in the picker.
  `ModelCatalog` projects `:static` lists directly, no network.
- **`-highspeed` is a distinct model id, not a request flag.** The provider
  schema has no per-model option field; MiniMax ships `-highspeed` as its
  own model name, so each is a separate catalog entry.
- **Which m2.x:** included the two current point releases that carry a
  `-highspeed` variant (M2.5, M2.7). Older `MiniMax-M2` / `M2.1` were left
  out (no confirmed highspeed variant); add on request.
- **No GEP.** Additive provider preset = data, not a new invariant/CLI verb
  (same category as the un-GEP'd `openai`/`openrouter` presets).

## Gates

- `mix test` (registry): 49/49.
- `mix precommit`: 3006 tests, 0 failures.
- `mix credo --strict`: no issues (exit 0).
- `mix format` on the edited test file.

## Skipped / not done

- No runtime dispatch against the live MiniMax API (no API key on this host;
  config is verified by unit tests + doc cross-check).
- No version cut / push (awaiting your ask, per standing rule).

## Commit(s)

- (this session) `feat(providers): minimax native provider — M2.x +highspeed + M3`
