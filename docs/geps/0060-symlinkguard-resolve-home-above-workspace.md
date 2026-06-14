---
gep: 60
title: SymlinkGuard must resolve the glorbo home and not trip on system symlinks above it (atomic-distro `/home → /var/home`)
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Draft
type: Standards
created: 2026-06-14
requires: [5]
see-also: [3, 27, 53]
history:
  - date: 2026-06-14
    status: Draft
    note: |
      Placeholder filed from three session journals that all flagged the
      same unbuilt fix and explicitly named this number:
      2026-06-02-paperclip-instance-import ("open a GEP + fix: scope shared
      guard to at/below glorbo home?"), 2026-06-12-gep-batch-elixir-1.20
      ("SymlinkGuard `/home → /var/home` Atomic fix (P1) — should become
      GEP-0060 + test-first implementation"), and 2026-06-12-otp29-bump
      ("SymlinkGuard false-positives on /home → /var/home; GEP-0060 not
      started"). Also the root cause of the operator-reported "default
      glorbo config is broken on this machine" (2026-06-14): the default
      `HOME=/home/<user>` resolves to `/var/home/<user>`, so the guard trips
      on the very first segment. Design + decisions still open — this is a
      Draft, not yet Accepted.
---

# GEP-60: SymlinkGuard must resolve the glorbo home, not trip on system symlinks above it

## Status

**Draft / placeholder.** The problem and the intended fix-direction are
recorded here so the work has a home; the load-bearing decisions (where the
trust anchor sits, where canonicalisation happens) are **not yet locked**.
Do not treat this as Accepted. Implementation is test-first (see §Test
strategy).

## Problem

`Glorbo.Sandbox.SymlinkGuard.assert_no_symlink_segment!/2`
(`lib/glorbo/sandbox/symlink_guard.ex`) walks **every** ancestor of a host
path from `/` down and raises `ArgumentError` if any intermediate component
is a symlink. It is the single canonical guard behind both
`Glorbo.Sandbox.PermissionMapper` (per-agent `--bind`/`--ro-bind` mount
sources) and `Glorbo.Sandbox.Bwrap.approved_path_flags/1` (GEP-27 external
grants). Its job is real and load-bearing: stop an agent that holds
`projects:write:foo` from planting a symlink at `<co>/projects/foo/tasks →
~/.ssh` so a sibling dispatch resolves it host-side and bind-mounts a secret
into the next sandbox (the round-3 codex finding behind PR #35).

The bug: the guard checks segments **above** the glorbo home too — segments
neither glorbo nor any agent controls. On atomic Fedora variants
(Bazzite / Silverblue / Kinoite / Aurora) `/home` is itself a symlink to
`/var/home`. With the default `HOME=/home/<user>`, the glorbo home resolves
to `/home/<user>/.glorbo`, whose **first** ancestor `/home` is a symlink — so
`assert_no_symlink_segment!` raises on essentially every permission mount and
approved path. Observable consequences on such a host:

- `glorbo reindex` indexes **0** files (every company path is refused).
- Agent dispatch cannot materialise its permission mounts.
- The default install is unusable; today's only workaround is to point
  `GLORBO_HOME` at the canonical `/var/home/<user>/.glorbo` by hand.

This is not exotic: immutable/atomic desktops are a growing share of Linux
hosts, and the same failure hits any home reached through a symlink (some
NFS / autofs / bind-mount layouts). The default-path config is "broken out of
the box" there.

## Goals

- **The default `~/.glorbo` works on atomic distros** with no manual
  `GLORBO_HOME` override.
- **No weakening of the in-workspace guarantee.** Agent-planted symlinks
  *inside* the glorbo home (the actual threat — an agent can only write under
  its company/agent subtree) must still be refused exactly as today.
- **One canonical guard still.** Both call sites (PermissionMapper, GEP-27
  approved paths) keep sharing the implementation; no per-call-site special
  cases.

## Non-goals

- Not a relaxation of GEP-27 external-grant checking. An operator-approved
  path *outside* the glorbo home is arbitrary host filesystem and still needs
  full-ancestor symlink verification — the system-trust assumption below
  applies only to ancestors of the resolved glorbo home.
- Not changing where `~/.glorbo` lives (that is GEP-3 / GEP-53) nor the XDG
  config split (GEP-61).

## Design (DRAFT — decisions open)

The threat model is **agent-controllable** symlinks. An agent can only write
beneath its own company/agent subtree of the glorbo home; it can never alter
`/home`, `/var`, or the home root itself. So the segments that need walking
are those **at or below the resolved glorbo home root**; everything above it
is host-trusted and immutable to agents.

Sketch (not locked):

1. **Canonicalise the home root once.** Resolve the glorbo home
   (`Hierarchy.default_root/0`) through its symlinks up front — e.g.
   `:file.read_link_info`-based realpath, or `Path.expand` + link
   resolution — to get the true root (`/home/<user>/.glorbo` →
   `/var/home/<user>/.glorbo`). Mount sources / approved paths under the home
   are expressed relative to this resolved root.
2. **Anchor the guard at the resolved root.** `assert_no_symlink_segment!`
   gains a `trust_root` (the resolved glorbo home): walk and symlink-check
   only the segments **from `trust_root` down to the leaf**, treating the
   resolved-root prefix as trusted. A path that does not descend from
   `trust_root` (GEP-27 external grant) keeps full-ancestor checking.

Open questions to resolve before Accepted:

- **Trust anchor:** the resolved glorbo home specifically, or a configurable
  trust-root? (Default: resolved home.)
- **Where canonicalisation happens:** at the guard, at the call sites
  (PermissionMapper / Bwrap), or in `Hierarchy` when the home is first
  computed? (Leaning: resolve in `Hierarchy` so the whole system sees the
  canonical root, and have the guard verify the supplied `trust_root` is
  itself symlink-free up to `/` exactly once at boot.)
- **Boot-time validation:** prove the resolved-root prefix really is
  symlink-free *once* at startup (so we don't blindly trust it forever), then
  skip re-walking it per-mount.
- **`GLORBO_HOME` interaction:** an explicitly-set `GLORBO_HOME` should be
  canonicalised the same way.

## Decision log

Draft — nothing locked yet. Candidate decisions, to be ratified when this
moves to Accepted:

- **D1 (proposed).** The trust anchor is the **resolved glorbo home** (its
  realpath), not a free-form configurable root. Rationale: agents can only
  write below the home; the home's own resolved prefix is host-trusted.
- **D2 (proposed).** Canonicalise the home **once, in `Hierarchy`**, so the
  whole system shares the resolved root; the guard verifies the supplied
  `trust_root` is symlink-free up to `/` exactly once at boot, then skips
  re-walking the prefix per mount.
- **D3 (proposed).** Off-home paths (GEP-27 external grants) are unchanged —
  full-ancestor symlink checking still applies; the trust-root shortcut is
  *only* for descendants of the resolved home.
- **Open.** Boot-time prefix validation mechanics; `GLORBO_HOME`
  canonicalisation parity; whether `read_link_info` realpath or an explicit
  `Path.expand` + loop is the resolver.

## Migration

No on-disk migration. The change is internal to `SymlinkGuard` + how
`Hierarchy` computes the home root; file layouts (GEP-3 / GEP-53), the audit
log, and SQLite are untouched. Behaviour change is purely corrective:

- Hosts where the home was reached through a symlinked ancestor (atomic
  Fedora `/home → /var/home`, some NFS/autofs homes) go from **broken
  default** to working — no operator action.
- The manual `GLORBO_HOME=/var/home/<user>/.glorbo` workaround keeps working
  (it already names the resolved path).
- No security posture is relaxed for any path that worked before; in-workspace
  and off-home symlink refusals are preserved (see §Test strategy 2–4).

## Test strategy (DRAFT)

Test-first, since this touches a security boundary:

1. Regression for the atomic case: a home reached through a symlinked
   ancestor (simulate `/home → /var/home` with a tmp symlink) — paths under
   the resolved home must be **allowed**.
2. The threat case must still **fail**: an agent-planted symlink *inside* the
   resolved home (`<co>/projects/foo/tasks → /etc`) is still refused.
3. GEP-27 external grant outside the home with a symlinked ancestor is still
   refused (full-ancestor check unchanged off-home).
4. Fail-closed on `lstat` errors below the trust root is preserved.

## Related

- GEP-5 — kernel-policy / sandbox model (the guard enforces it host-side).
- GEP-27 — external path grants (the other call site; off-home, unchanged).
- GEP-3 / GEP-53 — `~/.glorbo` layout + the 0700 home root.
- Known-gotcha context in the project knowledge graph: glorbo only works via
  the canonical `/var/home/<user>/.glorbo` on this class of host today.
