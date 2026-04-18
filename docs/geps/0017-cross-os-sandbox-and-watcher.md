---
gep: 17
title: Cross-OS Sandbox and Filesystem Watcher Landscape
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Informational
created: 2026-04-18
see-also: [5, 16]
history:
  - date: 2026-04-18
    status: Draft
    note: Pure research GEP — captures the cross-OS sandbox + filesystem-watcher landscape so any future macOS/Windows port has a baseline reference. No decisions, no roadmap commitments. Draft and may stay that way until a port is actually attempted.
---

# GEP-17: Cross-OS Sandbox and Filesystem Watcher Landscape

## Purpose

Glorbo is Linux-only today. The kernel-layer sandbox (GEP-5, bwrap)
and the filesystem watcher (`file_system` hex package with inotify
backend) both rely on Linux-specific primitives. A future port to
macOS or Windows would need to answer: **what are the equivalent
primitives on each OS, and how usable are they for Glorbo's
per-invocation sandbox + inotify-style watcher shape?**

This GEP is **research only**. It does not commit to a port, propose
a design, or add abstractions. It captures the 2026-04 landscape so
the next person who asks "can we run on Mac?" has a baseline.

## Non-goals

- No cross-OS abstraction in Glorbo's code. GEP-5's bwrap wiring and
  the `file_system` hex package stay as they are.
- No timeline for a port. Glorbo targets Linux-first per `DESIGN.md`;
  other OSes are a "someday, maybe."
- No decision log. Nothing is being decided.

## Sandbox landscape

### Linux — bwrap (current, GEP-5)

Mount namespaces via user namespaces. No daemon, per-invocation,
sub-10ms startup. Packaged in every major distro. See GEP-5.

### macOS — `sandbox-exec`

- Officially deprecated since OS X 10.8 (2012); still ships with
  macOS Sequoia/Tahoe as of 2026. Apple has kept it functional for
  13+ years while never removing it.
- Uses `.sb` TinyScheme profiles (the "Seatbelt" kernel subsystem).
- Used in production today by Chromium, Firefox, and Docker
  Desktop's `vpnkit`.
- **UX:** no admin required, per-invocation, fast (~10–50ms).
- **Risk:** Apple could remove it at any release without notice.
- **Shape match vs bwrap:** good. Closest macOS analogue — profile
  file replaces bwrap flag string, but per-invocation and
  daemon-free.

### macOS — App Sandbox

- Requires code-signing + entitlements plist + distribution through
  signed bundles. Designed for App Store / notarization, not
  per-invocation CLI sandboxing of arbitrary binaries.
- Wrong shape for Glorbo.

### macOS — other

- `chroot` exists but requires root and provides no namespace /
  network / capability isolation.
- No actively maintained "bwrap-for-mac" project. Profile
  collections exist (e.g., `macOS-sandbox-exec-profiles`) but no
  tool displaces `sandbox-exec`.
- Practical fallback: Lima / UTM / Tart VM running Linux inside.

### Windows — AppContainer

- Win32 API-level isolation (integrity level + capability SIDs +
  object-namespace virtualization).
- Per-process, no admin, no VM.
- **Closest structural analogue to bwrap.**
- Used by Edge, Chrome renderers, Windows Defender Application Guard.
- **Downsides:**
  - API-only — no CLI wrapper equivalent to `bwrap <cmd>`.
  - Win32-centric: console apps work, but filesystem virtualization
    is weaker than mount namespaces.
  - Invocation requires calling `CreateProcess` with an
    `AppContainer` attribute list from C/C++/Rust.
- Wrapper projects exist (e.g., Rust `sandbox-windows-appcontainer`);
  none is a drop-in bwrap equivalent.

### Windows — Job Objects + restricted tokens

- Older primitive (pre-AppContainer Chromium sandbox model). Still
  works.
- Lower isolation ceiling than AppContainer. ACL-based denial, not
  mount-namespace substitution — can't remap the filesystem view the
  sandbox sees.

### Windows — Windows Sandbox

- Hyper-V-backed lightweight VM.
- Requires Pro/Enterprise/Education SKU + hardware virtualization.
- ~1–2s startup — heavy for per-invocation dispatch.
- Good for "run this installer in a throwaway"; wrong for agent
  spawns.

### Windows — WSL2 fallback

- Full Linux VM. Glorbo could run inside WSL2 and use bwrap
  normally.
- Requires WSL2 install (not admin after initial setup on Win11).
- **Pragmatic shortcut:** ship Glorbo as a Linux binary; on Windows,
  the user runs it inside WSL2. This is the path that needs zero
  Glorbo code changes.

### Cross-platform primitives

**None production-usable for Glorbo's shape.**

- Firejail, gVisor, systemd-nspawn, Podman native sandboxing — all
  Linux-only at the isolation layer.
- Docker Desktop / Podman Desktop on macOS/Windows run a Linux VM
  internally (HyperKit / WSL2) and containerize inside it. Requires
  a daemon, ~500 MB–2 GB RAM baseline, admin for install. Heavy and
  violates GEP-5 D6's "no daemon" principle.
- Deno / Wasmtime / WASI sandbox language runtimes, not process
  trees — wrong layer, can't sandbox the `claude` / `codex` CLIs.

**Summary:** any portable Glorbo would need a per-OS sandbox adapter
behind a common Elixir interface. There is no single binary or
library that works everywhere.

## Filesystem watcher landscape

### Current — `file_system` hex 1.1

