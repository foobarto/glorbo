---
gep: 61
title: Consolidate provider config + credentials under XDG (~/.config/glorbo)
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
type: Standards
created: 2026-06-13
requires: [8, 32, 45]
see-also: [53, 55]
history:
  - date: 2026-06-13
    status: Draft
    note: |
      Filed from a backup-safety bug report: `~/.glorbo/providers/<name>.toml`
      (GEP-8 per-provider overrides, e.g. stado.toml) and `~/.glorbo/providers.toml`
      (the enabled-providers registry) live INSIDE the `~/.glorbo` data tree and
      get swept into naive home-folder backups. Native credentials already sit
      out-of-home (GEP-32, `~/.local/etc/glorbo/credentials`), but at a
      non-standard location and split from the rest of the provider config.
      Operator decision (2026-06-13): consolidate EVERYTHING provider —
      overrides + registry + native credentials — under XDG_CONFIG_HOME
      (`~/.config/glorbo/`), with a one-time migration. Full consolidation.
  - date: 2026-06-13
    status: Accepted
    note: |
      Approved + implemented in the same PR. `Hierarchy.config_root/0`
      (+ `:glorbo_config_root` test override) anchors `~/.config/glorbo`;
      `native_credentials_dir/0`, `providers_config_path/0`, and
      `providers_override_dir/0` resolve under it; `enable.ex` / registry loader
      repointed. New `Glorbo.Filesystem.ConfigMigration` runs once on real-binary
      start (`run_cli_and_halt/1`) — copy-then-remove, no-clobber, perms-preserving,
      best-effort. Flip to Implemented on merge to main.
  - date: 2026-06-14
    status: Implemented
    note: |
      Flipped to Implemented. Provider config + credentials consolidated
      under ~/.config/glorbo via `Glorbo.Filesystem.ConfigMigration`.
      Merged in PR #55, [Unreleased]; `implemented-in:` at the next cut.
---

# GEP-61: Consolidate provider config + credentials under XDG

## Problem

Glorbo's provider configuration and credentials are scattered across three
locations with inconsistent backup-safety:

| What | Current path | In `~/.glorbo`? |
|---|---|---|
| Native-provider credentials (API keys) | `~/.local/etc/glorbo/credentials/<provider>.toml` (GEP-32) | No ✓ |
| Per-provider overrides (GEP-8, e.g. stado) | `~/.glorbo/providers/<name>.toml` (GEP-45) | **Yes ✗** |
| Enabled-providers registry | `~/.glorbo/providers.toml` | **Yes ✗** |

`~/.glorbo/` is the **user data** tree — companies, channels, audit log, the
derived SQLite projection — exactly what a Director *wants* to back up. But it
now also carries provider config (and, via overrides, potentially secrets such
as `args`/auth tweaks). A naive `tar czf backup.tgz ~/.glorbo` sweeps provider
config into the archive. GEP-32 already recognised this for API keys and put
them out-of-home — but at `~/.local/etc/glorbo/` (a non-XDG location) and split
from the rest of the provider config. The result is three locations, two
conventions, and a backup foot-gun. Notably `priv/providers/stado.toml` already
*documents* that provider config "belongs under XDG_CONFIG_HOME" — the code's
own stated intent, not yet realised.

## Goals

- **One** canonical, XDG-standard home for ALL provider config + credentials:
  `$XDG_CONFIG_HOME/glorbo` (default `~/.config/glorbo`).
- Nothing provider-config or provider-secret inside `~/.glorbo/` — that tree
  stays **pure user data**, so "back up `~/.glorbo`" never captures secrets.
- Honour `XDG_CONFIG_HOME`; keep the `GLORBO_CREDENTIALS_DIR` escape hatch.
- A **one-time, idempotent migration** of existing files from all three old
  locations — credentials are user data and must never be orphaned.

## Non-goals

- **Not** moving the `~/.glorbo` data tree (companies, audit, cache, run,
  runtime, logs, derived SQLite) — that IS the backup target and stays put.
- **Not** (in this GEP) relocating the `config.md` secrets (dashboard token,
  director password hash, `secret_key_base`, `erl_cookie`). They live in
  `~/.glorbo` under the GEP-53 `0700` root and are a separate, load-bearing
  concern — see Open questions.
- **Not** changing the in-sandbox credential bind semantics (GEP-55) — only the
  host-side source path changes; the `--ro-bind` into the agent sandbox is
  unchanged.

## Design

### Canonical config root

A new `Glorbo.Filesystem.Hierarchy.config_root/0`:

```
$XDG_CONFIG_HOME/glorbo   (if XDG_CONFIG_HOME is set + absolute)
~/.config/glorbo          (otherwise)
```

chmoded `0700` on first materialisation (parity with the `~/.glorbo` root,
GEP-53), since it holds credentials.

### Target layout under `~/.config/glorbo/`

```
~/.config/glorbo/
├── providers.toml                 # enabled-providers registry (was ~/.glorbo/providers.toml)
├── providers/<name>.toml          # per-provider overrides (was ~/.glorbo/providers/<name>.toml)
└── credentials/<provider>.toml     # native-provider API keys (was ~/.local/etc/glorbo/credentials/<provider>.toml)
```

### Code touch-points

- `Hierarchy.native_credentials_dir/0` → `config_root()/credentials`
  (keep the `GLORBO_CREDENTIALS_DIR` override + its absolute-path / no-`..`
  validation guard).
- `Providers.Enable.default_path/0` + `CLI.Registry.Loader.default_user_file/0`
  → `config_root()/providers.toml`.
