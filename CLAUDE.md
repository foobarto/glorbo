# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Glorbo shipped **v0.0.2** (Milestone 01 — CLI-agent runtime): Phoenix/LiveView dashboard, SQLite-backed Ecto, `glorbo` CLI (`up`/`down`/`doctor`/`init`/backup/restore), and Burrito single-binary release. Source lives under `lib/` (`glorbo`, `glorbo_web`). Agents are CLI-tool subprocesses (`claude`, `gemini`, `codex`) run under `bwrap`; no Python runtime and no container runtime — see GEP-5 D6 for the Podman-dropped decision.

`DESIGN.md` is the authoritative architectural spec; `README.md` is the user-facing pitch. When they disagree, `DESIGN.md` wins. `CHANGELOG.md` tracks what has actually shipped.

## Coding discipline

Four principles, adapted from Karpathy's coding guidelines. These override the "move fast" impulse.

1. **Think before coding.** Don't assume, don't hide confusion, surface tradeoffs. When a request has multiple plausible interpretations, state them and pick one *visibly* — don't silently choose. For non-trivial work, sketch the plan (one paragraph, maybe a bullet list of steps) before opening a file. If a requirement is ambiguous and the ambiguity is load-bearing, ask.

2. **Simplicity first.** Minimum code that solves the problem. No speculative abstractions, no unrequested configurability, no defensive error-handling for scenarios that can't happen. Three similar lines is cheaper than a premature abstraction. When adding a helper, ask: "does the *current* problem need this, or am I building for a hypothetical?"

3. **Surgical changes.** Touch only what you must. Preserve existing style in the files you're editing — don't rename vars, reformat neighbouring lines, or "improve" unrelated sections while passing through. When your change orphans an import or a function, remove *those*; leave pre-existing dead code untouched unless the user asks for cleanup. Mockup-alignment sessions and refactoring sprints are the exceptions — they're declared wide-scope up front.

4. **Goal-driven execution.** Define success concretely before implementing. "Fix the bug" → "write a test that reproduces it, make the test pass." "Match the mockup" → "screenshot the view, diff against the reference, list the deltas, close them." Loop until the test passes / the diff is closed, not until you *feel* done. This project's browser-verification loop (agent-browser screenshots against `~/Pobrane/abc.zip`) is this principle applied to UI.

Success looks like fewer churned lines, no collateral rewrites, and clarifying questions ahead of implementation rather than reverted commits after it.

## Common commands

- **Setup:** `mix setup` (fetches deps, creates/migrates dev DB, installs esbuild).
- **Run dev server:** `mix phx.server` → `http://localhost:4000`. (Live-reload needs host `inotify-tools`; optional.)
- **Tests:** `mix test` (alias creates/migrates test DB first).
- **Format + lint gate:** `mix precommit` — compiles with `--warnings-as-errors`, prunes unused deps, formats, runs tests. Run this before committing non-trivial changes.
- **Credo (strict):** `mix credo --strict` — zero findings is the ship bar (see commit history).
- **Assets:** `mix assets.build` / `mix assets.deploy` (esbuild via Hex wrapper, no npm).
- **Release:** `mix release` (Burrito-wrapped single binary in `burrito_out/`).

Elixir/OTP pinned in `.tool-versions`: Elixir 1.18.4 / OTP 28.0.

## Architecture — load-bearing invariants

The full architecture is in `DESIGN.md`. These are the constraints that span multiple files and are easy to violate:

- **The kernel is the policy engine.** Permissions declared in `agent.md` frontmatter (resource:action:scope) must be enforced at *two* layers: the Elixir Router (application) and the Linux kernel via `bwrap` mount namespaces. Application-only checks are a design bug — if an agent lacks `projects:write:foo`, the filesystem must physically reject the write. Detail: **GEP-5**.
- **Filesystem is the source of truth.** `~/.glorbo/companies/` is user data and is never modified by upgrades. `~/.glorbo/glorbo.db` (SQLite) is **derived data**: `glorbo reindex` must be able to fully reconstruct it from the filesystem. Never store anything in SQLite that isn't rebuildable from markdown/JSONL on disk. Detail: **GEP-3**, **GEP-7**.
- **One-way inbox/outbox flow.** `agents/<name>/inbox/` is write-only for Elixir, read-only for the agent. `agents/<name>/outbox/` is write-only for the agent, read-only for Elixir. Agents never touch each other's directories directly — Elixir's Router mediates every transfer.
- **Audit log is append-only.** `audit/YYYY-MM.jsonl` entries are never modified or deleted. Ever.
- **No Python anywhere.** The pre-pivot plan to host a Python agent runtime inside Podman was dropped (GEP-5 D6). Glorbo wraps existing CLI tools; there is no Python on the host and none in any container. Adding Python deps to the Elixir side is off-spec.
- **Company isolation is absolute.** Each company's agents see only that company's directory through bwrap mount namespaces. There is no cross-company access mechanism at any layer.
- **Crash isolation follows the OTP supervision tree.** Agent crash → only that agent restarts. Company crash → only that company's agents restart. Dashboard and other companies are unaffected. Preserve this when wiring new supervisors.

## Tech stack

