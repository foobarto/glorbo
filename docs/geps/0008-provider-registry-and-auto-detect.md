---
gep: 8
title: Provider Registry + CLI Auto-Detect
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-17
updated: 2026-04-17
implemented-in: v0.0.3
requires: [2, 4]
see-also: [3, 5]
extended-by: [16, 32, 45]
history:
  - date: 2026-04-17
    status: Draft
    note: Initial draft — originally lived at docs/specs/2026-04-17-provider-registry-and-auto-detect.md; migrated into the GEP process with the same content. Targets v0.0.3.
  - date: 2026-04-17
    status: Accepted
    note: §11 open questions resolved (D12–D17). Module-layout paths in §5 corrected to match the actual `lib/glorbo/cli/` tree. Reply-file contract confirmed as a hard flip — breaking change for existing agents; migration requires system-prompt updates.
  - date: 2026-04-17
    status: Implemented
    note: Ships in v0.0.3. Registry, Loader, Detection, Dispatcher, Parsers, PathTransforms, `/providers` LiveView, and six built-in provider TOMLs (claude-code, codex, gemini-cli, hermes, opencode, pi) all landed. 680 tests green; mix credo --strict clean.
---

# GEP-8: Provider Registry + CLI Auto-Detect

**Targets:** v0.0.3 (tentative)

## 1. Problem

Glorbo today has three hand-written CLI adapter modules (`Glorbo.CLI.Adapter.ClaudeCode`, `GeminiCli`, `Codex`). Each embeds invocation shape, env isolation, and usage telemetry parsing in a single module. Adding a new provider means writing a fourth module — even when the new provider only needs detection + invocation and no telemetry parsing.

Two concrete needs trigger this work:

1. **Auto-detect installed CLIs.** Users need `glorbo doctor` and the dashboard to show which providers are available on their host.
2. **Support more providers cheaply.** The set Glorbo wants to cover includes hermes, opencode, pi, and whatever else ships next, plus user-declared custom entries. Writing a module per provider doesn't scale.

## 2. Goals

- Surface provider availability (installed? path? version?) in CLI and dashboard, backed by a single source of truth.
- Decompose providers into *configuration* (how to invoke) and *code* (how to parse telemetry) so most new providers need no Elixir changes.
- Allow power users to declare custom providers in `~/.glorbo/providers.toml` with the same schema shipped defaults use.
- Make reply extraction unambiguous — agents write to a unique per-invocation file path, so dispatch never has to parse stdout for the actual response.

## 3. Non-goals (for this spec)

- Full adapter support for hermes/opencode/pi. They ship with invocation config only; `usage_parser = "none"` means no budget tracking until follow-up work.
- Session resumption (`--continue`, `--resume`). Every dispatch is fresh.
- Just-in-time re-detection on dispatch. Snapshot is refreshed manually.
- Response streaming to the dashboard. Reply file is read-on-exit only.
- Publishing user configs to a marketplace. Custom providers are local-only.

## 4. High-level design

One provider registry, two layers:

