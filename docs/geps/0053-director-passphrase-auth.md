---
gep: 0053
title: Director passphrase login — browser auth distinct from the MCP/CLI token
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Draft
type: Standards
created: 2026-05-29
requires: [48]
see-also: [29, 49]
history:
  - date: 2026-05-29
    status: Draft
    note: |
      Initial draft. Captures the operator's brainstormed decisions
      (browser=passphrase, MCP/CLI=token, first-run web wizard, token
      grants no browser access once a passphrase is set) and folds in a
      six-lens adversarial security red-team (2 critical, 7 high
      findings) run against the locked design before drafting.
  - date: 2026-05-29
    status: Draft
    note: |
      Amended hashing from Argon2id to PBKDF2-HMAC-SHA512 (pbkdf2_elixir,
      pure Elixir) during implementation — argon2_elixir is a build-time
      C NIF that collides with the repo's pure-Elixir-preserves-Burrito
      rule for the 4-target cross-build. Operator decision; see D13.
---

# GEP-0053: Director passphrase login — browser auth distinct from the MCP/CLI token

## Problem

Glorbo's only browser credential today is the shared `dashboard_token`
(GEP-48): a single long-lived secret that authenticates the web
dashboard, the MCP endpoint, and the CLI alike. It is something the
operator *has* (a 128-bit string), not something they *know*, and it is
printed in the `glorbo serve` / `glorbo up` startup banner
(`build_url/0`, `lib/glorbo/cli/lifecycle/serve.ex:111`;
`lib/glorbo/cli/lifecycle/up.ex:74`). Any capture of that banner — a
supervisor log, the `systemd` journal, terminal scrollback, a support
bundle, shell history, or a `Referer` leak (C-120) — is a durable
credential leak that grants full dashboard access until the operator
hand-rotates `config.md`. GEP-49 (Draft) tackles the *leak surface* by
demoting the token to a one-time bootstrap and minting rotating session
tokens, but it keeps the token as the sole human credential.

The director wants a **passphrase** — a secret they know, that never
appears in a banner or a URL — to gate the browser dashboard, while
MCP clients and CLIs (which are non-interactive and cannot type a
passphrase) keep using the `dashboard_token` as a Bearer API key. The
passphrase must be *real* security: once it exists, capturing the token
must not grant a browser session.

## Goals

- The browser dashboard requires a **director passphrase**
  (PBKDF2-HMAC-SHA512 at rest), entered at a `/login` form, riding a
  signed session cookie thereafter.
- The passphrase is established through a **first-run web setup
  wizard** (`/setup`), not a CLI step or a hand-edited config file.
- MCP and CLI keep the existing `dashboard_token` Bearer/`?token=`
  credential, on the `:api` and `:mcp` pipelines, **unchanged**.
- **Once a passphrase is set, the token grants no browser access.** The
  token authorises the browser *only* in bootstrap mode (no passphrase
  yet), purely to reach `/setup`. After setup, the browser strictly
  requires the passphrase session.
- Auth is enforced on **every browser transport** — the dead-render
  HTTP request *and* the persistent LiveView WebSocket.
- A **recovery path** (`glorbo reset-password`) exists for a forgotten
  passphrase, with an explicit running-daemon contract.
- Every state-changing endpoint is **CSRF-protected**; no GET handler
  mutates state.

## Non-goals

- Multi-user / RBAC. Glorbo stays single-user-per-instance
  (project-profile: "single-user-per-instance product model"). One
  passphrase, one director.
- Replacing the `dashboard_token` for MCP/CLI. Two credential types,
  two audiences, deliberately.
- Server-side session storage / per-session token rotation — that is
  GEP-49's scope. This GEP uses the existing `store: :cookie` session
  and notes where GEP-49 would strengthen revocation.
- TLS termination. The dashboard remains plain HTTP on loopback; LAN
  exposure is an operator decision with documented caveats (see Failure
  modes).
- Passphrase strength meters, rotation schedules, or a credential vault.

## Design

