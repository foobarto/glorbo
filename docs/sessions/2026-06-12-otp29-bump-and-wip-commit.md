# 2026-06-12 (pm) — OTP 29.0.2 + Elixir 1.20.1 toolchain, WIP-tree commit, dep bumps

Continuation of the morning `gep-batch-elixir-1.20-warning-zeroing` session.
Picked up against the uncommitted verified-green tree on `release/v0.25.0`.
Mid-session the operator added: **"make sure we are on the latest versions."**

## Task picked

1. Commit the morning's verified-green WIP tree (toolchain 1.20 bump +
   warning-zeroing + GEP-0055 feature + GEP placeholders).
2. "Latest versions" → re-evaluate the deliberately-deferred OTP-29 bump and
   dependency currency.

## What shipped

Four commits on `release/v0.25.0` (local only — not pushed):

- `2caab2d chore(toolchain): Elixir 1.20.1 + OTP 29.0.2, zero compiler warnings`
  — the morning's platform batch + the OTP 28.5 → **29.0.2** bump.
- `6e89348 feat(proxy): GEP-0055 in-process inference proxy for sandboxed agents`
  — the operator's WIP feature (OpenAIProxy + 3 shapes + wiring + tests).
- `f3e07ad chore(deps): bump in-range deps to latest (phoenix, live_view, bandit, credo)`
  — phoenix 1.8.8, phoenix_live_view 1.2.1, bandit 1.12.0, credo 1.7.19 +
  plv-1.2.1 HEEx formatter reflow of 5 templates.

### The OTP-29 decision (reverses the morning's deferral)

The morning doc deferred OTP 29 because Burrito fetches a precompiled ERTS
from the Beam Machine CDN and an OTP-major bump risked the 404 that broke
PR #42 (28.5.0.2 not published). **That blocker is empirically gone for
29.0.2:** `HEAD` on the Burrito URL scheme returned **200 for all four
targets** — `OTP-29.0.2/linux/{x86_64,aarch64}` and `…/macos/universal`.
So the bump is release-safe; the operator's "latest" directive + the gone
blocker → bumped.

- `.tool-versions`: `erlang 29.0.2` + `elixir 1.20.1-otp-29`.
- `ci.yml`: 3× setup-beam `otp-version: '29.0.2'`; comment rewritten; PLT
  cache key → `otp29.0.2-ex1.20.1` (busts the stale OTP-28 PLT).
- README runtime line (was doubly stale — never updated for the morning's
  1.20.1 bump either); CHANGELOG Changed entry; dialyzer-baseline.md
  burn-down entry.

## Design calls I made without you

- **Two-commit split of the intermingled tree.** ~10 lib files carry both
  the morning warning-fixes and GEP-0055 proxy wiring (file-level
  intermingling — clean path-split impossible). Put all GEP-0055-primary
  files in the feature commit (warning fixes ride along, noted in both
  messages); everything else in the toolchain commit. Committed locally,
  did **not** push (your standing rule).
- **In-range dep bumps applied; `req` 0.5→0.6 deferred.** phoenix/plv/
  bandit/credo are within existing `~>` ranges → bumped + verified.
  `req` 0.6.1 is out-of-range (breaking 0.x) **and** the upgrade target is
  GEP-0055's proxy client → left for its own tested pass.
- **`.tool-versions` pins the CI-correct latest even though mise can't
  build OTP locally on this host** (see gotcha below); mise falls through
  to PATH (linuxbrew OTP 29), so commands still work.
- **gitignored `/priv/plts/`** — 10 MB of stale OTP-28.5/ex-1.19.5 dialyzer
  PLTs were untracked-but-not-ignored; never commit build artifacts.

## Gates

- `mix precommit` **exit 0** under Elixir 1.20.1 / OTP 29 — twice (post-
  toolchain, post-dep-bump). **3063 passed, 45 excluded.**
- Compile `--warnings-as-errors` **0 warnings** under OTP 29 (the morning's
  36→0 holds; no new OTP-29 warnings).
- Dialyzer **111 findings ≤ 169 baseline** under OTP 29 — the bump *resolved*
  false positives (count dropped). Baseline kept at 169 pending CI's exact
  count (cross-host variance). Only GEP-0055 findings: 2 redundant
  `pattern_match_cov` arms in `openai_proxy.ex` (harmless dead-defensive).
- `mix format --check-formatted` clean.
- Burrito local release build (`mix glorbo.build_local`) — see review
  questions (running at write time; confirms the 29.0.2 ERTS CDN fetch).

## Skipped / not done

- **req 0.5 → 0.6** — deferred (out-of-range + GEP-0055-entangled).
- **Dashboard UAT for phoenix_live_view 1.2.1** — the suite covers LiveView
  functionally (LiveViewTest), but the 1.1→1.2 minor warrants a browser
  pass on the dashboard before release. Not done this session.
- **SymlinkGuard `/home → /var/home` GEP-0060** — still the morning's #1
  open item; not started (the "latest versions" directive took priority).
- **GEPs 0056–0059 Draft→Implement** — still placeholders.

## Local toolchain gotcha (this Atomic Fedora host)

mise builds erlang from source via **kerl**, which **fails here**: erlang
29.0.2 dies at `erts/configure` (`kill: No such process` — PID-namespace
quirk); the one erlang that did build, 28.0.2, has **broken crypto**
(`undefined symbol: EVP_sm4_cbc` — OpenSSL mismatch). The morning's pinned
`erlang 28.5` had silently gone **missing**. The working local runtime is
**linuxbrew's OTP 29** (`erts-17.0.1`, crypto OK) + **mise's Elixir
1.20.1** — that combo ran every gate this session. CI is unaffected
(`erlef/setup-beam` uses precompiled OTP, not kerl). For local work, use:
`PATH=…/mise/installs/elixir/1.20.1-otp-29/bin:/home/linuxbrew/.linuxbrew/bin:$PATH`.

## Things I'd like your review

1. **OTP 29.0.2 bump** — I reversed the morning's deferral because the CDN
   now serves 29.0.2 ERTS for all four Burrito targets. OK to carry into
   the release? (Belt-and-suspenders: the local Burrito build is the
   real-world confirmation — result noted above/next.)
2. **`req` 0.5 → 0.6** — want it folded in (its own tested pass), or leave
   pinned at `~> 0.5`?
3. **plv 1.2.1 dashboard UAT** — want me to run a browser pass before this
   release branch moves on?
4. **Commit structure** — two-commit split (toolchain / GEP-0055) plus a
   deps commit. Reword/reslice before the eventual maintainer squash-merge?