- **Configuration layer (data):** `priv/providers/*.toml` ships built-in provider definitions. `~/.glorbo/providers.toml` adds user-declared custom entries. Both use the same schema. Entries cover invocation shape, env overrides, reply contract, version-probe config, and optional usage-parser binding.
- **Code layer (modules):** A small set of named `Parsers.*` modules implement telemetry extraction for known CLI output formats. A named-transform registry handles the rare path-construction quirk (today: Claude's `/`→`-` workspace encoding).

`Glorbo.CLI.Registry` is an Agent holding the detection snapshot. Boot runs PATH detection synchronously; version probes only run on explicit refresh.

Dispatch resolves a provider by name, expands invocation templates, runs the CLI in the sandbox, reads the agent's reply from a per-invocation file path, optionally parses usage. Failure to produce the reply file is a hard invocation failure.

## 5. Module layout

```
lib/glorbo/cli/
├── dispatcher.ex               NEW — template expansion + invocation orchestration
├── registry.ex                 NEW — Agent + public API
├── registry/
│   ├── detection.ex            NEW — PATH scan + parallel version probes
│   ├── loader.ex               NEW — TOML load + validation
│   └── provider.ex             NEW — struct
├── parsers/
│   ├── claude_jsonl.ex         EXTRACTED from cli/claude_code.ex
│   ├── gemini_stdout.ex        EXTRACTED from cli/gemini_cli.ex
│   ├── codex_jsonl.ex          EXTRACTED from cli/codex.ex
│   └── none.ex                 NEW — no-op parser
├── path_transforms.ex          NEW — named transforms (slash_to_dash)
├── adapter.ex                  DELETED — behaviour replaced by Registry + Dispatcher
├── claude_code.ex              DELETED — logic split between TOML config + Parsers.ClaudeJsonl
├── codex.ex                    DELETED — logic split between TOML config + Parsers.CodexJsonl
└── gemini_cli.ex               DELETED — logic split between TOML config + Parsers.GeminiStdout
```

The existing adapter files sit directly under `lib/glorbo/cli/` (not under an `adapter/` subdir). The `Glorbo.CLI.Adapter` behaviour in `lib/glorbo/cli/adapter.ex` goes away along with the three adapter modules. `Glorbo.Agent.Dispatch` stops resolving adapter modules by name and instead resolves provider entries from the Registry.

## 6. TOML schema

Shipped defaults: one file per provider under `priv/providers/`. User config: `~/.glorbo/providers.toml` with optional `[[providers]]` array-of-tables.

```toml
# priv/providers/claude-code.toml

name   = "claude-code"
binary = "claude"                            # PATH name or absolute path

# Invocation — templates may reference:
#   {model}, {workspace}, {prompt_path}, {reply_path}, and any named path_transform
args = [
  "--print",
  "--model", "{model}",
  "--output-format", "text",
]
prompt_mode = "stdin"                        # "stdin" | "stdin_dash" | "argv" | "tmpfile_argv"

# Reply contract. Dispatcher generates a unique path per invocation and
# exports it as GLORBO_REPLY_PATH. Agent must write its final reply there.
# Absence or emptiness of the file on exit = invocation failure.
reply_dir               = "{workspace}/.glorbo/outbox"
reply_filename_template = "{timestamp}-{invocation_id}.md"
reply_max_bytes         = 1_048_576          # 1 MiB default (D12)

# Version detection.
version_flag         = "--version"           # "" disables probing
version_regex        = '(\d+\.\d+\.\d+)'
allow_version_probe  = true                  # User entries default false (D13)

# NOTE on TOML layout: tables (`[env]`, `[path_transforms.*]`) must come
# AFTER all top-level key-value pairs. TOML's grammar scopes subsequent
# keys into the most-recent table header, so putting `[env]` mid-file
# would silently consume `reply_dir`, `version_flag`, etc. into the env
# map. Built-in and sample configs below follow this ordering convention.

# Usage parsing (optional).
usage_parser = "claude_jsonl"                # "none" for no budget tracking
usage_path   = { kind = "jsonl_latest_in_dir", path = "{workspace}/.glorbo-claude/projects/{encoded_workspace}" }

# Environment overrides passed to the CLI sandbox.
[env]
CLAUDE_CONFIG_DIR = "{workspace}/.glorbo-claude"

# Path transforms used when expanding templates that can't be a pure substitution.
[path_transforms.encoded_workspace]
from      = "{workspace}"
transform = "slash_to_dash"
```

### Validation rules (all hard-fail at load)

- Duplicate `name` across any file → error with both file paths and line numbers.
- Missing required field (`name`, `binary`, `args`, `reply_dir`, `reply_filename_template`) → error with file + line.
- `version_regex` fails to compile → error with file + line.
- `prompt_mode` not in the enumerated set → error.
- `usage_parser` references an unknown module → error.
- `path_transforms[*].transform` references an unknown named transform → error.
- `reply_max_bytes` not a positive integer → error. Defaults to `1_048_576` (1 MiB) if unset (D12).
- `allow_version_probe` defaults to `true` for built-in providers, `false` for user entries (D13). When `false`, detection performs PATH resolution only — the `System.cmd/3` probe is skipped. Explicit `allow_version_probe = true` in a user entry opts in.
- `source: :builtin | :user` is computed by the Loader (not a TOML field), based on which directory the entry came from (D17).

### Invocation-time env vars

Dispatcher exports a fixed set on every invocation, in addition to the provider's `[env]` block:

- `GLORBO_TASK_ID` — the task definition identifier.
- `GLORBO_INVOCATION_ID` — unique per dispatch; changes on retry.
- `GLORBO_REPLY_PATH` — the fully-resolved reply path.
- `GLORBO_WORKSPACE` — absolute path to the agent workspace.

`agent.md` and skills reference these by name, not by literal path.

## 7. Data flow

### 7.1 Boot

```
Glorbo.Application.start/2
  └── Glorbo.CLI.Registry (Agent child)
        └── load_and_detect/0
              1. Loader.load_all/0
                   - Read priv/providers/*.toml
                   - Read ~/.glorbo/providers.toml (if present)
                   - Validate (see §6)
                   - Return [%Provider{}] (config only)
              2. Detection.detect_all/1
                   - For each provider: System.find_executable(binary)
                     (or stat absolute path if binary is absolute)
                   - Return %{name => %Provider{installed?, resolved_path}}
              3. Pass snapshot as Agent initial_state
```

Boot blocks on load + PATH detection only. No version probes, no network, no CLI invocations.

Load-validation failure is a hard crash on boot — a broken registry file is not a soft error.

### 7.2 Dashboard read

LiveView mounts → `Registry.list/0` → pure `Agent.get` → renders card or table grid. No probing, no IO, sub-ms.

Refresh button emits an event → LiveView calls `Registry.refresh_with_version_probe/0` → rerender on completion.

### 7.3 Refresh

```
Registry.refresh_with_version_probe/0:
  1. Loader.load_all/0                     — re-read TOML (picks up new user entries)
  2. Detection.detect_all/1                — PATH scan
  3. Detection.probe_versions/1            — Task.async_stream
       - One task per provider with version_flag != ""
       - Each: System.cmd(resolved_path, [version_flag], stderr_to_stdout: true, timeout: 3_000)
       - On timeout or non-zero exit: probe_error stored, version = nil
       - On success: match version_regex, store capture group
  4. Agent.update(new_snapshot)
  5. Return :ok
```

Wall-clock ≈ slowest responder, capped at 3s per probe, fanned out in parallel.

### 7.4 Dispatch

```
Agent.Dispatch.run(task_def):
  1. provider = Registry.get(task_def.provider)
       - :not_found → emit provider.unavailable event, mark task failed
       - %Provider{installed?: false} → same
  2. Dispatcher.invoke(provider, task_def, workspace):
       a. Generate invocation_id, timestamp
       b. Expand templates: args, env, reply_dir + reply_filename_template → reply_path
       c. Apply path_transforms where declared
       d. Write prompt file (audit + stdin source)
       e. Build env map: provider.env + GLORBO_* standard vars
       f. Invoke via Sandbox.Bwrap with argv + env + stdin
       g. Wait for exit
  3. Post-run:
       a. Read reply file:
            - exists && non-empty && readable → agent output = contents
            - otherwise → invocation.failed with reason :no_reply_file
       b. If provider.usage_parser != "none":
            - Resolve usage_path (template + transforms)
            - Call named parser module
            - Record in Budget.Ledger
          else:
            - Record invocation with tokens = :untracked
  4. Write audit event (success or failure)
```

The registry is read-only during dispatch. Refresh is the only writer; Agent serializes updates.

## 8. Status and UI classification

Every provider is computed from its snapshot entry, not from a pre-assigned tier:

- **Routable** — `installed? == true` and (`usage_parser != "none"` or user explicitly opts into untracked). Safe to route agent tasks through.
- **Installed, untracked** — `installed? == true` but `usage_parser == "none"`. Routable only if the agent's `agent.md` allows it (opt-in per agent). Budget tracking unavailable.
- **Declared, not installed** — `installed? == false`. Shown in the dashboard for visibility but cannot be routed.
- **Invalid** — TOML validation failed at load. Never reaches the snapshot; surfaces as a boot error instead.

Dashboard colour scheme:

| State                        | Colour | Badge             |
|------------------------------|--------|-------------------|
| Routable                     | green  | "routable"        |
| Installed, untracked         | yellow | "no budget track" |
| Declared, not installed      | grey   | "not installed"   |

`glorbo doctor` prints a table covering the same data: name, installed?, path, version (if probed), usage parser, source (`builtin` or `user`).

## 9. Failure modes and error messages

| Failure                        | Where surfaced                 | Message style                                                            |
|--------------------------------|--------------------------------|--------------------------------------------------------------------------|
| TOML parse error               | Boot crash                     | `providers config error: <file>:<line> <reason>`                         |
| Duplicate provider name        | Boot crash                     | `duplicate provider "<name>" declared in <file1> and <file2>`            |
| Invalid `version_regex`        | Boot crash                     | `providers config error: <file> invalid version_regex: <error>`          |
| Binary missing at invocation   | Dispatch, `provider.unavailable` event | `provider "<name>" declared but binary "<path>" not found`       |
| Reply file missing             | Invocation failure             | `no reply at $GLORBO_REPLY_PATH (agent did not produce required output)` |
| Reply file empty               | Invocation failure             | `empty reply at $GLORBO_REPLY_PATH`                                      |
| Reply file exceeds size cap    | Invocation failure             | `reply exceeded N bytes at $GLORBO_REPLY_PATH (cap: M bytes)` (D12)       |
| Dispatch to untracked provider without opt-in | Dispatch refusal | `agent "<slug>" lacks allow_untracked_budget; cannot route to "<provider>" (usage_parser: none)` (D15) |
| Version probe timeout          | Snapshot entry, dashboard      | `probe timed out after 3s` (non-fatal; provider still shown)             |
| Version probe non-zero exit    | Snapshot entry, dashboard      | `probe exited with code N` (non-fatal)                                   |
| Usage parse error              | Audit event `usage.parse_error`| Logged, invocation still succeeds; tokens recorded as zero               |

## 10. Migration plan

Because the three existing adapters get replaced, the refactor and the auto-detect feature ship together. Suggested sequence:

1. Create `Provider` struct, `Loader`, `Detection`, `Registry`.
2. Write shipped `priv/providers/claude-code.toml`, `gemini-cli.toml`, `codex.toml` matching the current adapter behaviour.
3. Extract parser logic into `Parsers.ClaudeJsonl`, `Parsers.GeminiStdout`, `Parsers.CodexJsonl`. Keep their public API minimal: `parse(source)` → `{:ok, usage()} | {:error, reason}`.
4. Create `PathTransforms` with `slash_to_dash`.
5. Build `Dispatcher` — template expansion + invocation. Unit tests against mocked invocations.
6. Rewire `Glorbo.Agent.Dispatch` to use Registry + Dispatcher instead of adapter modules.
7. Delete old adapter modules and `lib/glorbo/cli/adapter.ex`.
8. Add hermes/opencode/pi TOML entries with `usage_parser = "none"`.
9. Wire dashboard: new LiveView panel (or section on `/health`) reading `Registry.list/0`.
10. Extend `glorbo doctor` to print the provider table.
11. Update `agent.md` docs to reference `GLORBO_REPLY_PATH` contract.

**Breaking change — reply-file contract (D1).** Existing agents that relied on stdout capture for their reply no longer work as-is. The three built-in providers (`claude-code`, `gemini-cli`, `codex`) all ship with the reply-file contract. Agent system prompts must be updated to instruct the CLI to write its final reply to `$GLORBO_REPLY_PATH`. Glorbo's default `new agent` scaffolding (GEP-10) includes this instruction. Users upgrading from v0.0.2 must edit their existing `agent.md` files before their agents will produce non-empty replies. A note is added to the v0.0.3 CHANGELOG under "Breaking changes."

Separately, the provider *name* surface is unchanged — `provider: claude-code | gemini-cli | codex` in `agent.md` still resolves correctly; only the reply-transport changes.

## 11. Open questions

All six open questions below were resolved on 2026-04-17 as part of the
Draft→Accepted transition. Resolutions recorded as D12–D17 in the decision
log. Kept verbatim here for historical context; the binding answers live
in §13.

1. **Where exactly do the dashboard entry points land?** → **Resolved (D16):** new `/providers` LiveView.
2. **Does `agent.md` need a new opt-in field** for "allow this agent to use providers with `usage_parser = "none"`"? → **Resolved (D15):** yes, `allow_untracked_budget: true`.
3. **Reply file size cap?** → **Resolved (D12):** 1 MiB default, overridable via TOML `reply_max_bytes`.
4. **What happens when the user edits `~/.glorbo/providers.toml` while Glorbo is running?** → **Deferred (D14):** no effect until explicit Refresh or restart.
5. **Should custom providers be exposed to the dashboard differently** from shipped defaults? → **Resolved (D17):** yes, `source: :builtin | :user` on the Provider struct.
6. **Version-probe privacy concern** → **Resolved (D13):** user entries must opt in via `allow_version_probe = true`.

## 12. Test strategy

- **Loader:** table-driven tests for each validation rule (duplicate, missing field, bad regex, unknown parser name, unknown transform).
- **Detection:** tests with a temp directory on `PATH`, symlinks, missing binaries, absolute-path `binary` values.
- **Version probe:** mock `System.cmd/3` responses for timeout, non-zero exit, regex miss, regex hit.
- **Dispatcher:** template-expansion unit tests, reply-file-present, reply-file-missing, reply-file-empty, reply-file-truncated.
- **Parsers:** reuse existing fixtures from the old adapter tests; keep parity.
- **Integration:** end-to-end test with a fake CLI shell script that writes to `$GLORBO_REPLY_PATH` — round-trip through Dispatcher, Registry, Agent.Dispatch.

## 13. Decision log

Each entry: **decision** / **alternatives considered** / **why this choice**.

### D1. File-only reply, no stdout fallback

- **Decided:** agents must write their final reply to `$GLORBO_REPLY_PATH`. Missing or empty file = invocation failure.
- **Alternatives:** stdout only with response-boundary markers the agent is prompted to emit; hybrid "prefer file, fall back to stdout extraction"; full-stdout capture with per-provider regex extractors.
- **Why:** hybrid creates ambiguity ("did the agent produce the file, or are we parsing stdout this time?") — exactly the kind of "maybe works" contract we don't want. Boundary markers are CLI-agnostic but still brittle (agent forgets to emit them, CLI chrome sneaks between markers, escaping issues). File-only is a hard contract: succeeded or didn't. Sandbox isolation is already there, and `agent.md` + skills are the right place to enforce the reply-file discipline.

### D2. Per-invocation reply paths, not fixed filenames

- **Decided:** Dispatcher generates a unique path per invocation (`{timestamp}-{invocation_id}.md`) and exports it via env var.
- **Alternatives:** fixed filename like `reply.md` under the workspace; per-task (not per-invocation) filename.
- **Why:** fixed filenames collide on back-to-back tasks and on retries. Per-invocation is zero-ambiguity and parallelism-safe by construction. Also produces a natural audit trail — every reply persists under its own name. Cost is negligible (string formatting + one dir).

### D3. Detect only PATH by default; version probes only on explicit refresh

- **Decided:** boot runs `System.find_executable/1` per provider. Version probes (`System.cmd(bin, [version_flag])`) only run when the user clicks refresh or runs `glorbo doctor --probe`.
- **Alternatives:** always probe versions; cache probe results with TTL; filesystem watcher on PATH.
- **Why:** PATH detection is sub-millisecond per provider; probes are 10s–100s of ms and can hang. Blocking boot on probes is wrong; probing in the hot path of dashboard mount is wrong. Manual refresh puts the user in control of when to pay the cost, and the dashboard being stale by a few minutes is cosmetic.

### D4. Sync detection at boot, not async

- **Decided:** boot runs detection synchronously and hands the result to the Agent as initial state.
- **Alternatives:** Agent starts empty, Task.Supervisor fires detection async, UI shows "detecting..." until it settles.
- **Why:** PATH detection is fast enough to be imperceptible. Async adds a transient UI state, a wait-for-settle step in tests, and an extra supervisor child for no real benefit. Refresh uses the same code path and isn't tied to boot — staying sync at boot doesn't limit runtime adaptability. The concern about post-boot CLI uninstalls is a separate problem (JIT re-check on dispatch, deferred).

### D5. Agent (GenServer) for the snapshot, not ETS or persistent\_term

- **Decided:** `Glorbo.CLI.Registry` is a simple Agent wrapping `%{name => Provider.t()}`.
- **Alternatives:** ETS table for lock-free reads; `:persistent_term` for fastest reads.
- **Why:** ~6 providers, infrequent reads. ETS's lock-free advantage doesn't matter at this scale; the plumbing ceremony does. `:persistent_term` is designed for rarely-changing data — rewrites trigger global GC. Agent is the Elixir-native shape here and the rest of Glorbo uses similar patterns. Upgradeable later if profiling shows contention.

### D6. Config-shaped invocation, code-shaped telemetry parsing

- **Decided:** invocation shape (argv, env, prompt mode) lives in TOML; telemetry parsing lives in named `Parsers.*` modules referenced by name from TOML.
- **Alternatives:** module-per-provider (existing shape — one module per CLI handling both); everything in code; everything in config including parsers (e.g., JSONPath expressions in TOML).
- **Why:** all three existing adapters decompose cleanly. Invocation is genuinely data (different flags, env vars, stdin semantics); telemetry is genuinely code (different discovery strategies, different accumulator logic, different cumulative-vs-delta semantics). Pushing parsers into config would require a mini-language (JSONPath, regex, stream-fold) that'd end up bigger than just writing the module. Splitting at the module-name reference keeps contracts simple: one named parser = one Elixir function, opaque to the config layer.

### D7. Drop the tiered-status concept (routable / placeholder / custom)

- **Decided:** every provider is a TOML entry. Status is computed from two fields (`installed?`, `usage_parser`) rather than assigned via tier.
- **Alternatives:** hardcoded built-in placeholders module, explicit `status` field in TOML, three separate registries.
- **Why:** tiers were premature — once invocation is config-driven, "built-in placeholder" and "custom" look identical at every layer except where the TOML file lives. Derived status is simpler: one set of rules applied uniformly. Avoids a `status` field that could contradict the other fields (`status: "custom"` + `usage_parser: "claude_jsonl"` would be nonsense to guard against). UI can still distinguish via the `source` field for display.

### D8. TOML for user config, not JSON or Elixir (.exs)

- **Decided:** TOML for both shipped defaults and user config.
- **Alternatives:** JSON (Jason is already a dep); Elixir (.exs, matches project language).
- **Why:** JSON is a poor fit for human-editable config — no comments, strict quoting, fiddly trailing commas. `.exs` is a security footgun (arbitrary code execution on `Code.eval_file/1`) and gives poor error messages when malformed — fine for `config/runtime.exs` where you need env-var interpolation, wrong for a user-authored static registry. TOML is purpose-built for config, has comments, has trailing-comma tolerance, and has `[[array-of-tables]]` that reads naturally for "list of providers." Cost is one Hex dep with no transitive deps.

### D9. Hard-fail at load on TOML errors

- **Decided:** duplicate names, missing required fields, invalid regex, unknown parser/transform refs → boot crash with file + line + reason.
- **Alternatives:** log warnings and skip invalid entries; partial-registry mode; lint command separate from boot.
- **Why:** a silently-broken registry is worse than a loud crash. If a user's `~/.glorbo/providers.toml` has a typo, they'd rather be told at boot than watch half their providers quietly vanish from the dashboard. Duplicates especially — "silently override" is the kind of behaviour that masks a real config conflict. Loud boot errors with line numbers are easy to fix; silent wrong-state is a debugging rabbit hole.

### D10. No sessions in v1 — every dispatch is fresh

- **Decided:** invocations use `--print` (or equivalent) without `--continue` / `--resume`. Each task is a cold start.
- **Alternatives:** opt-in session-resume per agent (`session_mode: "fresh" | "continuous"` in `agent.md`); always-resume; configurable per-provider.
- **Why:** sessions have real wins (prompt caching = ~10% input cost on follow-ups, context continuity, plan-state persistence) but introduce statefulness that bleeds into the dispatch contract — accounting becomes delta-based, session poisoning needs a reset primitive, provider asymmetry (Claude/Codex support it cleanly, Gemini less so, hermes/opencode/pi TBD). Worth a dedicated phase later. Staying fresh-per-dispatch keeps the v1 contract simple: prompt in, file out, done.

### D11. Split the CLI auto-detect feature into a bigger refactor, not a bolt-on

- **Decided:** do the registry + Dispatcher refactor first; auto-detect is a natural consequence.
- **Alternatives:** add auto-detect on top of the existing three-adapter shape, refactor later.
- **Why:** auto-detect as originally scoped was mostly plumbing around a tiered-status concept that got invalidated by the config-driven insight. Shipping auto-detect on the current shape would mean writing code that gets rewritten in the next phase. The refactor is larger but eliminates duplicate work; auto-detect falls out of it for ~80% free.

### D12. Reply file size cap defaults to 1 MiB, overridable per provider

- **Decided:** `reply_max_bytes = 1_048_576` is the default. Providers may override in TOML. Exceeding the cap on exit is an invocation failure with reason `:reply_too_large`. The cap is checked via `File.stat/1` before reading the file (cheap) and is recorded in the audit `agent.complete` failure event.
- **Alternatives:** unbounded (current stdout behaviour has no cap either); a single global cap in config; streaming read with mid-stream abort.
- **Why:** unbounded is a disk-fill DoS waiting to happen once agents start writing files (stdout capture was naturally bounded by OS pipe buffers plus CLI process memory; files have no such limit). 1 MiB is generous — a 1 MiB markdown reply is ~250k English words — and the audit-log overhead of recording caps-exceeded events gives the Director visibility. Per-provider override covers the edge case of providers that legitimately return long outputs (e.g. full-page HTML rendering).

### D13. Version probes on user-declared providers require explicit opt-in

- **Decided:** built-in providers have `allow_version_probe = true` by default. User-declared providers in `~/.glorbo/providers.toml` default to `false`; running a version probe requires explicit `allow_version_probe = true` per entry.
- **Alternatives:** always probe (current spec draft); probe only binaries under a trusted-path allowlist (`/usr/bin`, `~/.local/bin`, `/opt/*`); never probe user entries.
- **Why:** running `claude --version` is a known-safe operation. Running `<arbitrary-user-binary> --version` on every boot-time refresh and every dashboard click is not — a malicious or buggy third-party CLI could do anything when invoked with `--version`. Trusted-path allowlists are fragile (users install tools everywhere). The least-surprise policy is: user entries opt in by saying so. Detection still shows the provider as installed? based on PATH presence; only the version string is gated. This matches how `nix`, `guix`, and most package managers treat user-contributed entries (opt-in execution of arbitrary scripts).

### D14. `~/.glorbo/providers.toml` hot-reload deferred

- **Decided:** edits to `providers.toml` require explicit refresh (dashboard button, `glorbo doctor --probe`, or restart) to take effect.
- **Alternatives:** `file_system` watcher auto-reloads on every write (we already use inotify for the rest of the dashboard); TTL-based reload.
- **Why:** auto-reload introduces a moving-target experience (user is mid-edit, registry flickers between valid/invalid states) and runs validation on every save — noisy, confusing error surface. Explicit refresh is cheap (sub-second) and keeps the "registry is a known snapshot" mental model intact. Can be revisited if users complain; the cost of deferring is one extra click.

### D15. `agent.md` opt-in for untracked providers: `allow_untracked_budget: true`

- **Decided:** dispatching through a provider with `usage_parser = "none"` requires `allow_untracked_budget: true` in the agent's `agent.md` frontmatter. Missing or `false` causes Dispatch to refuse with a clear error before any invocation.
- **Alternatives:** global config flag; per-company flag; silent acceptance (current spec draft implied this).
- **Why:** budget tracking is a product invariant — "you will always know what each agent costs." Providers without a parser break that invariant. The opt-in is agent-level rather than global because an organisation might reasonably want `pi` (untracked, local-only) for their research agent while requiring `claude-code` (tracked) for their engineer. A single field per agent makes the tradeoff visible in the file-as-source-of-truth layout: reading `agent.md` tells you whether that agent's spend is observable.

### D16. Dashboard entry point: new `/providers` LiveView

- **Decided:** add `/providers` as a standalone LiveView route rather than bolting onto `/health`.
- **Alternatives:** section on `/health`; tab within the system-health page; inline card on company overview.
- **Why:** `/health` is deliberately terse (status-code-style green/red checks) and widening it with a provider table dilutes the at-a-glance value. Providers have their own interaction surface (per-row refresh, per-provider detail drilldown in future milestones, user-config management) that deserves a dedicated page. Splitting avoids one LiveView trying to be two things.

### D17. `source: :builtin | :user` as a computed field on the Provider struct

- **Decided:** the Loader tags each entry with `source: :builtin` when it came from `priv/providers/*.toml` and `:user` when it came from `~/.glorbo/providers.toml`. This is a runtime-only field — TOML authors never write it.
- **Alternatives:** omit the field entirely; require authors to declare it (sanity check); track in a separate index.
- **Why:** the UI (and the future `glorbo doctor` table) wants to visually differentiate user entries from shipped defaults — dashboard badges, diagnostic filtering, security audit scope. Computing from the load path is zero-ceremony for authors and immune to manipulation (a user TOML claiming `source: :builtin` can't actually be a builtin). Named atoms are fine here since the possible values are a closed set known at compile time — GEP-12's no-user-input-atoms rule doesn't apply.

## 14. Related notes

- **GEP-4** — CLI-tool agents; this GEP refactors the hand-written adapter pattern into config + named parsers.
- **GEP-1** — GEP process (why this lives at `docs/geps/` rather than the retired `.planning/` tree).
- `DESIGN.md` §4.2 — existing CLI-agent architecture, still correct at the invariant level (filesystem as source of truth, etc.); adapter-per-provider section becomes outdated after this ships.
- Git history (pre-2026-04-17) — original note captures that sparked this GEP (`2026-04-16-support-opencode-pi-hermes.md`, `2026-04-16-gsd-plan-only-workflow.md`) were deleted with the rest of `.planning.archive/`; `git log --all` finds them.
