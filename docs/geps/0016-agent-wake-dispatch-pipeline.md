---
gep: 16
title: Agent Wake + Dispatch Pipeline
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Informational
created: 2026-04-18
implemented-in: v0.0.3
requires: [5, 8]
extends: [5, 8]
see-also: [4, 14]
history:
  - date: 2026-04-18
    status: Draft
    note: Retrofit capturing the wake-path rewrite that shipped during the v0.0.3 browser-verification sprint. The GEP-8 spec stopped at "dispatcher reads reply file"; in practice end-to-end agent wake required seven additional layers of wiring that aren't in GEP-8 or GEP-5. This records what actually ships.
  - date: 2026-04-18
    status: Accepted
    note: Accepted on the bootstrap carve-out — no design alternatives remain open; the code has been running end-to-end against real claude-code since commit 3632248.
  - date: 2026-04-18
    status: Implemented
    note: Shipped across commits 1f24854, abcaa56, c45d762, cac24c4, 400e59d, 3632248. 793 tests green, mix credo --strict clean, live browser verification shows `agent.complete` in 8.3s.
---

# GEP-16: Agent Wake + Dispatch Pipeline

## Purpose

GEP-8 specified the provider registry and the reply-file contract.
GEP-5 specified bwrap as the sandbox. Neither spelled out the
**boundary glue** between them — what happens between "user clicks
Wake" and "claude-code responds inside bwrap with real auth."

Getting from Wake-click to a non-zero `agent.complete` audit row
required seven additional pieces of wiring, each debugged against a
specific failure mode on real hardware (Bazzite + flatpak
claude-code). This GEP documents all seven, together, as the
canonical wake-path description.

This is Informational — it captures shipped behaviour, not a
proposal.

## Scope

This GEP covers:

1. **Wake PubSub topic** — how Director clicks reach the agent
   GenServer.
2. **Path math** at the Dispatch → Dispatcher → Bwrap boundary.
3. **Sibling-dir creation** so bwrap can bind inbox/outbox.
4. **CLI binary auto-mounting** for flatpak / nix / user-local installs.
5. **auth_binds** — TOML-declared host→sandbox bind pairs (extends GEP-8 §6).
6. **Env rewriting** — host workspace paths → `/workspace` at the bwrap
   boundary.
7. **Stdout→reply fallback** — capturing stdout when a CLI prints its
   answer instead of writing `$GLORBO_REPLY_PATH`.

Out of scope: provider TOML schema at large (GEP-8), bwrap flag set
(GEP-5), heartbeat scheduling (GEP-14), AGENT.md conventions (GEP-15).

## The seven layers

### 1. Wake PubSub topic

Director actions (Wake button, `@mention` in chat, scheduled
heartbeat) need to reach a specific agent's GenServer. The
`Glorbo.Agent.Server` init subscribes to two topics:

```
company:{co}:inbox                                  — inotify events
company:{co}:agents:{slug}:wake                     — director wakes
```

The per-agent wake topic is the critical one: without it, clicking
Wake writes a `wake-request.md` file (handled by
`lib/glorbo_web/live/agent_live.ex`), inotify notices the write, but
the event never reaches the agent's GenServer — the agent stays
idle.

Subscription happens in `Glorbo.Agent.Server.init/1` behind a
`subscribe?: true` opt so tests can drive `wake/2,3` directly.

### 2. Path math at the Dispatch → Bwrap boundary

Workspace layout:

```
~/.glorbo/companies/<co>/agents/<slug>/
├── inbox/            ← Elixir writes, agent reads (bwrap --ro-bind)
├── outbox/           ← agent writes, Elixir reads (bwrap --bind)
├── workspace/        ← agent scratch space (bwrap --bind)
├── history/
├── state/
└── AGENT.md
```

`Dispatch.build_ctx/5` constructs the bwrap bind list. The workspace
path ends in `.../agents/<slug>/workspace`, and the
**agent root** — parent of inbox/outbox — is therefore
`Path.dirname(workspace)`, not `Path.dirname(Path.dirname(workspace))`.

The pre-rewrite code stripped one dirname too many, yielding
`.../agents/` as the "agent root" and pointing bwrap at
`.../agents/outbox` — a path that doesn't exist on any host. bwrap
exited with `Can't find source path .../agents/outbox`; the CLI
never ran; dispatch surfaced `:reply_file_missing`.

### 3. Sibling-dir creation

A user-created agent dir might contain only `AGENT.md`. bwrap
`--ro-bind`ing a non-existent source path crashes. `ensure_workspace`
pre-creates all four sibling dirs (`inbox`, `outbox`, `history`,
`state`) on every dispatch:

