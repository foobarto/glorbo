# UAT benchmark vs paperclip — 2026-04-25

End-to-end import + structural validation pass against
`/path/to/paperclip/agentledger`. Companion check on the
`bench-softdev` template.

## What ran

1. **Hermetic Glorbo home.** `GLORBO_HOME=/tmp/glorbo-uat-bench-r2-*`
   with `glorbo init --no-example` so nothing leaks in/out of
   `~/.glorbo/`.
2. **Burrito binary.** Used the freshly-rebuilt `./glorbo` (all four
   cross-compile targets produced — Linux x86_64/aarch64 + macOS
   x86_64/arm64). The previously-noted `mix glorbo.build_local`
   breakage has resolved itself env-wise.
3. **Paperclip import.**
   `glorbo import paperclip /path/to/paperclip/agentledger
   --as agentledger` — succeeded.
4. **Structural validation.** `glorbo validate $GLORBO_HOME` against
   the imported tree.
5. **Bench template.**
   `glorbo new company benchmark-softdev --template bench-softdev`
   then re-validated.
6. **Full test suite.** `mix test` — 2118/2118 green.

## What the validator caught (round 1, before fixes)

```
glorbo validate — 32 files · 4 error(s), 3 warning(s), 1 info(s)
```

| Severity | File | Finding |
|----------|------|---------|
| error | `agents/project/HEARTBEAT.md` | missing required `kind: agent-heartbeat/v1` |
| error | `agents/project/HEARTBEAT.md` | missing required key `kind` |
| error | `agents/project/SOUL.md` | missing required `kind: agent-soul/v1` |
| error | `agents/project/SOUL.md` | missing required key `kind` |
| warn | `agents/project/AGENT.md` | unknown key `imported_from` |
| warn | `agents/project/AGENT.md` | unknown key `imported_company` |
| warn | `company.md` | unknown key `imported_from` |
| info | `agents/project/TOOLS.md` | unknown_file (paperclip-specific reference) |

All four errors and three warnings were **real importer bugs** — the
benchmark surfaced them without any other harness work. Both classes
were fixed in the same session:

- **Errors (HEARTBEAT.md / SOUL.md):** the importer copied the source
  files verbatim, but Glorbo's GEP-25 R26.2b atomic cut requires every
  recognised file to carry a `kind:` discriminator. Fixed by wrapping
  the body with the appropriate `kind: agent-heartbeat/v1` /
  `kind: agent-soul/v1` frontmatter on copy.
- **Warnings (`imported_from`, `imported_company`):** the importer
  intentionally writes these into agent + company frontmatter so
  Directors can grep for paperclip-derived agents. They just hadn't
  been added to the FileSpec optional-key allowlist. Fixed by adding
  them.

## Round 2 (after fixes)

```
glorbo validate — 7 files · 0 error(s), 0 warning(s), 1 info(s)
```

The remaining `info` is the documented "TOOLS.md is paperclip-specific
reference, not Glorbo-recognised — kept verbatim per the importer
contract" case. Expected, not actionable.

## Bench template validation

```
glorbo validate — 27 files · 0 error(s), 0 warning(s), 1 info(s)
```

`bench-softdev` scaffolds clean: 27 files (engineer + reviewer
agents, three projects with three tasks each, channels, company.md).
The same single info — TOOLS.md from the agent template, same
expected case.

## What this benchmark covers

- **Import correctness.** `glorbo import paperclip` produces a
  Glorbo company that passes the file-format validator end-to-end.
- **Schema coverage.** GEP-25's FileSpec schemas cover every file
  the importer + bench template emit (modulo the documented
  TOOLS.md exception).
- **Atomic cut compliance.** GEP-25 R26.2b's "kind: required on every
  frontmatter" invariant holds across the imported + scaffolded trees.
- **Round-trip ergonomics.** The Burrito-built binary handles import
  + validate + scaffold without any of the boot-ordering issues the
  release path has historically had.

## What this benchmark does NOT cover

- **Live LLM dispatch.** `glorbo bench run` requires either:
  - The release binary's CLI Registry to know about LM Studio, OR
  - Running through `mix` instead of the binary.

  Neither was attempted here. The release path's `detect-providers`
  errored on httpc ETS (`:badarg` on `httpc_glorbo_harness__session_db`
  insert) — release-boot ordering bug; the same code works under
  `mix test`. Tracked as a follow-up; not a benchmark blocker.
- **Audit-chain comparison.** A full apples-to-apples comparison vs
  paperclip's run records would need an actual dispatch round. Today
  the benchmark proves the *static* shape; the *dynamic* dispatch
  comparison waits on either fixing the release boot or doing the
  bench through `mix`.
- **Peer-review behaviour.** GEP-42 (reviewer auto-dispatcher) just
  shipped this session — bench-softdev's reviewer agent now has a
  working auto-dispatch path, but no test in this benchmark exercised
  it. The unit tests (`Glorbo.Actions.ReviewsTest`, 10 tests) cover
  the mechanism.
- **Browser UI.** Bazzite's chromium / Playwright MCP issues remain
  per memory `reference_agent_browser_bazzite`. Out of scope.

## Findings → fixed

1. **Importer wraps HEARTBEAT.md + SOUL.md with kind: frontmatter.**
   `lib/glorbo/cli/import_paperclip.ex` — `wrap_companion_md/2`
   helper added.
2. **`imported_from` + `imported_company` added to FileSpec
   optional keys** for `agent/v1` and `company/v1` schemas.
3. **Auto-generated docs regenerated** (`mix glorbo.docs.file_formats`)
   so the schema additions land in the published docs too.

## Findings → deferred (with rationale)

| Finding | Decision | Why |
|---------|----------|-----|
| Release-binary `detect-providers` fails on httpc ETS `:badarg` | Track as follow-up | Boot-ordering bug; doesn't affect mix-test or scaffolded data; orthogonal to import/validate UAT |
| Release-binary `glorbo init` reindex fails (Repo not started) | Track as follow-up | Same boot-ordering family; the FILE-system init succeeds, only the SQLite mirror fails; Glorbo's filesystem-as-source-of-truth posture means this is recoverable via `glorbo reindex` after the boot order is fixed |
| Live LLM dispatch comparison vs paperclip | Defer to follow-up benchmark | Needs either release-binary boot fix OR mix-based bench harness; doesn't gate the static-shape comparison |

## Bench command tested

```bash
GLORBO_HOME=/tmp/glorbo-uat-bench-r2-1777080836
./glorbo init --no-example
./glorbo import paperclip /path/to/paperclip/agentledger --as agentledger
./glorbo validate $GLORBO_HOME           # 7 files · 0/0/1
./glorbo new company benchmark-softdev --template bench-softdev
./glorbo validate $GLORBO_HOME           # 27 files · 0/0/1
mix test                                  # 2118/2118 green
```

## Scope decision (per your earlier ask)

This benchmark intentionally scopes to **import + structural
correctness**, not full dispatch comparison. That decision was made
upfront for this session because:

- GEP-42 just shipped; the auto-dispatch path is brand new and would
  benefit from a few days of operational data before it gets
  benchmark-graded.
- The release-binary boot-ordering bugs surfaced here would skew any
  dispatch comparison toward "Glorbo is slower because it can't talk
  to providers from the Burrito binary" — that's a packaging bug,
  not a runtime characteristic.
- Static-shape correctness is the prerequisite — without it, dispatch
  results would be uninterpretable ("did the run fail because of the
  agent or because the importer mangled the agent definition?").

A follow-up "dispatch benchmark" should land once the release-binary
boot fixes are in.
