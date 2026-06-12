# 2026-06-10 — GEP-0055 slices 1–4a: review round + fixes

Operator ask: *"review the code, update the documentation if needed,
identify issues with the code and fix them"* — against the uncommitted
GEP-0055 working tree (in-process inference proxy) on
`release/v0.25.0`.

Context note: the GEP-0055 code itself was written in the 2026-06-07/08
sessions, which have **no session journal** (flagged below). This file
covers today's review round only.

## Task: multi-agent review of the GEP-0055 working tree

**Task picked:** Full review of the uncommitted diff (14 modified
files + 7 new) before it ever gets committed.

**What shipped:** A 6-dimension review (dispatch wiring, listener,
security, periphery modules, tests, docs) with one adversarial
verifier per finding — 80 subagents total. 73 findings confirmed,
1 refuted-set. Everything actionable was fixed in this session (next
task); the three deliberately deferred items went to `docs/todo.md` P2.

**Gates:** n/a (read-only phase).

## Task: fix the confirmed findings

**What shipped (code):**

- `lib/glorbo/agent/dispatch.ex` — the via_proxy mint now unwraps
  `ProxyTokens.register/1` (was nesting `{:ok, {:ok, token}}` into
  `GLORBO_PROXY_TOKEN`, a guaranteed crash at bwrap env build); mints
  **only** for resolved `auth: :via_proxy` providers; the
  `*_BASE_URL`/`GLORBO_PROXY_*` env now carries the **inference
  proxy's** URL instead of the GEP-23 CONNECT proxy URL (which embeds
  the CONNECT token in userinfo — a credential leak into env vars CLIs
  log); the token is revoked at dispatch end; a via_proxy provider on
  a non-`:proxy` network or with the proxy down fails loudly
  (`:via_proxy_requires_proxy_network` / `:openai_proxy_unavailable`)
  instead of dispatching with a `127.0.0.1:0` placeholder; the test
  seam moved from Application env to the opts keyword
  (`:openai_proxy_url_fun`), matching GEP-23.
- `lib/glorbo/openai_proxy.ex` — body bytes arriving in the same TCP
  segment as the headers are no longer discarded (every real JSON POST
  used to stall 10 s and fail); per-request handlers are unlinked +
  rescue→500 (a handler crash used to kill the linked acceptor); the
  acceptor respawn reuses the existing listen socket (it used to
  re-listen on a NEW ephemeral port, with `packet: :http_bin`, **and
  without the loopback `ifaddr` pin** — i.e. 0.0.0.0); socket ownership
  is explicitly transferred to handlers; `Content-Length` is parsed
  with `Integer.parse` (garbage used to crash via `String.to_integer`);
  the request line is parsed into a tagged tuple (the error tuple used
  to silently destructure as `{method, path}`); the nil-adapter 404
  path actually works now (`nil` IS an atom, so the old
  `when is_atom(adapter)` guard let it through to a crash); upstream
  calls now send the auth headers (they were computed and dropped),
  hit `endpoint-origin + request-target` (the path used to be ignored
  entirely), respect GET vs POST, and have a catch-all error clause;
  added: token-company cross-check (GEP failure-mode table), provider
  `auth == :via_proxy` check, `X-Glorbo-Token` fallback, 405 for other
  methods, 400 on invalid JSON, 15 s head-read deadline (slowloris
  bound), binary-passthrough in `send_json` (no double-encoding).
- `lib/glorbo/sandbox/bwrap.ex` — pasta `-T` now forwards the
  inference-proxy port alongside the CONNECT-proxy port (kernel-level
  gap: without it the netns blocked the listener even with correct
  env). New optional `openai_proxy_url` opt, validated by the same
  loopback-URL parser as the GEP-23 URL.
- `lib/glorbo/providers/native_config.ex`, `cli/harness.ex`,
  `cli/dispatcher.ex`, `providers/model_catalog.ex` — `:via_proxy`
  support end-to-end for the native path: `parse_auth`/`validate_auth`/
  `auth_headers` clauses; harness presents `GLORBO_PROXY_TOKEN` as its
  Bearer credential and skips the (nonexistent) credentials TOML;
  dispatcher points `GLORBO_NATIVE_ENDPOINT` at the proxy URL (was the
  upstream — the harness would have dialed out directly) and stops
  advertising `/creds/provider.toml`; model catalog reads the host env
  var named by `api_key_env` (model-list refresh errored for every
  via_proxy provider before).