```elixir
agent_root = Path.dirname(path)
Enum.each(~w(inbox outbox history state), &fs.mkdir_p!.(Path.join(agent_root, &1)))
```

Idempotent: `mkdir -p` on an existing dir is a no-op.

### 4. CLI binary auto-mounting

GEP-5's baseline mount list is `--ro-bind /usr /usr` (plus
`/bin /lib /lib64 /etc`). That's enough for Debian/Fedora
`apt`/`dnf`-installed CLIs, but **not** for:

- **flatpak**: `claude` is often a symlink under `~/.local/bin/`
  pointing at `/var/lib/flatpak/exports/bin/...` or similar.
- **nix**: binaries live under `/nix/store/...`.
- **user-local**: anything under `~/.local/bin/`, `~/bin/`, `/opt/*`.

`Dispatch.cli_binary_binds/1` auto-mounts both the symlink's parent
dir AND (if the binary is a symlink) the target's enclosing dir.
Same host+sandbox path so `$PATH` resolution inside the sandbox
matches outside:

```elixir
defp cli_binary_binds(%{resolved_path: path}) when is_binary(path) do
  symlink_parent = Path.dirname(path) |> Path.expand()
  target_parent =
    case File.read_link(path) do
      {:ok, target} -> Path.expand(target, Path.dirname(path)) |> Path.dirname()
      _ -> nil
    end
  [symlink_parent, target_parent]
  |> Enum.reject(&is_nil/1)
  |> Enum.uniq()
  |> Enum.filter(&File.exists?/1)
  |> Enum.map(fn dir -> {dir, dir} end)
end
```

`resolved_path` is populated by `Glorbo.CLI.Registry.Detection` at
boot — the same `System.find_executable/1` call that decides
`installed?`.

### 5. `auth_binds` — TOML-declared host → sandbox bind pairs

Extension to GEP-8 §6. Every CLI needs its own auth material inside
the sandbox; the shape of that material is provider-specific:

| Provider     | Auth layout                                    |
|--------------|------------------------------------------------|
| claude-code  | `~/.claude/` (OAuth refresh) + `~/.claude.json`|
| gemini-cli   | `~/.gemini/`                                   |
| codex        | `~/.codex/`                                    |
| opencode     | `~/.config/opencode/`                          |
| hermes       | `~/.hermes/config.yaml`                        |
| pi           | (none — local)                                 |

Hardcoding this per-provider in Elixir would re-introduce the
adapter-per-CLI pattern GEP-8 deleted. Instead, each provider TOML
declares its own binds as an array of tables:

```toml
# priv/providers/claude-code.toml
[[auth_binds]]
host    = "~/.claude"
sandbox = "/workspace/.claude"
mode    = "ro"

[[auth_binds]]
host    = "~/.claude.json"
sandbox = "/workspace/.claude.json"
mode    = "ro"
```

Schema:

- `host` (required, string) — host path. `~` and `$HOME` expand via
  `Path.expand/1`.
- `sandbox` (required, string) — absolute path inside the sandbox.
- `mode` (optional, `"ro"` | `"rw"`, default `"ro"`) — bind mode.
  `"rw"` is reserved for future use; today it is silently treated as
  `"ro"` (auth dirs should never be rw-mounted).

Parsed by `Glorbo.CLI.Registry.Loader.parse_auth_binds/2` into
`%{host: String, sandbox: String, mode: :ro | :rw}`. Unknown `mode`
values hard-fail at load (matches GEP-8 §6 validation rule style).

At dispatch time, `Dispatch.resolve_auth_binds/1`:

1. Expands `~` / `$HOME` in host paths.
2. Filters out binds whose host path doesn't exist
   (`--ro-bind` on a missing source crashes bwrap).
3. Passes the resulting `[{host, sandbox}]` tuples into
   `bwrap_opts.cli_auth_binds`.

Because the claude-code auth has two siblings (`~/.claude/` and
`~/.claude.json`), neither one overlaying the other, both appear as
separate `[[auth_binds]]` entries. bwrap's constraint "no create-in-ro"
isn't triggered because the siblings map to sibling sandbox paths.

### 6. Env rewriting at the bwrap boundary

`Glorbo.CLI.Dispatcher` expands env-var templates with the **host**
workspace path — correct for Dispatcher's own bookkeeping
(`GLORBO_WORKSPACE`, reply path construction). But those same env
vars get passed to the CLI **inside** the sandbox, where the host
workspace path doesn't exist — everything lives under `/workspace`.

`Dispatch.default_run_fun/4` rewrites every env value through
`rewrite_env_to_sandbox/2` at the boundary before handing off to
`Bwrap.start/2`:

