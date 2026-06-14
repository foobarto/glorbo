---
gep: 62
title: Multi-instance support via per-instance node identity
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
implemented-in: v0.27.0
type: Standards
created: 2026-06-13
requires: [48]
see-also: [3, 37]
history:
  - date: 2026-06-13
    status: Draft
    note: |
      Filed from the EPMD-recovery work (#54): the hardcoded node name
      `glorbo@127.0.0.1` means two glorbo instances on one machine collide in
      EPMD — the second cannot start, even with distinct GLORBO_HOME + PORT.
      Operator wants multiple isolated instances per box (distinct id, no
      cross-contamination / accidental clustering). Decisions (2026-06-13):
      D1 = random `node_id` minted in each home's config.md → `glorbo-<id>@
      127.0.0.1`; D3 = explicit PORT, fail-fast on clash (no auto-assign).
  - date: 2026-06-13
    status: Accepted
    note: |
      Approved + implemented in the same PR. `Config.node_id/1` mints/persists
      `node_id` in config.md (and `write_default!` now ships it);
      `Distribution.canonical_node/1` builds `glorbo-<id>@127.0.0.1` and the
      #54 EPMD recovery is parameterised by the instance alive-name;
      `Console` derives the remsh target from it; `vm.args.eex` gains
      `-kernel dist_auto_connect never`. Two refinements noted during build:
      (1) the EPMD-recovery sole-registrant gate means a crashed instance can't
      auto-recover its stale registration *while a sibling is live* — safe but
      a documented limitation (Failure modes); (2) `-connect_all false` was
      dropped as redundant with `dist_auto_connect never` for our single-node
      app (D4). PORT fail-fast (D3) endpoint pre-check deferred to a follow-up
      — the threading + identity is the load-bearing part. Flip to Implemented
      on merge to main.
  - date: 2026-06-14
    status: Implemented
    note: |
      Flipped to Implemented. Multi-instance support via per-instance node
      identity (`node_id` minted in config.md; `glorbo-<id>@127.0.0.1`).
      Merged in PR #57, [Unreleased]; `implemented-in:` at the next cut.
---

# GEP-62: Multi-instance support via per-instance node identity

## Problem

Glorbo's Erlang node name is the hardcoded **`glorbo@127.0.0.1`**
(`Glorbo.CLI.Lifecycle.Distribution.@canonical_node`, mirrored in
`Console.@remote_node`). Two glorbo instances on one machine therefore try to
register the *same* name with the shared EPMD, and the second fails to start.
The recent EPMD-recovery work (#54) makes this fail *cleanly* — it probes the
registered port, sees the first instance alive, and refuses with "another
glorbo is already running" — but it confirms the limitation: **glorbo is
single-instance-only per box today**, even with distinct `GLORBO_HOME` and
`PORT`, because the node name is fixed.

An operator may legitimately want several isolated instances on one host
(separate orgs/projects, a throwaway test instance beside the real one). And
whatever the scheme, instances must stay **strictly isolated** — no accidental
clustering or cross-contamination between them.

## Goals

- Multiple glorbo instances coexist on one machine, each fully isolated: its
  own home (`GLORBO_HOME`), its own **unique, stable** Erlang node name, its
  own dashboard port, its own EPMD registration.
- **No accidental clustering / cross-contamination** between instances.
- Transparent + backward-compatible for the single-instance default install.

## Non-goals

- **NOT** distribution/clustering *between* glorbo instances — the opposite:
  strict isolation. Instances never connect to each other.
- **NOT** auto-port-assignment — explicit `PORT` with fail-fast on clash (D3).
- **NOT** multi-instance against a *shared* `GLORBO_HOME` — one home = one
  instance; isolation is per-home.

## Design

### Per-instance node identity (D1)

On first boot, mint a short random instance id (8 hex chars from
`:crypto.strong_rand_bytes`, like the cookie) and persist it in the home's
`config.md` front-matter as `node_id:`. The node name becomes:

    glorbo-<node_id>@127.0.0.1

Stable for a given home (read back from `config.md`), so `up` / `down` /
`status` / `console` all resolve the *same* name. The default single-home
install simply gets one stable id — transparent; the only visible change is the
node name in `glorbo console` / EPMD listings.

### Threading the name (D2)

The node name is set in exactly one runtime path — `Distribution.start/0`'s
`Node.start/2` — because distribution was deliberately removed from
`rel/vm.args.eex` (its old fixed `-name glorbo@127.0.0.1` is precisely what
caused the collision documented there). So no `vm.args` surgery is needed.
Touch-points:

- **`Distribution`** — `canonical_node/0` becomes a function of the home's
  `node_id` (read via `Glorbo.Config`). The EPMD-recovery helpers (`live_owner?`,
  `clear_stale_registration`, the `@alive_name`) are parameterised by the
  instance's alive name (`glorbo-<id>`) instead of the literal `"glorbo"`, so
  the sole-registrant gate + stale-registration recovery target the right name.
  With unique names, two instances no longer collide on EPMD at all — they
  coexist on the shared daemon; recovery only fires for a stale registration of
  the instance's *own* name.
- **`Console`** — `@remote_node` (the remsh target) is computed from the target
  home's `node_id`; the transient `@console_node` stays per-invocation unique.
- **`Glorbo.Config`** — add `node_id` to the generated `config.md` + the loader,
  alongside `erl_cookie`.

### Port (D3)

The dashboard port stays `4000` by default, overridable via `PORT` or
`config.md` `port:`. A second instance must choose a distinct port; if the
chosen port is already bound, glorbo **fails fast** with a clear message rather
than auto-picking a surprise port. (Auto-assign was considered and rejected —
it makes the dashboard URL non-deterministic.)

### Anti-clustering (D4) — already mostly true, made explicit

- **Per-home cookie** (already shipped, GEP-48 / Plan 05-01): each home's
  `config.md` carries an independently-generated 24-byte `erl_cookie`. Distinct
  homes ⇒ distinct cookies ⇒ two instances *cannot* connect even if a name were
  guessed. This is the primary isolation guarantee; keep it.
- **No auto-connect**: glorbo never calls `Node.connect/1` / pings peers (verified
  — single-node app). To harden against any transitive auto-connect, set
  `-kernel dist_auto_connect never` in `rel/vm.args.eex` so the BEAM never
  auto-forms a mesh. (`-connect_all false` was considered but dropped as
  redundant for a single-node app — `dist_auto_connect never` already blocks it;
  `console`'s explicit remsh still works.)
- Loopback-only EPMD + node (`127.0.0.1`) is unchanged (GEP-48 / T-05-04).

## Migration

Forward-only, no data migration (pre-1.0 atomic cut):

- Existing single-instance installs have no `node_id:` in `config.md`. On next
  boot, mint one and append it (same as a missing `erl_cookie` would be
  handled). The node name changes `glorbo@127.0.0.1 → glorbo-<id>@127.0.0.1`,
  but every CLI verb computes it from `config.md`, so `console` etc. keep
  working transparently. A running pre-upgrade daemon should be `glorbo down`'d
  before upgrade (its old `glorbo@127.0.0.1` registration is reaped normally /
  by the #54 recovery).
- No change to `~/.glorbo/` layout or any on-disk format beyond the one new
  `config.md` field.

## Failure modes

- **Port already bound** → today the endpoint bind fails (tree crash); a clean
  "port N in use, set PORT" pre-check message is a deferred follow-up (the
  identity threading is the load-bearing part of this GEP).
- **`config.md` missing `node_id`** → mint + persist (idempotent).
- **`console` with no running instance for this home** → the existing clear
  "glorbo is not running" message (now keyed to the computed name).
- **Two instances racing first-boot on the same home** → out of scope (one home
  = one instance; the pidfile already guards this).
- **Crashed instance can't auto-recover its stale EPMD registration while a
  sibling instance is live** → the #54 recovery's sole-registrant gate refuses
  to kill a *shared* EPMD when other `glorbo-<id>` names are registered (it
  would take the live siblings down). Safe but a documented limitation: the
  stale registration recovers automatically once it's the sole registrant, or
  the operator clears it (restart all / manual). The common single-instance
  case recovers automatically as before.

## Test strategy

- `node_id` minting + persistence + readback from `config.md`; node-name
  computation is deterministic per home.
- **Two-instance coexistence**: two distinct homes → distinct names + cookies +
  ports → both `Distribution.start/0` succeed on the shared EPMD (no collision).
- EPMD-recovery helpers target the instance's alive name (not literal `glorbo`).
- `console` computes the right remsh target for a given home.
- Port-clash fail-fast.

## Open questions

- Should `glorbo status` / the banner surface the node name + port so an
  operator running several instances can tell them apart at a glance? (Lean
  yes — cheap.)
- Is `-kernel dist_auto_connect never` safe for `glorbo console`'s remsh? (It
  connects *to* the named node explicitly; `dist_auto_connect never` blocks
  *automatic* connects, not explicit `Node.connect/1` — needs a quick check.)

## Decision log

### D1. Per-instance random `node_id` in `config.md` *(settled)*
- **Decided:** mint a short random id on first boot, persist as `config.md`
  `node_id:`; node name = `glorbo-<id>@127.0.0.1`.
- **Alternatives:** derive from a hash of `GLORBO_HOME` (no new state, but the
  name changes if the home is moved/renamed + leaks a path hash); an
  operator-set instance name (most explicit, but requires a choice — folds into
  this as an optional override).
- **Why:** stable per-home, survives a home move/rename, trivially read back for
  console attach, and the single-home default is transparent. (Operator
  decision, 2026-06-13.)

### D2. Set the name in `Distribution.start/0` only; no `vm.args` `-name` *(settled)*
- **Decided:** compute the name from `node_id` in `Distribution`; keep
  distribution out of `vm.args` (where a fixed `-name` previously caused the
  very collision this GEP fixes). Parameterise the #54 EPMD-recovery by the
  instance alive name.
- **Why:** one source of truth for the name; reuses the existing CLI-managed
  distribution path.

### D3. Explicit `PORT`, fail-fast on clash *(settled)*
- **Decided:** default 4000; additional instances set `PORT`/`port:`; refuse to
  start on a bound port with a clear message.
- **Alternatives:** auto-assign the next free port (rejected — non-deterministic
  dashboard URL). (Operator decision, 2026-06-13.)

### D4. Isolation by per-home cookie + no auto-connect *(settled)*
- **Decided:** keep the per-home `erl_cookie` (the primary anti-clustering
  guarantee) and add `-kernel dist_auto_connect never` to make the no-mesh
  posture explicit. `-connect_all false` was considered but dropped as
  redundant for a single-node app (and untested via the suite).
- **Why:** distinct cookies already prevent cross-instance connects; the flag
  makes the no-clustering posture explicit + robust without weakening EPMD.

## Related

- GEP-48 (local auth hardening — EPMD loopback + per-home cookie, the isolation
  primitive this builds on) · GEP-3 (filesystem as source of truth — per-home
  isolation) · GEP-37 (`glorbo shell`) · the #54 EPMD stale-registration
  recovery (parameterised here by the instance name).