- `lib/glorbo/company/supervisor.ex` — collapsed the byte-identical
  `ensure_under_size` / `ensure_under_size_for_openai_proxy_scan`
  duplicate (crossed names), removed the duplicated
  `@max_agent_md_bytes`, fixed the moduledoc child list + the
  "cheap string scan" comment (it's a full parse), documented the
  init-time-scan/company-restart property.
- `lib/glorbo/network/proxy_tokens.ex` — `register/1` back to
  head-pattern + guards (the cond refactor raised `MatchError` instead
  of the curated errors for missing keys), `provider_alias` validated
  binary-or-nil, entry typespec corrected to
  `required(:provider_alias) => String.t() | nil`.
- `lib/glorbo/cli/registry/loader.ex` — kept the native-only
  restriction but rewrote its false rationale ("no CLI speaks the
  proxy's protocol" contradicted the GEP's own multi-shape design);
  it's a slice boundary until D11 lands.
- `mix.exs` — `{:req, "~> 0.5"}` declared (was only transitive via
  burrito; runtime code must not lean on a transitive dep).

**What shipped (tests):** dispatch via_proxy tests rewritten — the old
ones ran with `network: :loopback`, never minted a token, and pinned
the `127.0.0.1:0` placeholder as the contract (both critical wiring
bugs were invisible to them). New tests assert the real mint
(provider_alias, live-then-revoked token, inference-proxy URL ≠
CONNECT URL, `openai_proxy_url` in bwrap opts), the loud failures, and
that non-via_proxy providers get nothing. Listener tests now cover:
single-segment POST (the buffering bug), X-Glorbo-Token, cross-company
401, non-via_proxy-provider 401, unknown-alias 401, 404-without-crash,
malformed Content-Length → 400 **with the port still serving**,
garbage request line, 405, invalid JSON, missing api_key_env → 503,
a 127.0.0.2 connect-refused loopback-bind assertion (the old test
could not fail), and a full stub-upstream round trip asserting the
real key + path + body reach the upstream. Loader: empty/non-string
`api_key_env` + malformed-on-bearer cases.

**What shipped (docs):** GEP-0055 — implementation-plan slice table
(ported from stale gitignored STATE.md, with 4a defined), auth-flow
rewritten to match the implemented company/auth checks, upstream-URL
origin rule documented, CLI first wave re-gated behind D11 + loader
lift, history entry added; DESIGN.md per-company tree gained the
conditional `Glorbo.OpenAIProxy` child; GEP-0008 `extended-by` +55
(mandatory bidirectional link); CHANGELOG `[Unreleased]` entry;
project-profile gained the operator's 2026-06-08 "quality over partial
result" directive (the 06-07 date bump had no content behind it);
moduledocs/comments de-drifted (the listener claimed "no upstream call
yet, stubs return 501" while implementing the upstream call; comments
claimed audit-row writing, path appending, after-block revocation —
none existed); knowledge-graph notes + todo updated.

**Design calls I made without you:**

1. **Kept the loader's native-only `via_proxy` restriction** (vs
   opening CLI providers now). The GEP names claude-code in the first
   wave, but CLI auth_binds haven't been reviewed under the
   no-credentials posture and the settings.json slice (D11) doesn't
   exist; opening it now would half-work. GEP rollout text now says
   so. The dispatch-side CLI env map stays as documented forward work.
2. **via_proxy hard-requires `network: :proxy`** and a reachable
   listener — dispatch fails with a typed error instead of booting a
   CLI pointed at port 0. Loud beats silent per GEP-8 D9.
3. **Two tokens per via_proxy dispatch** (CONNECT + inference), both
   revoked at dispatch end. The "single shared token" the old comments
   described was never what the code did. The audience/scope field
   that would make the separation unforgeable is deferred to todo.md
   P2 (touches `Network.Proxy` too).
4. **Upstream URL = endpoint origin + request target.** Subpath-hosted
   upstreams are a documented limitation. Alternative (endpoint-path
   concatenation) double-prefixes `/v1` for every bundled provider.
5. **ModelCatalog reads the env key host-side** rather than routing
   through the proxy — same trust domain, no listener dependency for a
   UI refresh; audit-parity routing deferred to todo.md.
6. **Did not commit anything** — this tree was uncommitted in-flight
   work when I arrived; bundling my fixes into your commit structure
   is your call.

**Gates:** `mix precommit` exit 0 (compile warn-as-err, format,
docs check, full suite **3058 tests, 0 failures**, 45 excluded);
`mix credo --strict` zero findings (exit 0 verified explicitly);
the file-formats "drift" warning precommit printed regenerated to a
no-op. Security pass: the bwrap argv change (second pasta `-T`
port) reviewed manually — both ports are integers parsed from
loopback-validated URLs, joined with a comma; no agent-controlled
input reaches the argv slot.