```elixir
defp rewrite_env_value(value, host) when is_binary(value) and is_binary(host) do
  String.replace(value, host, "/workspace")
end
```

Before this, claude-code saw `GLORBO_REPLY_PATH =
/home/user/.glorbo/companies/.../outbox/...md` and wrote its reply
there — a path visible only outside the sandbox. Inside bwrap, the
write went to a tmpfs overlay and vanished on exit. Dispatch
surfaced `:reply_file_missing` despite the CLI exiting 0.

### 7. Stdout → reply fallback

GEP-8 D1 committed to "file-only reply, no stdout fallback." That
decision assumes the agent's system prompt actually instructs the
CLI to write `$GLORBO_REPLY_PATH`. In practice, several CLIs
(claude-code with `--print`, gemini-cli with `-p`) print the answer
to stdout by default regardless of env vars, because that's what
`--print` means to them.

Two options:

1. Wrap every CLI invocation in a shell that does
   `$(cli ...) > $GLORBO_REPLY_PATH`.
2. Catch stdout in the Dispatcher and, if the CLI exited cleanly and
   the reply file wasn't written, treat stdout as the effective reply.

Option 2 is the one that ships. `Dispatcher.maybe_stdout_to_reply/4`
writes stdout to the reply path iff:

- `exit_status == 0`
- stdout is non-empty after trimming
- reply file doesn't exist (don't clobber a real write)
- stdout ≤ `reply_max_bytes` (preserves the GEP-8 D12 disk-fill DoS
  guard)

If any condition fails, the original `:reply_file_missing` /
`:reply_file_empty` / `:reply_file_too_large` errors still surface.
The fallback is purely additive — a clean exit with output nobody
was going to read otherwise.

This is a **soft reversal** of GEP-8 D1. D1's rationale —
"stdout-capture is ambiguous" — still holds as the design
*preference*. But the fallback recovers the case where agent prompts
don't yet instruct `$GLORBO_REPLY_PATH` usage, which is common
during iteration and essentially universal with flatpak-installed
CLIs that the user hasn't customised. No ambiguity is introduced:
the file path is still the primary contract; stdout is secondary.

`Dispatcher.maybe_log_run_output/4` also emits a Logger.warning on
any non-zero exit or missing-reply situation, so operators see the
CLI's stderr snippet in the app log instead of a bare
`:reply_file_missing`.

## How the pieces compose

```
┌──────────────────────────────────────────────────────────────────┐
│ Director clicks Wake                                              │
│   └── writes wake-request.md to agents/<slug>/state/             │
│       └── inotify → PubSub "company:<co>:agents:<slug>:wake"      │
│           └── Agent.Server (§1) — handle_director_wake            │
│               └── Dispatch.execute/3                              │
│                   ├── build_ctx  (§2 path math, §3 mkdir_p,       │
│                   │                §4 cli_binary_binds,           │
│                   │                §5 resolve_auth_binds)         │
│                   ├── default_run_fun (§6 env rewrite)            │
│                   │   └── Sandbox.Bwrap.start                     │
│                   │       └── CLI runs in sandbox                 │
│                   │           with auth visible + binary visible  │
│                   │           + GLORBO_REPLY_PATH inside /workspace│
│                   └── Dispatcher.invoke                           │
│                       ├── read_reply (file present?)              │
│                       └── maybe_stdout_to_reply (§7 fallback)     │
│           └── record_usage, emit agent.complete audit event       │
└──────────────────────────────────────────────────────────────────┘
```

## Test strategy

The full pipeline is exercised end-to-end in
`test/glorbo/agent/dispatch_test.exs` and
`test/glorbo/cli/dispatcher_test.exs` with injected
`run_fun`/`fs_fun` seams. Live sandbox tests (real bwrap + real
flatpak claude-code) are not in CI — they ran manually during the
v0.0.3 browser-verification sprint. The regression guard against a
bwrap regression is:

1. The test matrix covers each helper in isolation
   (`cli_binary_binds/1`, `resolve_auth_binds/1`,
   `rewrite_env_to_sandbox/2`, `maybe_stdout_to_reply/4`).
2. `mix release` + `glorbo up` on any Linux with `bwrap` + `claude`
   installed can run the same wake path through the live dashboard.

Failure modes surface either as `:reply_file_missing` (common bucket
for sandbox problems) with a `Logger.warning` stdout snippet, or as
`:sandbox_start_failed` with bwrap's own stderr.

## Decision log

### D1. Per-provider auth_binds, not a global auth-mount table

- **Decided:** each provider TOML declares its own `[[auth_binds]]`
  entries.
