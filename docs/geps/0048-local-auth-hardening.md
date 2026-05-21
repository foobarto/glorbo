---
gep: 0048
title: Local auth hardening — epmd loopback + mandatory dashboard token
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
type: Standards
created: 2026-05-11
history:
  - date: 2026-05-11
    status: Draft
    note: Initial draft.
  - date: 2026-05-11
    status: Implemented
    note: Shipped in the same session.
implemented-in: v0.21.0
---

# GEP-0048: Local auth hardening — epmd loopback + mandatory dashboard token

## Problem

Three gaps existed in Glorbo's local security posture:

1. **epmd listened on all interfaces.** `ensure_epmd/0` spawned `epmd -daemon`
   with no `-address` flag, binding `0.0.0.0:4369`. Any process on the LAN
   could register or query Erlang node names.
2. **Dashboard auth was opt-in.** `DashboardToken` was a no-op when
   `dashboard_token: null` (the default). Fresh installs had no token, so
   the web UI was unauthenticated by default.
3. **MCP endpoint was unauthenticated by default** for the same reason —
   `/mcp` was already behind the `:dashboard` pipeline but inherited the
   nil pass-through.

The HTTP bind (`ip: {127, 0, 0, 1}`) was already correct.

## Goals

- epmd only listens on `127.0.0.1`.
- A mandatory auth token is auto-generated on first boot (or on upgrade
  from a `null` value) and persisted in `config.md`.
- Both the web dashboard and the MCP endpoint always require the token.
- The token URL is printed on `glorbo serve`, `glorbo up`, and
  `glorbo status`.

## Non-goals

- Token rotation UI (the operator can edit `config.md` manually).
- Multi-user or multi-token support.
- Changing the HTTP bind (already `127.0.0.1`).

## Design

### epmd

`ensure_epmd/0` in `Glorbo.CLI.Lifecycle.Distribution` spawns:

```
epmd -address 127.0.0.1 -daemon
```

Edge case: if another Erlang app already started epmd on all interfaces,
our invocation exits silently (epmd is idempotent). We log a warning but
do not abort — `Node.start/2` still succeeds.

### Token generation

`Glorbo.Config.load/1` gains an `ensure_dashboard_token/2` step in its
`with` chain. When `dashboard_token` is nil or empty, a 32-byte
URL-safe base-64 token (~192 bits of entropy) is generated and patched
into `config.md` via line-level regex replacement (same technique as the
existing `write_cookie!`). The file is written with mode 0600. The token
is never logged (T-04-05).

`write_default!/1` (fresh-install path) also pre-generates a token, so a
newly created `config.md` never contains `dashboard_token: null`.

### Plug enforcement

`DashboardToken.call/2` drops the nil and empty-string pass-throughs.
A missing token at runtime (startup bug) returns `500 server
misconfiguration` and halts, making the failure loud rather than silently
open.

### Session cookie (post-ship refinement, 2026-05-21)

The browser dashboard pipes through `:browser`, which fetches the
session. The plug records a `sha256` fingerprint of the token in the
signed session on the first valid `?token=`, and accepts that cookie on
subsequent requests — so the operator opens the printed token URL once
and then browses normally, without `?token=` on every request. This
also repairs the advertised entry URL: `GET /?token=…` redirects to
`/companies`, and the redirect previously dropped the token and 401'd;
the cookie set on the redirect response now carries the auth through.
Rotating `dashboard_token:` invalidates every outstanding cookie (the
fingerprint stops matching) and the raw token is never stored in the
cookie. MCP (`:api` pipeline, no session) stays stateless — the bearer
header accompanies each request.

Two follow-up fixes from full e2e UAT (2026-05-21): (1) `mix phx.server`
(dev) only loaded the token into app env via runtime.exs's prod block,
so the dev dashboard 500'd on every request — `config_env() == :dev` now
loads it too; (2) the session-cookie behaviour above.

### Token URL display

- `glorbo serve` — prints `http://127.0.0.1:4000/?token=<token>` to stdout.
- `glorbo up` — includes the token URL in the success message.
- `glorbo status` — reads `config.md` and includes the token URL in both
  human and `--json` output.

## Migration / rollout

On upgrade, the next `glorbo serve` or `glorbo up` triggers
`Config.load/1`, which detects `dashboard_token: null`, generates a
token, and patches `config.md`. The token URL is then printed in the
startup banner — operators copy it to configure their browser and MCP
client (`Authorization: Bearer <token>`).

## Failure modes

- **config.md patch fails (disk full, EACCES):** token is generated
  in-memory, server boots, warning is logged. Token changes on next
  restart. Operator must fix the filesystem to make it persistent.
- **Another epmd already running on all interfaces:** warning logged,
  glorbo still starts. Risk is pre-existing epmd's wider bind.

## Test strategy

- `Glorbo.ConfigTest` — token auto-generation cases (nil, empty, existing,
  mode 0600 after patch).
- `GlorboWeb.Plugs.DashboardTokenTest` — nil/empty → 500; removed
  pass-through cases.
- `Glorbo.CLI.StatusTest` — token URL in table and JSON output.
- `Glorbo.CLI.ServeTest` / `UpTest` — token URL in startup output.
- `Glorbo.CLI.DistributionTest` — contract test asserting `-address` flag.

## Decision log

### D1. Generate token in `Config.load/1`, not at serve/up time

- **Decided:** `load/1` is the single generation point. `ensure_dashboard_token/2`
  is a step in the `with` chain.
- **Alternatives:** Generate in `Serve.run/1` and `Up.start_daemon/1`
  separately; generate only in `write_default!` (no migration).
- **Why:** Single path handles both fresh install and migration from `null`.
  Token is always available in app env after `runtime.exs` calls `load/1`.

### D2. Line-level regex patch for `config.md`

- **Decided:** `String.replace/3` with a `~r/^dashboard_token:.*$/m` regex
  to overwrite the existing line.
- **Alternatives:** Full YAML round-trip serialisation.
- **Why:** `Frontmatter` has no serialise function. The config format is
  fixed and narrow; targeted line replacement is safe, auditable, and
  mirrors the existing `write_cookie!` approach.

### D3. 500 on nil token in `DashboardToken`

- **Decided:** nil/empty → `500 server misconfiguration` + halt.
- **Alternatives:** Silently pass through (original); 503.
- **Why:** A nil token at runtime is a startup bug. 500 is loud and
  forces investigation; silent pass-through turns a bug into an open door.

## Related

- GEP-5: kernel-enforced security (bwrap isolation)
- GEP-29: MCP server (the endpoint being hardened)
- Threatmodel T-04-05: secret leakage
- Threatmodel T-04-14: timing attacks on token comparison
- Threatmodel T11: MCP bearer-header auth
