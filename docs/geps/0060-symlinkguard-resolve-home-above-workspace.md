---
gep: 60
title: SymlinkGuard must resolve the glorbo home and not trip on system symlinks above it (atomic-distro `/home → /var/home`)
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
implemented-in: v0.27.0
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
  - date: 2026-06-14
    status: Accepted
    note: |
      Decisions locked (D1–D3 below) after an adversarial security review
      confirmed the canonicalise-the-home-root approach is SOUND and
      SECURITY-NEUTRAL: the SymlinkGuard is left entirely unchanged, so it
      still refuses agent-planted symlinks below the home — only the trusted
      home PREFIX is resolved. Chosen over the original D2 sketch's
      `trust_root` skip (which would have trusted-a-prefix-forever inside the
      guard).
  - date: 2026-06-14
    status: Implemented
    note: |
      Shipped. `Glorbo.Filesystem.Hierarchy.canonicalize_home_root/1` (a
      per-segment `:file.read_link` resolver, root-only, loop-guarded)
      resolves the home through symlinked ancestors; `default_root/0`
      canonicalises the `GLORBO_HOME`/`~/.glorbo` branches (the `:glorbo_base`
      test override stays verbatim), and a new `home_root/0` carries the same
      canonicalisation to the 16 CLI/lifecycle/scaffold call sites that
      previously re-implemented `System.get_env("GLORBO_HOME") ||
      default_root()` — so an EXPLICIT `GLORBO_HOME=/home/<user>/...` is
      resolved too, not just the unset default. SymlinkGuard untouched.
      Tests: `test/glorbo/sandbox/symlink_guard_test.exs` (atomic-passes /
      agent-symlink-still-refused / off-home-refused + the ROOT-ONLY
      invariant that a mount path reaches the guard verbatim) +
      canonicalisation cases in `hierarchy_test.exs`. Verified on-host:
      `default_root/0` now returns `/var/home/<user>/.glorbo`.
      NON-GOAL kept as-is: GEP-27 off-home operator grants
      (`Bwrap.approved_path_flags`) still get full-ancestor symlink checking
      — canonicalising an off-home grant ancestor would be a weakening, not a
      fix. If an operator grants a path under a symlinked system ancestor it
      is still refused by design.
---

# GEP-60: SymlinkGuard must resolve the glorbo home, not trip on system symlinks above it

## Status

**Implemented** (2026-06-14). Shipped by canonicalising the glorbo home root
in `Glorbo.Filesystem.Hierarchy` (`canonicalize_home_root/1` +
`default_root/0` + a new `home_root/0` for the CLI call sites);
`SymlinkGuard` itself is unchanged. The §Design sketch below is what shipped;
D1–D3 in the Decision log are locked. The only deliberate carve-out is GEP-27
off-home grants (still full-ancestor checked — a non-goal, not a gap).

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

## Design (as shipped)

The threat model is **agent-controllable** symlinks. An agent can only write
beneath its own company/agent subtree of the glorbo home; it can never alter
`/home`, `/var`, or the home root itself. So the only symlinks worth detecting
are those **at or below the resolved glorbo home root**; everything above it is
host-trusted and immutable to agents.

What shipped — **canonicalise the home root, leave `SymlinkGuard` untouched**
(simpler and strictly safer than the original `trust_root`-skip sketch, which
would have taught the guard to trust-a-prefix-forever):

1. **`Hierarchy.canonicalize_home_root/1`** — resolve the home through any
   symlinked ancestors. It `Path.expand`s, then walks the path segment by
   segment following symlinks via `:file.read_link` (loop-guarded at
   `@max_symlink_hops`), re-appending a not-yet-created tail verbatim. So
   `/home/<user>/.glorbo` → `/var/home/<user>/.glorbo`, whose ancestors
   (`/var`, `/var/home`, …) are all real directories.
2. **`Hierarchy.default_root/0`** canonicalises its `GLORBO_HOME` / `~/.glorbo`
   branches (the `:glorbo_base` test override is used verbatim — it already
   names a real tmp path).
3. **`Hierarchy.home_root/0`** (new) carries the same canonicalisation to the
   16 CLI/lifecycle/scaffold sites that re-implemented `System.get_env(
   "GLORBO_HOME") || default_root()`, so an EXPLICIT `GLORBO_HOME` under a
   symlinked ancestor is resolved too.

Because every consumer derives its paths from the (now resolved) home, the
**unmodified** `SymlinkGuard` walks a symlink-free prefix and passes — while
still refusing any agent-planted symlink in the agent-controlled *suffix*,
which is appended AFTER canonicalisation and never resolved.

**ROOT-ONLY invariant (load-bearing):** `canonicalize_home_root/1` must never
be applied to a mount source / approved path — it follows symlinks, so it
would resolve away a planted `tasks → /etc` and neutralise the guard. Pinned
by a test that a threat-case mount path reaches the guard verbatim.

## Decision log

Locked at Accept (2026-06-14):

- **D1.** The trust anchor is the **resolved glorbo home** (its realpath), not
  a free-form configurable root. Agents can only write below the home; the
  home's own resolved prefix is host-trusted.
- **D2.** Canonicalise **in `Hierarchy`** (`default_root/0` + `home_root/0`),
  so the whole system shares the resolved root and **`SymlinkGuard` is left
  unchanged**. (Chosen over teaching the guard a `trust_root` skip: keeping the
  guard dumb-but-total means it can never be tricked into trusting a prefix it
  shouldn't.) The resolver is `Path.expand` + a per-segment `:file.read_link`
  loop — `read_link_info`-realpath would also work but OTP has no realpath and
  the explicit loop is what the existing detector in `agent_writable_file.ex`
  uses too.
- **D3.** Off-home paths (GEP-27 external grants) are unchanged —
  full-ancestor symlink checking still applies; canonicalisation is *only* for
  the home root, never off-home grants.
- **D4.** `GLORBO_HOME` parity: the explicit override is canonicalised the
  same way via `home_root/0` (not just the unset `~/.glorbo` default).

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
