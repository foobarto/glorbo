---
gep: 0049
title: One-time bootstrap token → rotating per-session cookie
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Draft
type: Standards
created: 2026-05-22
requires: [48]
see-also: [29]
history:
  - date: 2026-05-22
    status: Draft
    note: |
      Initial draft. Captures the operator's "discard the token after
      first use, mint a fresh per-session token in a cookie" decision
      from findings B-028 + C-120. Extends GEP-48's session-cookie
      refinement.
---

# GEP-0049: One-time bootstrap token → rotating per-session cookie

## Problem

GEP-48 made the `dashboard_token` mandatory and added a session-cookie
affordance so the operator only has to paste `?token=…` once. But the
long-lived config token is still a **recurring bearer credential**: the
`?token=` query path is accepted on *every* request, not just the first
(`lib/glorbo_web/plugs/dashboard_token.ex`, `query_token/1`). Two
findings flow from this:

- **B-028 (dashboard token leaked in CLI startup URLs).** `glorbo serve`,
  `glorbo up`, and `glorbo status` print
  `http://127.0.0.1:4000/?token=<token>`. The token is the *same*
  long-lived secret stored in `config.md`, so any capture of that banner
  (process supervisor, `systemd` journal, scrollback, support bundle,
  shell history) is a durable credential leak — not a one-time login
  artefact.
- **C-120 (token exposed through URL query strings).** Because the
  query-param path stays live, the raw config token can re-enter the
  address bar at any time (operator habit, a bookmark, a doc). On any
  such navigation, an agent-authored markdown link → external site →
  `Referer: …/?token=…` leaks the long-lived secret to an attacker who
  then has standing dashboard + MCP access.

The current session cookie (GEP-48) only stores a `sha256` *fingerprint*
of the config token. That bounds the cookie's value but does **not**
demote the config token: the token remains a valid bearer forever, so a
single leak of the banner or a single Referer leak compromises the
deployment until the operator manually rotates `config.md`.

The operator's decision (captured on both findings):

> "Once the token is used it should be discarded — a new session token
> should be generated and stored as a cookie."

This GEP turns the config `dashboard_token` into a **one-time bootstrap
credential** and makes a freshly-minted, per-session, cookie-stored
token the recurring credential.

## Goals

- The config `dashboard_token` is accepted from `?token=` **once per
  session bootstrap**. On first successful auth it is *consumed*: a
  fresh random per-session token is minted and stored in the signed
  session cookie, and the config token stops being accepted for that
  session.