### Overview

Two credential domains, split by pipeline:

| Pipeline | Audience | Credential | Plug |
|---|---|---|---|
| `:browser` | Human dashboard | Director passphrase → `director_auth` session cookie | **`GlorboWeb.DirectorAuth`** (new) |
| `:api`, `:mcp` | MCP clients, CLIs | `dashboard_token` Bearer / `?token=` | `GlorboWeb.Plugs.DashboardToken` (unchanged) |

`DashboardToken` is **removed from the `:browser` pipeline** and stays
only on `:api`/`:mcp`. This guarantees the token can never mint a
browser session in CONFIGURED mode (D2).

### Auth state machine

State is keyed on the presence of a **structurally valid** PBKDF2 hash
(`director_password_hash`) — not mere key presence (D9, fail-closed).

**BOOTSTRAP** (no valid hash):
- Browser: a valid `dashboard_token` (`?token=` or a bootstrap session)
  is required, and the request is **forced to `/setup`** for every
  other route. No long-lived tokenless window.
- MCP/CLI: token works.

**CONFIGURED** (valid hash present):
- Browser: a valid `director_auth` passphrase session is required;
  otherwise `redirect(to: ~p"/login")`. The token grants **no** browser
  access. `/setup` returns 404/redirect (single-shot — D7).
- MCP/CLI: token works (pipelines untouched).

**DEGRADED** (config load failed, or hash present-but-malformed): browser
**fails closed** — a `503`/error page, never an auto-downgrade to
BOOTSTRAP (D9, D10).

### New module: `GlorboWeb.DirectorAuth`

A plug **and** an `on_mount` hook (one module, two entry points), so the
same authority covers the dead render and the LiveView socket.

```elixir
# plug (on :browser, replaces DashboardToken there)
def call(conn, _opts) do
  case auth_state() do
    :degraded   -> conn |> fail_closed() |> halt()
    {:bootstrap, token} -> require_token_then_force_setup(conn, token)
    {:configured, hash} -> require_passphrase_session(conn, hash)
  end
end

# on_mount (authoritative for the WS socket — see "Socket auth")
def on_mount(:ensure_director, _params, session, socket) do
  case auth_state() do
    {:configured, hash} ->
      if valid_marker?(session, hash) do
        {:cont, schedule_revalidation(socket)}
      else
        {:halt, redirect_to_login(socket)}
      end
    _ -> {:halt, redirect_to_login(socket)}
  end
end
```

`auth_state/0` reads the runtime source of truth (D3). `valid_marker?/2`
constant-time-compares the session marker to the live hash fingerprint
(D5).

### Socket auth (the critical lever)

The entire dashboard is LiveView, and the persistent `/live` socket
**bypasses the router pipeline** — plugs run only on the initial dead
render; the WebSocket decodes the session cookie once at connect
(`endpoint.ex:14`) and there is currently **no `on_mount` auth hook**
(the only `on_mount`, `GlorboWeb.Layouts.on_mount(:default, …)`, just
seeds layout assigns — it does no auth). A `:browser`-only plug would
therefore be wholly bypassed over the socket.

Fix: wrap **all** dashboard `live` routes in

```elixir
live_session :director, on_mount: {GlorboWeb.DirectorAuth, :ensure_director} do
  live "/companies", OverviewLive
  # … every dashboard LiveView
end
```

The `on_mount` hook is **load-bearing**; the plug alone is insufficient.
It runs on both the dead-render mount and the connected (WS) mount.

### Session marker

- **Marker** = `sha256("director-session/v1|" <> hash) |> Base.url_encode64(padding: false)`
  — a domain-separated fingerprint of the *full encoded PBKDF2 hash
  string* (which embeds its own random salt). Changing or resetting the
  passphrase changes the hash → changes the marker → every outstanding
  cookie falls dead (D5).
- **Session key**: `"director_auth"`, distinct from GEP-48's
  `"dashboard_auth"`. `DirectorAuth` checks **only** `director_auth` and
  never honors `dashboard_auth` (D2). Compared with
  `Plug.Crypto.secure_compare/2`.