Ships four backends: `fs_inotify` (Linux, wraps `inotifywait`
binary), `fs_mac` (macOS, bundled C helper using FSEvents),
`fs_windows` (Windows, `ReadDirectoryChangesW`), and `fs_poll`
(pure-Elixir polling, works everywhere).

This is already cross-OS at the library layer. The port problem is
packaging, not library selection.

### Is `file_system` still the right choice?

Yes. As of 2026-04 it's the de-facto Elixir FS watcher — used by
Phoenix LiveReload, ExSync, Credo. No new entrant has displaced it.
The alternatives (`fs` — its unmaintained ancestor; project-specific
polling loops) are strictly worse.

### Linux — `inotify-tools` dependency

The `fs_inotify` backend invokes the `inotifywait` binary from the
`inotify-tools` package. No pure-Elixir or pure-Erlang inotify
binding exists on Hex with production-quality — direct `inotify(7)`
use would need a NIF wrapping `inotify_init1`/`inotify_add_watch`
and careful non-blocking FD polling, which BEAM doesn't expose
cleanly.

Options to drop the runtime dep:

1. Write an `inotify` NIF. Risky — NIFs must not block the scheduler;
   inotify's read-on-FD model requires a dedicated port driver or
   dirty scheduler.
2. Bundle a static-musl `inotifywait` (~50 KB) inside the Burrito
   payload. Pragmatic fix; matches the "single-binary distribution"
   invariant already in place.
3. Fall back to `fs_poll`. Works, but high CPU on large trees —
   already the documented fallback (see GEP-16 §1's polling branch).

### macOS — `fs_mac` packaging

- `fs_mac` ships a pre-compiled `mac_listener` binary inside the
  Hex package. Consumers don't need `xcode-select` at install time.
- Cross-compiling the macOS helper from Linux is impractical
  (requires Apple SDK + codesigning). Standard practice: build the
  macOS Burrito artifact on a macOS GitHub Actions runner
  (`macos-14` for Apple Silicon).
- Real packaging pain is codesigning + notarization, not the C
  helper.

### Windows — `fs_windows`

- Works. Known edge cases: UNC paths, long paths (>260), and
  case-insensitive rename events firing twice.
- Any path normalisation in Glorbo's watcher layer would need to
  account for these. Not blocking for a port, but expect to handle
  them.

### Apple Silicon / Windows 11 status

- Apple Silicon: `fs_mac` supports arm64 since `file_system` 0.2.10
  (2022). No outstanding issues. Burrito handles arm64-darwin
  targets.
- Windows 11: `fs_windows` works. Event coalescing differs from
  inotify (batched/debounced differently), so any per-event
  assertions written against Linux behaviour will need OS-specific
  tolerance.

## Summary table

| Layer            | Linux (current)   | macOS                        | Windows                        | Notes                                 |
|------------------|-------------------|------------------------------|--------------------------------|---------------------------------------|
| Sandbox          | `bwrap`           | `sandbox-exec` (deprecated but alive) | AppContainer (API-only) or WSL2+bwrap | No cross-platform primitive exists    |
| FS watch         | `fs_inotify`      | `fs_mac`                     | `fs_windows`                   | Already cross-OS via `file_system` hex |
| Polling fallback | `fs_poll`         | `fs_poll`                    | `fs_poll`                      | Always available, high CPU on large trees |
| Packaging        | Single-binary via Burrito | macOS builder + codesign     | WSL2 reuses Linux artifact; native needs separate build | Codesign / notarization is the pain   |

## What a port would actually need

Spelled out only to answer "is this a small or large undertaking?"
— not a commitment.

1. **Sandbox adapter behind a behaviour** — `Glorbo.Sandbox` becomes
   a behaviour; `Bwrap`, `SandboxExec`, and (maybe) `AppContainer` or
   `WSL2Passthrough` become implementations. Each implementation
   translates Glorbo's permission model (resource:action:scope) into
   the native primitive's config shape.
2. **macOS build pipeline** — CI runner for `macos-14`, producing
   a notarized Burrito tarball. Realistic lift: 1–2 weeks for first
   green build, ongoing codesign-cert management.
3. **Windows build pipeline** — either WSL2-only (easy: reuse Linux
   artifact, document WSL2 install) or native Windows Burrito
   (harder: `fs_windows` works, but AppContainer invocation needs
   C/Rust shim).
4. **Watcher tolerance** — path normalisation layer for Windows
   edge cases, event-coalescing tolerance in tests.

The sandbox layer is where the work concentrates. The watcher layer
is already 90% there via `file_system`.

## Related

- **GEP-5** — bwrap sandbox. This GEP describes what would replace
  it per-OS.
- **GEP-16** — wake/dispatch pipeline. The cross-OS work would need
  to replicate every bind described in GEP-16 §2–§6 in the
  target-OS primitive's config shape.
- **GEP-3** — filesystem as source of truth. The watcher layer is
  what keeps derived state (SQLite) in sync with the filesystem;
  any watcher regression on a new OS would compromise that.

## Open questions (explicitly deferred)

1. Is there a minimum-viable Windows story that goes beyond
   "install WSL2 and run the Linux build"? (Probably not without
   AppContainer work.)
2. Does the macOS sandbox-exec deprecation risk rise above "low" in
   Tahoe+1 (macOS 17)? If Apple pulls it, the macOS story reduces
   to "VM only."
3. Is it worth writing the inotify NIF to eliminate the
   `inotifywait` runtime dep on Linux, independent of any port?
   Probably no — Burrito-bundled `inotifywait` is easier.

All three stay unanswered until someone is actually doing the work.