**Skipped / not done:** burrito rebuild (`mix glorbo.build_local`) —
deferred until you decide how to commit this tree; audit rows,
usage.json write, streaming, Gemini translation (future slices per the
GEP plan, not regressions); the ProxyTokens audience field, handler
cap, catalog-via-proxy (deferred with rationale in todo.md P2).

**Commit(s):** none (deliberate — see design call 6).

## Task: fold the dependabot PRs into PR #42 (operator ask)

**What shipped:** Applied #44 (mix.lock: earmark 1.4.49,
phoenix_live_view 1.1.31, yaml_elixir 2.12.2, thousand_island 1.5.0
transitive) and #43 (actions/checkout v6.0.3, codeql-action v4.36.1
pins) onto `release/v0.25.0`; full suite re-run on the bumped deps
(3058/3058 green); committed as `c62d27a` with its own CHANGELOG
`### Changed` entry (the GEP-0055 `### Added` entry stayed
uncommitted with its code — the CHANGELOG hunk was split so the
committed file never describes uncommitted work); pushed; closed
#43/#44 with reference comments.

**Design calls:** push was authorized by "fold into this one" (#42
is this branch's PR). The GEP-0055 working tree remains uncommitted
— only the deps fold went out.

**Gates:** `mix test` 3058/3058 on bumped deps before push. CI on
PR #42 re-running post-push.

## Task: PR #42 monitoring — CI fix + review threads (operator ask)

**Task picked:** "keep monitoring PR 42 and fix any tests failing,
make sure all conversations are resolved."

**What shipped (commit `6ff96cb`, pushed):**

- **CI red on `c62d27a` was not a test failure**: Burrito 404'd
  fetching the precompiled OTP **28.5.0.2** linux musl ERTS from Beam
  Machine. `otp-version: '28.5'` had started resolving to the
  brand-new 28.5.0.2 patch release, which Beam Machine hasn't
  published for linux yet (28.5.0.1 → HTTP 200, 28.5.0.2 → 404,
  verified). Pinned `otp-version: '28.5.0.1'` in all three setup-beam
  blocks with a dated drop-when comment.
- **Copilot thread (actions.ex `ensure_dm_channel/3`)**: replaced the
  non-atomic `exists?`+write with an `O_CREAT|O_EXCL` exclusive create
  (`:eexist` = idempotent success) behind the M03
  `ensure_regular_file_for_write/1` lstat gate. Tests: pre-planted
  symlink refused with target untouched; 8-way concurrent-create race
  asserting exactly one canonical header.
- **Codex thread (config.ex PBKDF2)**: rounds segment now `[1-9]\d*`
  — `$0$` (would hang `Pbkdf2.verify_pass/2` on `/login`) and
  leading-zero rounds coerce to `:malformed` → DEGRADED. Tests for
  both shapes.
- Both review threads replied to with the fix summary and **marked
  resolved**; PR #42 now has zero unresolved conversations.

**Gates:** full suite 3062/3062 green + credo --strict clean before
push. CHANGELOG `### Fixed` entries committed in the same commit
(hunk-split again so the uncommitted GEP-0055 `### Added` entry stays
with its code). CI on `6ff96cb`: **all four build jobs green**
(x86_64 24m, aarch64 19m, both macOS cross-builds ~5m; publish jobs
correctly skipped — not a tag). PR #42: 0 unresolved conversations.

**Noticed in passing:** GitHub is forcing Node-20 actions onto Node 24
from 2026-06-16; the pinned `goto-bus-stop/setup-zig` SHA trips the
warning on the macOS cross-build jobs. Logged as a dated P1 in
`docs/todo.md` — needs a bump (or the FORCE env opt-in + verify)
before the 16th.

## Things I'd like your review

1. **Native-only first wave** (design call 1) — agree, or do you want
   CLI `via_proxy` opened sooner at the cost of a partial path?
2. **`via_proxy` ⇒ `network: :proxy` required** (design call 2) — any
   agent config you care about that this would refuse?
3. The 2026-06-07/08 GEP-0055 sessions have **no session journal**;
   the GEP history notes are the only record of the "ollama launch"
   reframing. I did not fabricate a retroactive journal — want one
   reconstructed, or is the GEP history enough?
4. `priv/plts/` sits untracked in the worktree but PLTs live (and are
   gitignored) under `_build/dialyzer_plts/` per mix.exs — looks like
   a stale leftover. I didn't delete it (unfamiliar-file rule); ok to
   remove?
5. The review fleet's full findings list (73 confirmed) is in the
   workflow output if you want the long version.
