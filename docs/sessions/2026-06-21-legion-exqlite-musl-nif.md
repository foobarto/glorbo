# 2026-06-21 — legion.local install won't start (exqlite NIF) + v0.28.5 cut

## Task picked

Operator reported that a freshly installed `glorbo` binary on a remote
host failed to start. Bugfix mode → then release. Diagnosed remotely by
reading the remote host's `~/.glorbo/log.txt` over ssh (authorized).

## Investigation (systematic-debugging)

- Log showed `Failed to load NIF library: Error relocating
  .../exqlite-0.37.0/priv/sqlite3_nif.so: __memmove_chk: symbol not
  found` → `Glorbo.DB.Bootstrap` child dies → supervision tree aborts →
  app exits at boot.
- First hypothesis (musl host) **wrong** — legion is Bluefin/atomic
  Fedora 44, glibc 2.43. Checked instead of assuming.
- Real cause: the Burrito-bundled **ERTS is musl** (`beam.smp` interp =
  `libc-musl-…`, `NEEDED libc.musl-x86_64.so.1`), but the bundled
  **exqlite 0.37.0 NIF is glibc** (`NEEDED libc.so.6`, wants
  `__memmove_chk`/`__memcpy_chk` fortify symbols musl lacks). Burrito
  recompiles `:elixir_make` NIFs to musl with `zig cc` only when they
  build from source; exqlite 0.37.0's `cc_precompiler` **downloads a
  precompiled glibc NIF**, so Burrito's Zig step never touched it.
- "What changed": exqlite **0.36→0.37**. 0.36.0 had no OTP-29 precompiled
  artifact → built from source → musl NIF (`NEEDED libc.so`) → worked.
  The bump silently regressed every release binary, all hosts.

## What shipped

- `config/prod.exs`: `config :exqlite, force_build: true` — forces the
  source build on release builds so Burrito's zig-musl path emits a musl
  NIF matching the ERTS. Dev/test keep the fast precompiled NIF.
- CHANGELOG + `docs/knowledge-graph/notes.md` gotcha entry.
- Landing-page fix (separate commit, earlier today): pinned CDN deps +
  SRI — see `2026-06-21-landing-page-blank-babel8.md`.
- Cut **v0.28.5** (mix.exs + CHANGELOG + README).

## Gates

- **Verified the fix at ELF level** via `mix glorbo.build_local`: rebuilt
  NIF is `NEEDED libc.so`, **zero** `_chk@` fortify syms, **zero** GLIBC
  refs. `./glorbo version` runs clean.
- `mix precommit`: 3388 passed / 0 failures. `mix sobelow --exit`: clean.
- Graphify refresh skipped — no `lib/` changes (config/docs/assets only),
  module graph unchanged.

## Design calls I made without you

- Forced source build via repo config (`config/prod.exs`) rather than a
  CI env var — applies to both local and CI builds, lives in the repo,
  one place. Also drops an opaque precompiled binary from the release
  (supply-chain win, matches the pin-everything posture).
- Bundled the landing-page fix + exqlite fix into one v0.28.5 PATCH.

## Skipped / not done

- No on-host workaround for legion (musl runtime can't load the glibc
  NIF without gcompat-in-musl); the real fix needs a rebuilt binary, i.e.
  this release.

## Commit(s)

- `10dac8e9` fix(site): pin landing-page CDN deps + SRI
- `07bafba9` fix(release): force exqlite source build (musl NIF match)
- `chore(release): cut v0.28.5` (this branch)

## RESUME POINT (paused 2026-06-21 for a reboot)

Release **v0.28.5** in flight as **PR #90** (branch `release/v0.28.5`,
https://github.com/foobarto/glorbo/pull/90). Everything is pushed; git
state survives the reboot.

Branch commits (on top of `origin/main`):
`fix(site)` landing CDN pin → `fix(release)` exqlite force_build →
`docs(session)` → `chore(release): cut v0.28.5` → `docs(session)` privacy
fix (`bb8c012e`).

Done: local gate green (precommit 3388 pass / sobelow clean), exqlite fix
verified at ELF level (musl NIF), privacy_check leak fixed + re-pushed.

**Next steps, in order:**
1. Confirm the re-run **CI `test (x86_64)` is green** on PR #90
   (`gh run list --branch release/v0.28.5 --workflow CI`). First run
   failed only on the privacy_check raw-chat-role line, now fixed.
2. **Resolve ALL PR conversations** — wait a few min for async
   codex/Copilot bot threads to land AFTER CI goes green; re-poll
   `mergeStateStatus` + threads; never trust a single green snapshot.
3. **Squash-merge** PR #90 to main. If `code/snyk` errors on the Snyk
   free-tier SAST quota, `--admin` is REFUSED — get everything else
   green + threads resolved, then HAND OFF to operator to merge via UI.
4. After merge: `git fetch && git switch main && git reset --hard
   origin/main` (local main currently carries the two fix commits).
5. **Sign + push the tag**: `git tag -s v0.28.5 -m …` then
   `git push origin v0.28.5` (GPG key 06FD46A02874AF8D is unlocked in
   the agent; authorized). `release.yml` publishes on the tag — do NOT
   pre-create the GH release.
6. Watch `release.yml` (binaries + tap) AND the Pages `static.yml`
   redeploy (the landing-page fix ships to glorbo.foobarto.me).
7. Tell operator legion needs `glorbo` updated to v0.28.5; offer to scp
   the already-built local `burrito_out/glorbo_linux_x86_64` (musl NIF,
   verified) as an immediate stopgap.

## Things I'd like your review

1. After the release publishes, legion needs `glorbo` reinstalled/updated
   to v0.28.5 to pick up the working binary. Want me to also scp the
   already-built local binary over as an immediate stopgap?
