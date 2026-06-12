# 2026-06-12 — odysseus cross-pollination GEPs + Elixir 1.20.1 bump + warning-zeroing

Session ran against the uncommitted GEP-0055 working tree on `release/v0.25.0`
(same tree the 2026-06-10 review round left in place). **Nothing committed**
this session either — commit structure is the operator's call (the GEP-0055
`### Added` CHANGELOG block + this batch are all still uncommitted).

Origin: a deep security review of `pewdiepie-archdaemon/odysseus` (a self-hosted
AI workspace) → cross-pollination candidates for glorbo → operator asked to land
the GEP drafts, then finish WIP-adjacent items.

## What shipped

### 1. Four GEP placeholders (renumbered around the in-flight 0055)
Operator's uncommitted **GEP-0055** (in-process inference proxy) already held the
number, so the odysseus-derived drafts are **0056–0059** (`status: Placeholder`,
validator stays lax on contents):
- **0056** untrusted-content framing — data-not-instructions across agent
  boundaries (PRIORITY). Open question to settle at Draft→Accepted: amend
  `SECURITY.md`'s "prompt-injection-within-grants out of scope" for the
  *cross-agent propagation* case.
- **0057** deep-research task type (governed gather/read/synthesise → portable
  sanitised HTML artifact; needs 0056's framing first).
- **0058** semantic-recall index (optional, **unbundled**, default-off; rebuildable
  derived index; pure-Elixir/Burrito constraint).
- **0059** hwfit — native hardware→model fit (closes "fully local out of the box":
  `detect-providers` only WIRES a running server; nothing downloads/serves).
  Pure-Elixir scoring embeds; serving stays a subprocess.

README index updated; `mix gep.validate` → **All checks passed (59 GEPs)**.

### 2. Fixed the operator's GEP-0055 file (was failing the validator)
`0055-openai-v1-proxy-for-sandboxed-agents.md` frontmatter had unquoted `note:`
scalars containing `: ` and `{…}` → YamlElixir `:block_mapping_value_not_allowed`
at line 18. Converted the three `note:` values to `|` block scalars. The
validator was **already red** before this session (cascaded into 5 cross-ref +
README/numbering errors); now green.

### 3. Ported the dispatcher nil.parse fail-closed fix
`cli/dispatcher.ex` — `parse_usage/4` + `parse_acp_usage/4` dispatched on
`Parsers.module_for(name)` which is typed `module() | nil`, so 1.20 inferred a
`nil.parse/1`. Extracted `run_usage_parser/3` with a `nil` head returning
`{nil, {:unknown_usage_parser, name}}` — kills the warning + a latent crash,
matches the existing `{usage, reason}` contract.

### 4. Toolchain → Elixir 1.20.1-otp-28 ("stick to latest elixir")
- `.tool-versions`: `elixir 1.20.1-otp-28`; **erlang kept at 28.5**.
- `ci.yml`: 3× `elixir-version: '1.19.5'` → `'1.20.1'`; **otp-version kept
  `28.5.0.1`**. Rationale (matches the existing CI comment): Burrito fetches a
  Beam Machine precompiled ERTS; an OTP-major bump risks the exact 404 that hit
  PR #42 (28.5.0.2). `mix.exs` `elixir: "~> 1.18"` already permits 1.20.
- OTP-29 was considered and **deferred** — separate, riskier change.

### 5. Drove all 36 Elixir-1.20 compiler warnings to ZERO
1.20's set-theoretic checker surfaced 36 own-code warnings (0 under 1.19.5).
Resolved via a 6-agent disjoint-file workflow + manual finishing:
- **22 safe removals** (unused `require Logger`, dead `x || default`, redundant
  catch-all `_ ->`/`other ->` arms the checker proved unreachable).
- **1 real bug found + fixed:** `agent_live.ex` `read_workspace_file/2` dropped
  `:symlink_in_path` from its error pass-through list → symlink-in-path opens
  were masked as `:not_found` ("File no longer exists.") instead of the
  symlink-refusal message. The H10 symlink *enforcement* was never affected;
  only the error label. **Regression test added** (`agent_live_test.exs`,
  "open_file across a symlinked dir is refused with the symlink message").
- **11 defensive-net cases** resolved without losing posture:
  - **Validators** (`reindex.valid_replay_slug?`, `benchmarks.valid_run_id?`):
    `reindex` got a **reachability-restructure** (dropped the redundant
    `is_binary` at 3 callers so the `_ -> false` traversal-defense net stays
    *reachable*, behaviour-identical); `benchmarks` removed the dead `_ -> false`
    (public callers are `when is_binary`-guarded).
  - `benchmarks/orchestrator.ex:186` — was NOT the bug the workflow brief
    assumed; the success map already carries `:reply` (line 185). Simplified the
    residual arm to `{:ok, inspect(other)}`. (Root cause is the stale
    `@type dispatch_result` at `agent/dispatch.ex:71` omitting `:reply`/
    `:reply_path` — worth widening later, but not load-bearing for the warning.)
  - Dead error/catch-all arms removed with documenting comments where a contract
    dependency or invariant was worth flagging: `cli/install.format_reason`,
    `cli/scaffold/company`, `company/router.extract_to`, `init/orchestrator.
    step_reindex`, `providers/model_catalog` (static refresh_one),
    `restore.maybe_fixer`, `sandbox/bwrap` (`_ ->` after `System.cmd`),
    `mcp/session.schedule_idle_timeout` (SSE guard — the no-timeout-for-SSE
    invariant is already enforced by callers; documented).
- **2 the `lib/glorbo` grep initially missed** (under `lib/gep`/`lib/mix`):
  `gep/validator.ex` dead `record.type || "Standards"`; `glorbo.release_formula`
  unused `require Logger`.

### 6. File.stream! 1.20 deprecations
15 sites across 13 files used the old `File.stream!(path, [], :line)` arg order
(deprecated in 1.20). Swapped to `File.stream!(path, :line, [])` — behaviour-
identical (same modes `[]`, same `:line`).

## Gates

**`mix precommit` exit 0** under Elixir 1.20.1 (compile `--warnings-as-errors`,
`format --check-formatted`, `credo --strict`, full suite **3063 passed, 45
excluded**). `mix gep.validate` → all 59 pass. Run with the mise toolchain
(`~/.local/share/mise/installs/elixir/1.20.1-otp-28/bin` + erlang 28.5) — NOT
linuxbrew's 1.20.0 (OTP 29), which fabricates a different warning set.

## Not done / next (operator's call)

1. **SymlinkGuard `/home → /var/home` Atomic fix (P1, hits EVERY project).**
   Robust design below — captured here so it survives. Should become **GEP-0060**
   + test-first implementation.
2. **GEPs 0056–0059 Draft→Implement cycle** — 0056 (untrusted framing) first to
   Draft (surface the SECURITY.md decision); 0059 (hwfit) most self-contained to
   implement.
3. **Commit the WIP tree** — GEP-0055 feature + this batch are uncommitted on
   `release/v0.25.0`. Structure is the operator's call.
4. Optional: widen `agent/dispatch.ex:71` `@type dispatch_result` (`:reply`/
   `:reply_path`) — the real source of the orchestrator:186 misleading inference.

## SymlinkGuard robust design (for GEP-0060)

**Problem.** `Glorbo.Sandbox.SymlinkGuard.assert_no_symlink_segment!/2` walks
*every* ancestor from `/` and refuses any symlinked segment (PR-#35 threat: an
agent plants a symlink in its writable tree → bwrap resolves it host-side →
mounts something outside). On Atomic (`/home → /var/home` symlink) the first real
segment is a symlink, so it refuses everything (`reindex` → `indexed=0`, company
boot blocked). Used by ~10 callers.

**Key insight.** The threat is an *agent* planting a symlink, and an agent can
only write *below* the glorbo home. Symlinks at/above the home (`/home`,
`/var/home`, `$HOME`, `.glorbo`) are OS/operator-trusted and not agent-writable —
checking them is pure false-positive with zero security gain.

**Fix — make the guard base-aware:**
1. **realpath-canonicalize the trusted base** once (resolves `/home → /var/home`);
   the base (glorbo home, or a GEP-27 operator-approved grant root) is
   operator-established, not agent-writable — resolving its symlinks is the
   intended canonicalization.
2. **Containment check** — the target must resolve within the canonical base.
3. **Symlink-walk ONLY segments strictly below the canonical base** — the
   agent-controllable portion. The PR-#35 property is fully preserved (a planted
   symlink anywhere in the writable tree is still caught); the OS symlink above
   the home just resolves away.

Two-tier rollout: (a) **immediate** — canonicalize the glorbo home at
`default_root/0`/`GLORBO_HOME` so downstream paths are already `/var/home/…`
(promote the todo workaround to default; covers reindex/company-boot/permission
mounts); (b) **complete** — the base-aware guard above, covering GEP-27 external
grants whose ancestors may also be symlinked. realpath in Elixir: a bounded
symlink-resolving walk (no stdlib realpath); reuse existing symlink machinery.
Matches GEP-54 D9's scoping precedent. Test-first: a tmpdir with a symlinked
ancestor accepts a below-base path; a symlink planted *below* the base is still
refused; + external-grant + `..`-escape + non-existent-leaf cases.

Note: `agent_live.ex`'s LOCAL `ensure_no_symlink_on_path/2` walks from the agent
dir down (already scoped) — it does NOT have the Atomic bug; only the shared
`Sandbox.SymlinkGuard` (walks from `/`) does.
