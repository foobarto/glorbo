# 2026-05-29 — Director passphrase auth (GEP-0053)

## Task: brainstorm + spec director passphrase login + CSRF sweep

**Task picked:** "add auth (still single user — director), protect every
endpoint from CSRF." Auth wasn't greenfield — GEP-48 already ships a
mandatory `dashboard_token` (Bearer/`?token=` + session-cookie
fingerprint) and `:protect_from_forgery` already covers `:browser`. So
the real ask was a **director passphrase** for the browser, on top of
the token.

**Brainstormed decisions (operator, via AskUserQuestion):**
1. Browser = passphrase; MCP/CLI keep the `dashboard_token` API key.
2. First-run **web setup wizard** establishes the passphrase.
3. Once a passphrase is set, the token grants **no** browser access
   (token = MCP/CLI-only); it reaches `/setup` in bootstrap mode only.
4. Approach **B**: keep `DashboardToken` on `:api`/`:mcp`; new
   `DirectorAuth` plug+on_mount on `:browser`.

**What shipped:** `docs/geps/0053-director-passphrase-auth.md` (Draft) +
reciprocal links (GEP-48 `extended-by: [49, 53]`, GEP-49
`see-also: [29, 53]`). No code yet — spec phase.

**Design calls I made without you (folded red-team fixes in as defaults):**
Ran a 6-lens adversarial security red-team (Workflow, 11 agents) against
the locked design before drafting. It found **2 critical + 7 high**. The
two that change the shape:
- **Critical — LiveView socket bypass.** The dashboard is all LiveView;
  the `/live` WS skips the router pipeline and there's **no auth
  `on_mount`** today (verified: only `layouts.ex:23` `:default`, layout
  assigns). A `:browser`-only plug = near-total bypass over the socket.
  → `live_session` + `DirectorAuth.on_mount` is the authoritative gate
  (D1).
- **Critical — fail-open hash.** `coerce/1` maps `""`→`nil`, so a torn
  write silently flips CONFIGURED→BOOTSTRAP and lets a token-holder
  re-plant a passphrase. → validate `$argon2…$` shape, **fail closed**
  (D9). (Verified `runtime.exs:62` sets `dashboard_token: nil` on parse
  error → D10 fatal-once-configured.)

Two folded fixes **reverse/extend locked decisions** (flagged for review):
- **Binary lockout → escalating-delay throttle** (D15): on single-IP
  loopback a lockout is a DoS against the sole director.
- **14-day cookie → 14-day cap + 72h sliding idle** (D6).

Other highs folded: rate-limit gates *before* Argon2 (D14), session
renew on transition / distinct `director_auth` key / logout `drop: true`
(D2/D4), `<.form>` CSRF + no per-route skip (D8), `redirect_to_dm` GET
→ pure-redirect (D19), `return_to` same-origin guard (D11), reference
hash not `no_user_verify` (D12), hash double-quoted in YAML (D16),
`reset-password` refuses while daemon runs (D17), state-aware banner
(D18), LAN/TLS guard (D20), passphrase log-filter (D21).

**Gates:** verified the 3 load-bearing red-team claims against live code
(no auth on_mount; config nil-fallback; argon2 not yet a dep). Spec
self-review passed (no placeholders, consistent state machine, scope
single-feature).

**Skipped / not done:** no implementation, no `mix` run (spec phase). 4
Open Questions left for the operator (session TTL, in-place reset RPC,
SameSite Strict-vs-Lax, GEP-49 re-scoping).

**Commit(s):** GEP-0053 draft + reciprocal GEP links (local only,
not pushed).

## Things I'd like your review
1. **Lockout reversal (D15):** OK to drop binary lockout for a
   self-clearing escalating delay? (My recommendation — it removes a
   single-user DoS.)
2. **Session TTL (D6):** 14-day cap + 72h idle, or do you want tighter
   (72h absolute)?
3. **SameSite (OQ3):** keep Lax (needs the `?token=` bootstrap deep-link)
   or go Strict and special-case bootstrap?
4. **GEP-49 (OQ4):** re-scope GEP-49 to "the session-store layer under
   GEP-53", or keep it independent?