- **Fixation**: `configure_session(conn, renew: true)` immediately
  before writing the marker, on **both** `/setup` success and `/login`
  success. Bare `put_session` (GEP-48's pattern) is insufficient (D4).
- **Cookie flags**: `http_only: true` set explicitly on
  `@session_options` (not left implicit). `secure:` stays off because
  the dashboard is plain HTTP on loopback — documented gap, see Failure
  modes.
- **Lifetime**: a 14-day absolute `max_age` **plus** a sliding idle
  timeout — `last_seen` stored in the signed session, rejected if older
  than the idle window (default 72h, tunable). Shrinks the leaked-cookie
  window without re-login friction for an active operator (D6).

### Routes

All three go through `:browser` → `protect_from_forgery` applies. Forms
use `Phoenix.Component.<.form>`, which auto-injects `_csrf_token`. **No
per-route `protect_from_forgery` skip is permitted** (D8) — skipping
`/setup` would make it a remote passphrase-planting CSRF.

| Route | Method | Mode | Behaviour |
|---|---|---|---|
| `/setup` | GET/POST | BOOTSTRAP only + valid token | Sets the PBKDF2 hash, `renew`s + opens session, redirects in. Single-shot: re-reads disk inside the write critical section and rejects if a hash already exists (409/redirect). 404/redirect in CONFIGURED. |
| `/login` | GET/POST | CONFIGURED only | Verifies passphrase, `renew`s + sets marker, redirects to a same-origin target. Generic error. Rate-limited *before* hashing. |
| `/logout` | POST | any | `configure_session(conn, drop: true)`; broadcasts a socket disconnect. |

**Post-auth redirect**: default to `~p"/companies"`. If a `return_to`
is honored it MUST pass the existing same-origin guard
(`DashboardToken.safe_request_path?/1`,
`lib/glorbo_web/plugs/dashboard_token.ex:164` — starts with a single
`/`, no `//`, no scheme delimiter / backslash / CR-LF / NUL); reject →
default (D11).

### Passphrase verification & timing

The `/login` POST handler is the single decision point and performs
**one PBKDF2-cost unit of work in every mode** (D12):

- CONFIGURED, any passphrase: `Pbkdf2.verify_pass(supplied, hash)`.
- No-hash / wrong-mode path: `Pbkdf2.verify_pass(supplied, @reference_hash)`
  where `@reference_hash` is a compile-time constant PBKDF2 hash
  generated with the **same** round count as production — *not*
  `Pbkdf2.no_user_verify/0`, whose cost is read from mutable
  `:pbkdf2_elixir` app-env and can desync from the stored hash's
  envelope rounds (D12).

Cost is **pinned** (D13): PBKDF2-HMAC-SHA512, `rounds: 210_000` (OWASP
2023 minimum for PBKDF2-SHA512). The stored hash's own
`$pbkdf2-sha512$<rounds>$…` envelope is the source of truth for verify
cost. Pure Elixir — no NIF, so the Burrito cross-build to all four
targets is unaffected (the reason PBKDF2 was chosen over Argon2id — see
D13).

The route-level distinction (`/setup` reachable vs `/login` reachable)
remains an observable BOOTSTRAP-vs-CONFIGURED oracle; this is an
**accepted leak** (knowing "a passphrase is set" is not actionable for a
remote attacker on a loopback single-user box) and is *not* something
`no_user_verify` could hide (D12).

### Rate limiting (escalating delay, no hard lockout)

A single O(1) global throttle (one GenServer / one ETS row: `last_attempt`,
`current_backoff`), consulted **before** any PBKDF2 call on both
`/login` and `/setup` POSTs (D14):

1. On POST, read the throttle. If inside the backoff window, return the
   generic error **immediately** (no `Process.sleep`, no PBKDF2) with a
   `Retry-After`-style next-allowed time.
2. Otherwise run the single PBKDF2 verify; on failure, grow the backoff
   (exponential, capped at a fixed max e.g. 2–5 s); on success, clear it.

**Binary lockout is rejected** (D15): on single-IP loopback the counter
is effectively global, so a lockout lets any local process (or an
attacker who reached the port) lock out the *sole* director indefinitely
— a self-inflicted DoS against a product whose entire value is the
operator reaching the dashboard. The escalating delay self-clears, needs
no escape hatch, and an exponential-backoff-capped throttle still
reduces a brute-forcer to a handful of guesses/minute (irrelevant
against a real passphrase + 210k-round PBKDF2). No attacker-controlled
value is ever used as a throttle key, so the table cannot grow.

### Config storage

`director_password_hash` is added to `config.md` frontmatter:

- **FileSpec** (`lib/glorbo/file_spec/config_md.ex`): add to
  `canonical_key_order/0` (after `:port`, before `:created_at`) and the
  frontmatter schema as optional.
- **`Config.coerce/1`** (`lib/glorbo/config.ex:72`): extract + validate
  the hash shape (`^\$pbkdf2-sha512\$`); a present-but-malformed value
  is a hard error (DEGRADED), **not** `nil` (D9).
- **Write**: always emitted as a **double-quoted** YAML scalar (extend
  `needs_quoting?/1`, `lib/glorbo/file_spec/formatter.ex:318`, to quote
  `$`-leading values — the PBKDF2 hash is `$pbkdf2-sha512$…`) so `mix
  glorbo fmt` and the patch writers can never corrupt the credential into
  an unparseable file (D16). Reuse
  `atomic_write_secret!/2` (`config.ex:286` — `:exclusive` open, chmod
  0600, atomic rename).
- **App-env wiring**: `config/runtime.exs` gains
  `config :glorbo, :director_password_hash, cfg.director_password_hash`,
  mirrored in the dev-parity block.

### Runtime source-of-truth & state propagation (D3)

`auth_state/0` resolves state with **immediate** effect inside the
running node:

- `/setup`'s POST handler runs **in the daemon**, so after the atomic
  file write it calls
  `Application.put_env(:glorbo, :director_password_hash, hash)` — the
  gate engages on the very next request, no restart.
- `glorbo reset-password` runs in a **separate** short-lived CLI BEAM
  and cannot mutate the daemon's env. Contract (D17): it **refuses with
  a loud "stop the server first" message if the pidfile shows a running
  instance** (and the daemon re-derives state from `config.md` on its
  next boot). Optional follow-up: a control-plane RPC that reloads
  in-place.
- A `config.md` that **fails to parse once a hash has ever been set** is
  a **fatal** boot error (or a 503 "config unreadable" endpoint), not
  the current soft fallback to an ephemeral tokenless map
  (`runtime.exs:44`). `director_password_hash` is dropped from the
  ephemeral fallback map entirely (D10).

### CLI surface

- **`glorbo reset-password`** — new lifecycle verb
  (`lib/glorbo/cli/lifecycle/reset_password.ex`, dispatched from
  `lib/glorbo/cli.ex`). Removes `director_password_hash` from
  `config.md` (atomic write) → instance returns to BOOTSTRAP on next
  boot → token URL reaches `/setup` again. Refuses while the daemon runs
  (D17). Emits an audit event.
- **Banner (D18)**: `serve`/`up` `build_url/0` becomes **state-aware** —
  prints the `?token=` URL only in BOOTSTRAP; once a hash exists it
  prints the bare `http://127.0.0.1:<port>/login` with no token. Keeps
  the bearer secret out of scrollback once it's no longer the way in.

### `redirect_to_dm` CSRF fix (folded in)

`GET /companies/:c/dms/:agent` (`page_controller.ex:24`) currently calls
`ensure_dm_channel/3` → `File.mkdir_p!` + `File.write!` on a *safe-method*
request — a state-changing GET, forgeable via a top-level navigation
under `SameSite=Lax`. Fix: make the GET **pure-redirect** (no `File.*`
side effect); `ChannelLive.mount` (or the first message post) creates the
channel file lazily. Establish the invariant **"no GET handler mutates
disk/DB state"** with a test (D19).

## Migration / rollout

Pre-1.0, atomic cut (project-profile: no soft-migration shims).

1. **Existing instances** (token already in `config.md`, no passphrase):
   boot into BOOTSTRAP. The next browser visit via the token URL is
   forced to `/setup`. Until the operator sets a passphrase, the token
   still gates the browser (so no one is locked out by the upgrade).
2. **Fresh installs**: first boot generates the token (unchanged);
   first browser visit → `/setup`.
3. `dashboard_token` semantics for MCP/CLI are **unchanged** — no client
   reconfiguration.
4. Add `{:pbkdf2_elixir, "~> 2.2"}` (pure Elixir, no NIF) to `mix.exs`.
   Set `config :pbkdf2_elixir, rounds: 210_000` in `config/config.exs`
   and override `rounds: 1` in `config/test.exs`; generate test fixtures'
   hashes at `rounds: 1` (D13, so a fast dummy never mixes with a
   high-rounds fixture).
5. No `reindex` needed — `config.md` is not a derived projection.

## Failure modes

| Failure | Surfacing | Mitigation |
|---|---|---|
| **Malformed/blanked hash** in `config.md` | DEGRADED 503 + "run glorbo reset-password" | Validate `$pbkdf2-sha512$…` shape; fail closed, never downgrade to BOOTSTRAP (D9) |
| **`config.md` unparseable** post-configuration | Fatal boot / 503 | No ephemeral tokenless fallback once a hash existed (D10) |
| **`reset-password` while daemon running** | CLI refuses, prints "stop server" | Daemon re-reads on next boot; in-place reset is no-op otherwise (D17) |
| **Leaked session cookie** | — | 14-day cap + 72h idle timeout; "change passphrase" rotates the marker and kills all cookies. `store: :cookie` gives no instant server-side revoke — GEP-49's server-side store would (see-also) |
| **Live socket survives logout/reset** | — | `on_mount` revalidation timer (~60 s) re-checks the marker and disconnects; logout broadcasts a socket disconnect (D1) |
| **`/login` flood** | — | Throttle rejects pre-PBKDF2; no CPU burned for throttled attempts; immediate rejection holds no connection (D14) |
| **DoS-by-lockout** | — | No hard lockout — escalating delay self-clears (D15) |
| **Plain HTTP on LAN** (`host: 0.0.0.0`) | — | No `Secure` flag → cookie sniffable in transit. Loud startup warning when `host != 127.0.0.1`; operator must set `PHX_HOST` so `check_origin` matches, and is warned that director sessions are unprotected without TLS. Default bind stays loopback (D20) |
| **Passphrase in logs/crash dump** | — | Add `password`/`passphrase`/`new_passphrase` to `:phoenix, :filter_parameters`; controller never assigns/sessions/echoes the plaintext; recommend `ERL_CRASH_DUMP` to a 0600 path or `/dev/null` (D21) |
| **Hash corrupted by `mix glorbo fmt`** | unparseable config | Hash always double-quoted; fmt round-trip test (D16) |

## Test strategy

- **Plug** (`DirectorAuth`): BOOTSTRAP forces `/setup` with a valid
  token; CONFIGURED with no `director_auth` marker redirects to
  `/login`; a request bearing a valid GEP-48 `dashboard_auth` fingerprint
  but no passphrase marker against a CONFIGURED instance **redirects to
  `/login`** (token grants no browser access); DEGRADED fails closed.
- **`on_mount`** (the load-bearing one): a connected LiveView whose
  passphrase is reset mid-session is forced to `/login` on the next
  mount/reconnect, and the revalidation timer disconnects it within the
  window.
- **State propagation**: after `/setup` POST, an immediate GET `/` in the
  *same running process* is gated to the passphrase session and the
  token no longer reaches `/setup`; after `reset-password` (+ restart),
  an immediate request falls back to `/setup`.
- **Session**: pre-auth and post-auth cookie values differ (fixation);
  logout uses `drop: true`; idle-timeout rejection.
- **CSRF**: POST `/setup` and `/login` **without** `_csrf_token` →
  403/invalid; **with** the token → success (proves the form embeds it).
- **Single-shot `/setup`**: a second POST (concurrent or later) is
  rejected by the in-write-critical-section re-read.
- **Throttle**: the (N+1)th rapid attempt is rejected **before** PBKDF2
  (assert no hash cost incurred); backoff self-clears; success clears it.
- **Timing**: `/login` performs one PBKDF2 verify in both no-hash and
  wrong-pass modes (reference hash, matching rounds).
- **CSRF/GET**: `GET /companies/:c/dms/:agent` creates **no** file;
  `return_to=//evil.tld` and `=https://evil.tld` both land on
  `/companies`.
- **Config**: hash round-trips `write → load → fmt --write → load`
  byte-identically incl. YAML-significant bytes; malformed hash →
  DEGRADED; no passphrase appears in logs.
- **E2E (UAT)**: fresh workspace → token URL → `/setup` → set passphrase
  → `/login` → dashboard; token URL now bounces to `/login`; MCP Bearer
  still works.

## Open questions

1. **Session TTL.** Default proposed: 14-day absolute + 72h sliding idle.
   Tighter (e.g. 72h absolute) is more Paranoid but adds re-login
   friction. Operator call on review.
2. **In-place reset RPC.** Ship `reset-password` as "refuse while
   running" first (D17), or also build the control-plane reload now?
   Leaning: refuse-first, RPC as a follow-up.
3. **`SameSite` Strict vs Lax.** Strict removes the top-level-GET vector
   wholesale but drops the cookie on the first pasted `?token=` bootstrap
   hop. Keep Lax for the bootstrap deep-link, harden every state-changing
   route to POST+CSRF (D19)? Or split per-route?
4. **Relationship to GEP-49.** This GEP makes the passphrase the human
   credential; GEP-49's rotating per-session token + server-side store
   would make revocation *enforceable* (closes the live-socket and
   leaked-cookie residual risks here). Does GEP-49 get re-scoped to "the
   session-store layer under GEP-53", or stay independent?

## Decision log

### D1. Auth is enforced at the socket layer, not just the dead-render plug
- **Decided:** `live_session` + a `DirectorAuth.on_mount` hook is the
  authoritative gate for every dashboard LiveView, with a periodic
  revalidation timer; the `:browser` plug covers only non-live routes.
- **Alternatives:** plug-only (status quo shape) — bypassed by the WS
  connect, which skips the router pipeline.
- **Why:** the entire dashboard is LiveView; a plug-only gate is a
  near-total bypass over the socket. (Red-team critical finding.)

### D2. The token grants no browser access once configured
- **Decided:** remove `DashboardToken` from the `:browser` pipeline;
  `DirectorAuth` checks only the `director_auth` session key and never
  the GEP-48 `dashboard_auth` fingerprint.
- **Alternatives:** token remains a browser bypass (operator rejected in
  brainstorming — makes the passphrase theatre).
- **Why:** a banner/Referer token leak must not yield dashboard access.

### D3. State changes take effect immediately in the running node
- **Decided:** `/setup` (in-daemon) `put_env`s the hash after the atomic
  write; `auth_state/0` reflects it on the next request.
- **Alternatives:** read app-env set only at boot — leaves an indefinite
  BOOTSTRAP window after setup until a restart.
- **Why:** closes the "no long-lived tokenless window" promise for real.

### D4. Session renewed on every auth transition (fixation)
- **Decided:** `configure_session(renew: true)` on `/setup` and `/login`
  success.
- **Alternatives:** bare `put_session` (GEP-48 pattern).
- **Why:** a signed-only cookie reused across the transition is a
  fixation vector, worst at bootstrap→configured.

### D5. Domain-separated `sha256(hash)` session marker
- **Decided:** marker = `sha256("director-session/v1|" <> encoded_hash)`,
  stored under `"director_auth"`, compared constant-time.
- **Alternatives:** store the hash; store a random server-side id
  (=GEP-49).
- **Why:** rotates with the passphrase (free invalidation); domain
  separation prevents cross-confusion with the token fingerprint.

### D6. 14-day absolute cap + sliding idle timeout
- **Decided:** keep the operator's 14-day cap, add a 72h idle timeout.
- **Alternatives:** 14-day only (larger leaked-cookie window); 72h
  absolute (more friction).
- **Why:** shrinks the leak window for an idle cookie at no cost to an
  active single operator. *(Adds to a locked decision — flag on review.)*

### D7. `/setup` is single-shot (compare-and-set on disk)
- **Decided:** the POST re-reads `config.md` inside the write critical
  section and rejects if a hash already exists; serialized.
- **Alternatives:** route-gate only (check-then-act on possibly-stale
  state → concurrent re-plant).
- **Why:** prevents a second/concurrent POST from re-planting a
  passphrase during the bootstrap window.

### D8. `protect_from_forgery` is never skipped per-route
- **Decided:** `/setup`/`/login`/`/logout` use `<.form>` (auto CSRF) and
  stay under `protect_from_forgery`.
- **Alternatives:** skip it "to make the form work" (the predictable
  trap).
- **Why:** skipping `/setup` = a remote passphrase-planting CSRF; these
  are the app's first dead-render POST forms, so the precedent matters.

### D9. Malformed hash fails closed
- **Decided:** validate `$pbkdf2-sha512$…` shape; present-but-invalid →
  DEGRADED deny, never `nil`/BOOTSTRAP.
- **Alternatives:** `maybe_string` mapping `""`→`nil` (current coerce
  behaviour) → silent fail-open.
- **Why:** a corrupt byte must not drop the passphrase wall. (Red-team
  critical.)

### D10. Unparseable config post-configuration is fatal
- **Decided:** once a hash has existed, a parse failure refuses to serve
  the dashboard (or serves a 503), and the ephemeral fallback map carries
  no auth secrets.
- **Why:** the current soft fallback reverts to an ambiguous
  half-configured posture.

### D11. Post-auth redirect is same-origin-guarded
- **Decided:** default `/companies`; any `return_to` must pass
  `safe_request_path?/1`, else default.
- **Why:** `return_to` reflected into `redirect/2` is an open-redirect /
  phishing pivot; the same guard already exists for the token strip and
  in `kanban_live`.

### D12. `/login` does one PBKDF2 unit in every mode; reference hash, not `no_user_verify`
- **Decided:** verify against the stored hash when present, else against a
  compile-time reference hash built with the same rounds. The
  route-level BOOTSTRAP/CONFIGURED distinction is an accepted, documented
  oracle.
- **Alternatives:** `Pbkdf2.no_user_verify/0` (cost from mutable app-env
  → can desync from the stored hash's envelope rounds).
- **Why:** keeps wrong-pass and no-hash timing identical regardless of
  cost-config drift; stops over-claiming what timing-flattening achieves.

### D13. PBKDF2 over Argon2id (pure Elixir preserves Burrito); rounds pinned
- **Decided:** PBKDF2-HMAC-SHA512 via `pbkdf2_elixir`, `rounds: 210_000`
  (OWASP 2023 min for PBKDF2-SHA512); tests run `rounds: 1` with fixtures
  hashed at `rounds: 1`.
- **Alternatives:** Argon2id via `argon2_elixir` (the original spec) —
  stronger (memory-hard) but a build-time C NIF, which collides with the
  repo's "pure-Elixir preserves Burrito" rule for the 4-target
  (incl. macOS) cross-build; the lone shipped NIF (`exqlite`) relies on
  precompiled binaries that `argon2_elixir` lacks.
- **Why:** for a 0600 local single-user passphrase the threat model is
  largely local, so PBKDF2's lack of memory-hardness costs little, while
  pure Elixir removes all Burrito cross-compile risk. Operator decision
  on 2026-05-29 (amended this GEP from Argon2id).

### D14. Rate-limit gates before PBKDF2; immediate rejection, no in-request sleep
- **Decided:** throttle consulted first on `/login` and `/setup`;
  throttled attempts return immediately with a next-allowed time and run
  zero PBKDF2.
- **Alternatives:** verify-then-throttle (every attempt pays PBKDF2);
  `Process.sleep` in-request (holds a Bandit process → connection
  exhaustion).
- **Why:** the limiter must protect the CPU it exists to protect.

### D15. Escalating delay, not binary lockout
- **Decided:** exponential backoff capped at a fixed max; no
  lock-for-N-minutes state.
- **Alternatives:** binary lockout after N failures (the original locked
  decision).
- **Why:** on single-IP loopback a lockout is a trivial DoS against the
  sole director and needs a separate escape hatch; the delay self-clears
  and still defeats brute force against a real passphrase. *(Reverses a
  locked decision — flag on review.)*

### D16. `director_password_hash` always double-quoted
- **Decided:** emit/quote it as a double-quoted YAML scalar in every
  write path; `needs_quoting?/1` quotes `$`-leading values.
- **Why:** a future param string or operator edit introducing `: ` would
  make yamerl raise → unparseable config → fail path; quoting closes it.

### D17. `reset-password` refuses while the daemon runs
- **Decided:** the CLI verb checks the pidfile and refuses with a
  "stop the server first" message; daemon re-derives on next boot.
- **Alternatives:** edit the file under a running daemon (silent no-op
  until restart — the running process keeps the old hash in env).
- **Why:** otherwise recovery from a forgotten/compromised passphrase
  doesn't actually take effect.

### D18. State-aware startup banner
- **Decided:** `serve`/`up` print the `?token=` URL only in BOOTSTRAP;
  bare `/login` once configured.
- **Why:** stops advertising a token that no longer grants browser
  access and keeps it out of scrollback.

### D19. No GET handler mutates state
- **Decided:** `redirect_to_dm` becomes pure-redirect (lazy channel
  creation); enforced as an invariant with a test.
- **Why:** state-changing GETs are CSRF-forgeable under `SameSite=Lax`
  regardless of the auth model.

### D20. Plain HTTP stays; LAN exposure is guarded, not silently secured
- **Decided:** `http_only: true` explicit; `secure:` stays off
  (loopback HTTP); loud warning + `PHX_HOST` requirement when
  `host != 127.0.0.1`; LAN-without-TLS tracked as accepted risk.
- **Alternatives:** blindly `secure: true` (breaks the loopback cookie
  over HTTP).
- **Why:** the cookie's transit protection depends on the bind; surface
  it instead of pretending.

### D21. Passphrase plaintext discipline
- **Decided:** filter `password`/`passphrase`/`new_passphrase` from
  Phoenix param logging; controller holds no copy beyond the PBKDF2 call;
  recommend a guarded `ERL_CRASH_DUMP`.
- **Why:** matches the existing secret-handling discipline (T-04-05) for
  the new credential.

## Related

- **GEP-48** (Implemented) — mandatory `dashboard_token`, session-cookie
  fingerprint, epmd loopback. This GEP builds the passphrase layer on top
  and removes the token from the `:browser` pipeline.
- **GEP-49** (Draft) — one-time bootstrap token → rotating per-session
  cookie + server-side store. Complementary: GEP-49's server-side session
  store is the mechanism that would make the revocation residuals noted in
  Failure modes (leaked cookie, live socket) *enforceable*. Cross-linked;
  scope boundary is an Open question.
- **GEP-29** — MCP server. Confirms `/mcp` stays Bearer/Origin-gated with
  no session path, consistent with D2.
- `docs/knowledge-graph/notes.md` — findings B-028 (token in banners),
  C-120 (Referer leak), C-131 (state-changing-GET CSRF) all referenced
  above.