- **Alternatives:** a single `config/auth_binds.toml` mapping
  provider-name → binds; Elixir-module-per-provider `auth_binds/0`
  callback; hardcoded map in `Glorbo.Sandbox.Bwrap`.
- **Why:** the provider TOML is already the source of truth for
  "everything about CLI X." Putting auth binds anywhere else creates
  two files to keep in sync. A callback module re-introduces the
  adapter-per-CLI pattern GEP-8 D6 specifically dropped. Hardcoded
  in Bwrap means user-declared providers can't bring their own auth.

### D2. `mode = "rw"` reserved but unimplemented

- **Decided:** the schema accepts `"ro"` and `"rw"`; the current
  Bwrap wiring treats both as `ro`. `"rw"` is reserved for future
  use.
- **Alternatives:** reject `"rw"` at load; implement `"rw"` today.
- **Why:** no shipped provider needs rw auth (auth files are read
  on every invocation, refresh-token rotation happens elsewhere).
  Rejecting at load would block users who copy a schema from a
  future version. Implementing `"rw"` today adds a bwrap code path
  with no test coverage.

### D3. Filter missing host paths silently rather than erroring

- **Decided:** `resolve_auth_binds/1` drops binds whose host path
  doesn't exist. No warning, no error — just skip.
- **Alternatives:** fail the dispatch with a clear error ("install
  claude-code first"); log a warning and continue.
- **Why:** the CLI itself will fail cleanly with its own "not logged
  in" message (claude-code:
  `Not logged in · Please run /login`), which is more actionable
  than Glorbo's auth-dir-missing message. Failing dispatch means a
  user who has `gemini` installed but not `claude` gets misleading
  Glorbo errors for every claude-configured agent. Silent skip +
  CLI's own error is the least-surprise path.

### D4. Auto-detect CLI binary parent dirs, don't make user configure

- **Decided:** `cli_binary_binds/1` runs on every dispatch, using
  `System.find_executable/1` (already cached in the Registry) +
  `File.read_link/1`.
- **Alternatives:** `binary_parent` field in provider TOML; mount
  `/` read-only into the sandbox (defeats GEP-5); require symlinks
  into `/usr/local/bin`.
- **Why:** flatpak and nix are popular enough that making users edit
  TOMLs to install Glorbo is a poor onboarding. `File.read_link/1`
  costs microseconds and handles the symlink-chain case automatically.

### D5. Env rewrite at the bwrap boundary, not at template expansion

- **Decided:** Dispatcher expands templates with host paths;
  `Dispatch.default_run_fun/4` rewrites host → `/workspace` at the
  moment of sandbox entry.
- **Alternatives:** expand directly to `/workspace` in Dispatcher;
  add a `sandbox_workspace` template variable.
- **Why:** Dispatcher also uses the same env map for reply-path
  bookkeeping (`read_reply(reply_path, ...)`) which MUST see the host
  path — the file is read by Elixir after the sandbox exits.
  Expanding to `/workspace` in Dispatcher would break the reply read.
  Splitting the concern — Dispatcher owns host paths, Bwrap owns
  sandbox paths — keeps each module's contract coherent.

### D6. Stdout fallback as a soft reversal of GEP-8 D1

- **Decided:** the reply-file contract is primary; stdout is a
  fallback when exit is clean AND the file is absent AND stdout is
  non-empty AND within the size cap.
- **Alternatives:** strict file-only (GEP-8 D1 as written); require
  a shell wrapper per provider; stdout-only (abandon the file
  contract).
- **Why:** strict file-only fails cleanly against well-configured
  agents but reports `:reply_file_missing` against every
  out-of-the-box CLI, producing a confusing first-run experience.
  The fallback is additive and preserves every GEP-8 invariant —
  the file contract is still the documented primary mechanism;
  `$GLORBO_REPLY_PATH` is still exported; the size cap still applies.
  What changes: "no file, no output" becomes "no file, try stdout,
  then fail." The ambiguity D1 feared doesn't arise — a well-written
  agent writes the file and `maybe_stdout_to_reply` short-circuits.

## Related

- **GEP-5** — bwrap sandbox. This GEP extends it with auto-mounted
  binary dirs and auth binds.
- **GEP-8** — provider registry. This GEP extends the TOML schema
  with `[[auth_binds]]` and softens D1 (stdout fallback).
- **GEP-14** — heartbeat semantics. Heartbeats are one of the wake
  triggers that hit §1's PubSub topic.
- **GEP-4** — CLI-tool agents. This GEP is what "CLI-tool agents"
  actually looks like once the boundary glue is wired end-to-end.
- Live-verification artifact: browser screenshot in commit 3632248's
  message — first `agent.complete` in 8.3s against real claude-code
  auth.