- The GEP-8 per-provider override dir → `config_root()/providers/`. **Resolve
  the doc/impl gap first:** GEP-45 + `priv/providers/stado.toml` document an
  override at `~/.glorbo/providers/<name>.toml`, but the loader I can find reads
  the `providers.toml` *file*, not the `providers/` *dir*. Part of this GEP is
  to confirm whether the override-dir path is wired and, if documented-but-dead,
  either wire it at the new location or correct the docs.
- `~/.glorbo` `@dirs`: drop any provider-config dirs; keep data dirs only.

## Migration

One-time and idempotent. On the first run of a config-aware verb (and surfaced
by `glorbo doctor`):

1. If `config_root()` provider files are absent AND a legacy path exists, **move**
   (not copy) each legacy file to its new home, preserving `0600`:
   - `~/.glorbo/providers.toml` → `~/.config/glorbo/providers.toml`
   - `~/.glorbo/providers/*` → `~/.config/glorbo/providers/*`
   - `~/.local/etc/glorbo/credentials/*` → `~/.config/glorbo/credentials/*`
2. Leave a one-line breadcrumb in the audit log; never delete a legacy dir that
   still has unmoved content.
3. Re-runnable: if the new file already exists, skip (don't clobber); if both
   exist, prefer the new and warn about the stale legacy copy.

This is a **data move**, not an API/back-compat shim — consistent with the
pre-1.0 "atomic cut" stance (no dual-readers) while still not orphaning a
Director's credentials.

## Failure modes

- **Partial migration** (crash mid-move) → idempotent re-run completes it.
- **Odd `XDG_CONFIG_HOME`** (relative, `..`, `/etc`) → reuse the GEP-32
  `GLORBO_CREDENTIALS_DIR` guard shape (must be absolute, no `..`).
- **Both legacy + new present** → new wins; stale legacy flagged by `doctor`.
- **`~/.config/glorbo` perms** → `0700` on materialise (GEP-53 parity).
- **Read-only `~/.config`** (unusual) → migration fails loudly with an
  actionable message; the old path keeps working until resolved.

## Test strategy

- `config_root/0` resolution + `XDG_CONFIG_HOME` precedence + the validation
  guard (absolute / no-`..`).
- Migration: legacy files present → moved to new paths, `0600` preserved,
  idempotent on re-run, no-clobber when new already exists.
- `Loader` / `Enable` read + write at the new `providers.toml`.
- `native_config` credential resolution at the new `credentials/` path.
- Sandbox bind (GEP-55) sources creds from the new path.

## Open questions

- **`config.md` secrets.** The dashboard token, director password hash,
  `secret_key_base`, and `erl_cookie` also live in `~/.glorbo` (GEP-53). Should
  they follow the same out-of-home logic? Bigger, load-bearing change — deferred
  to a follow-up unless the operator wants it folded in.
- **Override-dir wiring.** Confirm whether `~/.glorbo/providers/<name>.toml`
  overrides are actually loaded today (vs documented-only) before migrating.

## Decision log

### D1. Canonical home = `~/.config/glorbo` (XDG_CONFIG_HOME) *(settled)*
- **Decided:** all provider config + credentials live under
  `$XDG_CONFIG_HOME/glorbo` (default `~/.config/glorbo`).
- **Alternatives:** keep GEP-32's `~/.local/etc/glorbo/`; use
  `~/.local/share/glorbo` (XDG_DATA).
- **Why:** XDG_CONFIG_HOME is the standard for config; `priv/providers/stado.toml`
  already states config belongs there; out of the `~/.glorbo` backup target.
  (Operator decision, 2026-06-13.)

### D2. Full consolidation — overrides + registry + native creds *(settled)*
- **Decided:** move ALL three (per-provider overrides, `providers.toml`
  registry, and the native-credentials dir) under `config_root()`.
- **Alternatives:** relocate only the `providers/` override dir; or only
  overrides + registry, leaving native creds at `~/.local/etc/glorbo`.
- **Why:** one consistent home eliminates the `~/.local/etc` vs `~/.glorbo`
  split and the two-convention confusion. (Operator decision: "migrate
  everything from `~/.local/etc/glorbo` there too" + "full consolidation".)

### D3. One-time automatic, idempotent migration *(settled)*
- **Decided:** move (not copy) legacy files to the new home on first config-aware
  run; idempotent; no-clobber; perms preserved.
- **Why:** credentials are user data and must not be orphaned by a path change;
  a data move is consistent with the pre-1.0 atomic-cut stance (no dual readers).

### D4. `~/.glorbo` stays data-only *(settled)*
- **Decided:** after this GEP, `~/.glorbo` carries only user data (companies,
  audit, cache, run, runtime, logs, derived SQLite, `bin`).
- **Why:** clean separation — backing up `~/.glorbo` captures the Director's
  data without sweeping in any provider secret/config.

### D5. `config.md` secrets out of scope *(settled, for now)*
- **Decided:** the GEP-53 `config.md` secrets stay in `~/.glorbo` for this GEP.
- **Why:** load-bearing + broader blast radius; deferred to a follow-up. Tracked
  in Open questions.

## Related

- GEP-8 (provider registry + per-provider overrides) · GEP-32 (native-provider
  credentials at `~/.local/etc/glorbo/credentials`) · GEP-45 (stado override at
  `~/.glorbo/providers/stado.toml`) · GEP-53 (`~/.glorbo` `0700` hardening +
  `config.md` secrets) · GEP-55 (credentials `--ro-bind` into the agent sandbox).