- **Orchestration/dashboard:** Elixir/OTP + Phoenix LiveView + Phoenix Channels, Ecto with `ecto_sqlite3`, `file_system` (inotify) for filesystem watching, `mix release` (Burrito-wrapped) for single-binary distribution.
- **Agent runtime:** existing CLI tools (`claude`, `gemini`, `codex`, etc.) invoked as `bwrap`-sandboxed subprocesses. Each CLI handles its own auth, model routing, tool-use, and telemetry. See GEP-4.
- **LLMs:** configured per-agent in `agent.md` via a `provider:` field referencing a CLI adapter. Auth lives in each CLI's own home dir (`~/.claude/`, `~/.gemini/`, `~/.codex/`), bind-mounted read-only into the sandbox.

## Design decisions — GEPs

Non-trivial design changes to Glorbo are captured as **GEPs (Glorbo Enhancement Proposals)** in `docs/geps/`. See `docs/geps/0001-gep-purpose-and-guidelines.md` for the full process and `docs/geps/README.md` for the index.

**When to propose a new GEP:**

- The user is **planning** a significant change — a new feature, a non-trivial refactor, a shift in architecture, a new public contract (CLI flag, config schema, on-disk layout, API surface), or anything that touches a load-bearing invariant documented in an existing GEP or `DESIGN.md`.
- The user has **already worked on** a significant change ad-hoc (without a prior GEP) and the decisions behind it are worth preserving. Retrofit as an Informational GEP capturing what shipped and why.
- The change reverses or materially extends an earlier decision.

**When NOT to propose a GEP:**

- Bug fixes, dependency bumps, refactors contained to one module that don't change behaviour, doc tweaks, performance work without API changes.

**How:** invoke the `glorbo-new-gep` skill. It walks the user through a Q&A covering scope, design, alternatives, and the decision log. The skill produces a well-formed GEP file in `docs/geps/`, updates the README index, and maintains bidirectional links with referenced GEPs.

Proactively suggest creating a GEP when the user describes work that meets the "when to propose" criteria — don't wait to be asked. If they decline, respect that; if they agree, start the skill.

## Historical planning artifacts

This project previously used GSD v1 planning under `.planning/`. As of 2026-04-17 the tree was archived and then deleted — the decisions it recorded are now captured in the GEPs above, and anything else that mattered lives in git history. If you ever genuinely need v0.0.1/v0.0.2 phase plans, `git log --all` + checking out a pre-2026-04-17 commit is the route. Don't create a parallel doc tree for historical reference; see GEP-11's "archaeology is best served with git" aphorism.

Do not run `/gsd-*` commands — GSD is disabled at the Claude Code level.

## Repo layout notes

- `.agents/skills/` (symlinked from `.claude/skills/`) contains external skill plugins installed from GitHub (see `skills-lock.json`). These are **not Glorbo source code** — they are tooling for Claude Code itself. Don't edit or document them as part of Glorbo.
- `assets/index.html` is the marketing/landing page, unrelated to the Phoenix app that will eventually live here.
- `.bg-shell/` is gitignored Claude Code runtime state.

## Browser UAT — the Bazzite workaround

The Playwright MCP server can't find Chrome on Bazzite (looks for `/opt/google/chrome/chrome`, missing). The `agent-browser` daemon mode is also broken on this host — CDP channel closes the moment any real navigation starts. Use the **manual chrome launch + `--cdp` attach** pattern:

```bash
# Terminal A — launch headless chromium (agent-browser ships one)
~/.agent-browser/browsers/chrome-*/chrome \
  --headless --disable-gpu \
  --remote-debugging-port=9222 \
  --window-size=1400,900 \
  about:blank \
  >/tmp/chrome.log 2>&1 &
disown; sleep 3
curl -sS http://localhost:9222/json/version    # sanity check

# Terminal B — every agent-browser command attaches via --cdp
export AGENT_BROWSER_SCREENSHOT_DIR=$PWD/.reports/uat-modals
mkdir -p "$AGENT_BROWSER_SCREENSHOT_DIR"

npx agent-browser --cdp 9222 open http://localhost:4100/companies
npx agent-browser --cdp 9222 snapshot                    # aria tree with refs
npx agent-browser --cdp 9222 click "@e28"                # click by ref from snapshot
npx agent-browser --cdp 9222 press Escape
npx agent-browser --cdp 9222 screenshot 01-modal.png     # lands in AGENT_BROWSER_SCREENSHOT_DIR
```

Screenshots land at the absolute path in `AGENT_BROWSER_SCREENSHOT_DIR` (if set) or in `$CWD` (relative filenames always). After a screenshot, `Read` the PNG and iterate. For UI work, this is the golden path: snapshot → identify ref → click → screenshot → read.

Notes:

- `npm i -g agent-browser` is blocked by the Claude Code sandbox. Use `npx agent-browser` everywhere — it auto-installs once into the npm cache.
- `npx playwright install chrome` fails on Bazzite (auto-deps uses `apt`). Setting `PLAYWRIGHT_SKIP_BROWSER_GC=1 npx playwright install chromium` works if you need Playwright's bundled binary, but the `agent-browser` bundled chromium is usually sufficient.
- Daemon mode (`npx agent-browser open <url>` without `--cdp`) fails on this host — always pass `--cdp 9222` (or whatever port you chose) once you've launched chrome manually.
- Starting a fresh `mix phx.server` on an **alternate port** (e.g. `PORT=4100`) keeps UAT sessions independent of the live `:4000` dev server. Pair with a `/tmp/glorbo-uat-<ts>` temp workspace (`GLORBO_HOME=...`) when the UAT mutates filesystem state.