- On the first authenticated hit, redirect to the token-less URL so the
  raw token never lingers in history / Referer beyond the redirect
  response (folds in C-120's recommended hardening).
- The recurring credential is the per-session token in the signed
  cookie, never the long-lived config token.
- Logout (or session expiry) discards the per-session token; the
  operator must re-bootstrap from a `?token=` URL.
- Rotating `dashboard_token:` in `config.md` invalidates every
  outstanding per-session token (existing GEP-48 behaviour preserved).
- MCP (`/mcp`, `:api` pipeline, no session) keeps its stateless
  `Authorization: Bearer <config-token>` behaviour — see Design §MCP.

## Non-goals

- **Multi-user / multi-token.** Still one operator, one config token.
  Per-session tokens are per-browser-session, not per-user.
- **A token-rotation UI.** Config-token rotation stays "edit
  `config.md`," as in GEP-48.
- **A short hard-coded TTL on the bootstrap token itself** (C-120's
  follow-up comment floated 15 min). The config token is a stable
  bootstrap credential the operator pastes on demand; a 15-minute
  expiry on the *config* value would break `glorbo status` showing a
  usable URL. The per-session token gets the bounded lifetime instead
  (see D4). Whether to additionally cap the *bootstrap window* is an
  open question.
- **Changing the HTTP bind or epmd** (GEP-48 already did).
- **CSRF on state-changing GET routes** (C-131) — tracked separately,
  but this GEP must not regress it (see Failure modes).

## Design

### Credential model

Two distinct credentials after this GEP:

| Credential | Source | Lifetime | Accepted on |
|---|---|---|---|
| **Bootstrap token** (`dashboard_token`) | `config.md`, 0600 | Stable until operator rotates | `?token=` query param **for an unauthenticated session only**; `Authorization: Bearer` on MCP |
| **Per-session token** | minted at first auth | Until logout / session expiry / config-token rotation | the signed session cookie (browser pipeline only) |

The config token degrades from "recurring bearer" to "bootstrap
credential": you can start a session with it, but once a session holds
a per-session token, the config token is no longer consulted for that
session.

### Plug flow (`GlorboWeb.Plugs.DashboardToken`, `:browser` pipeline)

On each request, in order:

1. **Session already authenticated?** The signed session holds
   `{:glorbo_session_token, <random>}` AND a `sha256` fingerprint of the
   *config token that minted it* (the GEP-48 fingerprint, kept for
   config-rotation invalidation). If the stored fingerprint still
   matches `sha256(current dashboard_token)`, the session is valid →
   pass through. The `?token=` query param is **ignored** in this state
   (no re-accepting the bootstrap token mid-session).
2. **Not yet authenticated, `?token=` present and equals the config
   token (constant-time compare, T-04-14)?** This is a bootstrap:
   - Mint a per-session token: `:crypto.strong_rand_bytes(32) |>
     Base.url_encode64()`.
   - Store `{token, fingerprint, minted_at}` in the signed session.
   - `redirect` to the same path **with `token` stripped from the query
     string** (302). The Set-Cookie on the redirect response carries the
     session; the redirected GET authenticates by cookie. The raw config
     token never appears in history/Referer past the redirect.
3. **Not authenticated, no/invalid `?token=`** → `401`.
4. **Config token nil/empty at runtime** → `500 server
   misconfiguration` + halt (GEP-48 D3, unchanged).

The per-session token value is opaque and lives only in the signed,
encrypted-at-rest session cookie. It is never reflected into a URL, a
log, or a response body.

### Logout

A new `DELETE`/`POST /logout` action (and a sidebar control) calls
`Plug.Conn.configure_session(conn, drop: true)`, discarding the
per-session token. The next request is unauthenticated → `401` until the
operator re-bootstraps from a `?token=` URL. This satisfies "the token
should be discarded" on the explicit-logout path as well as on natural
session expiry.

### Config-token rotation

Unchanged from GEP-48 and load-bearing here: the session stores the
`sha256` fingerprint of the config token that bootstrapped it. When the
operator edits `dashboard_token:` in `config.md` and restarts,
`sha256(new token) ≠ stored fingerprint`, so **every** outstanding
per-session token is rejected at step 1 and falls through to `401`.
Rotating the config token is the global "log everyone out" lever.

### MCP implications

`/mcp` rides the `:api` pipeline with **no session** (GEP-29, GEP-48).
There is no cookie to rotate into, and MCP clients re-send the bearer
on every request by design. So:

- MCP continues to accept `Authorization: Bearer <config-token>` on
  every request. The config token remains MCP's recurring credential.
- The one-time-rotation model is **browser-session-only**. MCP cannot
  be bootstrapped-then-rotated because it is stateless by contract.
- Consequence the operator must accept: the config token stays a live
  MCP credential. The reduction in exposure is on the *browser* surface
  (no recurring `?token=`, no Referer leak of a live recurring token),
  not the MCP surface. Demoting the MCP credential would require a
  stateful MCP session handshake — out of scope, noted in Open
  questions.

### CLI banner changes (B-028)

With the config token demoted to bootstrap-only, the banner URL is now
a *bootstrap* URL, not a recurring credential — but it still authorises
session creation, so it is still a secret worth not persisting:

- `glorbo serve` (foreground, attached TTY): print the full
  `?token=` bootstrap URL **only when stdout is a TTY**. This is the
  documented interactive login surface.
- `glorbo up` (daemonises): the returned/persisted result string prints
  the **token-less** `http://127.0.0.1:4000` plus a non-secret pointer
  ("bootstrap token in `~/.glorbo/config.md`"). The daemon's stdout is
  detached and most likely to be captured.
- `glorbo status`: **never** prints the token (also fixes B-027); prints
  the token-less URL + the pointer.

## Migration / rollout

- Pre-1.0, no kid gloves: the recurring `?token=` acceptance is removed
  outright once a session is authenticated. No dual-reader window.
- Existing sessions: on first request after upgrade, an old GEP-48
  cookie (fingerprint-only, no per-session token) is treated as
  *unauthenticated* → operator re-bootstraps once from the URL. Cheap
  one-time re-login.
- No `config.md` schema change; `dashboard_token` keeps its meaning,
  only its acceptance scope narrows.

## Failure modes

| Failure | Surface |
|---|---|
| Session cookie tampered/forged | signed session verification fails → unauthenticated → `401` |
| Operator pastes a stale `?token=` after rotating config | fingerprint mismatch → `401`; re-bootstrap needed (correct) |
| Per-session token leaks (e.g. cookie stolen) | bounded by session lifetime + config-token rotation; not a long-lived config-secret leak (the win over today) |
| Redirect strips `token` but client re-submits cached URL | second submit hits an already-authenticated session → `token` ignored at step 1; no re-bootstrap |
| State-changing GET during bootstrap redirect | the 302 is a GET→GET redirect; must not auto-execute a mutation (keep C-131 in mind — the redirect target must be a safe view, e.g. `/companies`) |
| MCP client sends `?token=` instead of bearer | unchanged: `:api` pipeline accepts the bearer header; query path on `/mcp` is not the supported MCP auth |

## Test strategy

- `GlorboWeb.Plugs.DashboardTokenTest`:
  - first `?token=` (valid) → 302 redirect to token-less path + session
    has a per-session token + fingerprint;
  - authenticated session ignores a *different* `?token=` value (no
    re-bootstrap, no privilege change);
  - config-token rotation (changed app env) invalidates an existing
    per-session cookie → 401;
  - nil/empty config token → 500 (GEP-48 regression guard).
- Logout test: `drop: true` clears the session → next request 401.
- `Glorbo.CLI.ServeTest` / `UpTest` / `StatusTest`: TTY vs non-TTY
  banner; `up`/`status` never emit the token.
- MCP contract test (`:api` pipeline): bearer still accepted; no
  session minted.

## Open questions

- **Per-session token TTL.** Fixed (e.g. 12 h) vs sliding vs
  cookie-session-lifetime only? C-120's comment suggested 15 min for a
  bootstrap token; that's too short for a working dashboard session.
  Leaning sliding-with-cap; deferred to implementation. (D4.)
- **Bootstrap-window cap.** Should the config token only be acceptable
  from `?token=` for the first N minutes after boot, or indefinitely?
  Indefinite is simpler and matches "operator pastes on demand"; a cap
  would shrink the leaked-banner window but break `glorbo status` URLs.
- **Demoting the MCP credential.** A stateful MCP session handshake
  would let MCP rotate too, but adds a contract MCP clients don't expect.
  Deferred unless an MCP credential leak becomes a concrete concern.

## Decision log

### D1. Config token becomes a one-time bootstrap credential, not a recurring bearer

- **Decided:** `?token=` is accepted only to bootstrap an
  *unauthenticated* session; once a session holds a per-session token,
  the config token is no longer consulted for that session.
- **Alternatives:** keep accepting `?token=` on every request (status
  quo, GEP-48); blanket-redact the token from all CLI output without
  changing the auth model.
- **Why:** the operator's explicit call — "once the token is used it
  should be discarded." It is the only change that turns a *durable*
  config-secret leak (B-028 banner capture, C-120 Referer) into a
  bounded per-session-token leak. Operator decision dated 2026-05-22.

### D2. Mint a fresh random per-session token; store opaque value in the signed cookie

- **Decided:** on bootstrap, generate a 32-byte url-safe random token,
  store the opaque value in the signed session, keep the GEP-48
  config-token fingerprint alongside it for rotation invalidation.
- **Alternatives:** keep storing only the fingerprint (GEP-48); store
  the raw config token in the cookie.
- **Why:** an independent per-session secret means the recurring
  credential is decoupled from the long-lived config secret; stealing
  the cookie yields a session-scoped, rotation-revocable token, not the
  config token. Storing the raw config token in the cookie would
  re-expose the long-lived secret.

### D3. Strip `?token=` via redirect on first authenticated hit

- **Decided:** the bootstrap response is a 302 to the same path with
  `token` removed; the Set-Cookie carries auth forward.
- **Alternatives:** leave `?token=` in the address bar (status quo);
  rewrite history client-side via JS.
- **Why:** folds in C-120's recommended hardening — the raw token never
  sits in history/Referer beyond the single redirect. Server-side
  redirect is robust and doesn't depend on JS.

### D4. Per-session token carries the bounded lifetime, not the config token

- **Decided:** the lifetime cap (C-120's "short-lived, invalidate after
  use" intent) lands on the per-session token, while the config token
  stays a stable bootstrap credential.
- **Alternatives:** put a 15-minute TTL on the config `dashboard_token`
  itself.
- **Why:** a 15-minute config token would make every `glorbo status`
  URL stale and force constant `config.md` rotation. Putting the bound
  on the session token achieves "invalidated after use / short-lived"
  for the recurring credential without breaking the bootstrap UX.

### D5. MCP stays stateless bearer; rotation is browser-only

- **Decided:** `/mcp` keeps `Authorization: Bearer <config-token>` on
  every request; the one-time-rotation model applies only to the
  browser session.
- **Alternatives:** add a stateful MCP session/handshake so MCP can
  rotate too.
- **Why:** MCP has no cookie and clients re-send the bearer by contract
  (GEP-29). A handshake would break existing MCP clients for a surface
  whose recurring-bearer exposure is lower than the browser's (no
  Referer/history vector). Demoting the MCP credential is deferred.

## Related

- GEP-48 — Local auth hardening (mandatory token + session-cookie
  fingerprint). This GEP extends GEP-48's §"Session cookie" refinement.
- GEP-29 — Glorbo MCP server (the stateless `:api` surface).
- Finding B-028 — dashboard token leaked in CLI startup URLs.
- Finding C-120 — dashboard token exposed through URL query strings.
- Finding C-131 — session-auth CSRF on state-changing GET routes
  (tracked separately; the bootstrap redirect must not regress it).
- Threatmodel T-04-05 (secret leakage), T-04-14 (timing-safe token
  compare).
