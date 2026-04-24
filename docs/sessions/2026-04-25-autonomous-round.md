# 2026-04-25 — autonomous session log

Round picked up post-v0.8.0. Autonomy level: **L3** (L2 + status
promotions when settled; no push). Two tasks landed: GEP-23
`kbps_cap` formal won't-fix, and the long-deferred FileSpec.Formatter
`|` block-scalar preservation.

---

## Task 1 — GEP-23 `egress.kbps_cap`: won't-fix

**Task picked.** P3 todo entry queued the per-dispatch
token-bucket throttle as a follow-up to v0.7.0's Phase 5
Proxy-Authorization tokens. Began implementation (parser +
ProxyTokens entry extension started); maintainer interrupted
mid-flight with "I really don't need kbps limiting proxy..." —
wholesale decline.

**What shipped.** Reverted three half-edited files
(`lib/glorbo/agent/parser.ex`, `lib/glorbo/agent/spec.ex`,
`lib/glorbo/network/proxy_tokens.ex`) to clean main; recorded the
won't-fix decision in two places:

  * `docs/todo.md` line 288 flipped to `[x]` with a 2026-04-25
    won't-fix note citing the maintainer's reasoning (kbps shaping
    is overkill for single-user / single-host posture; allowlist +
    audit log already cover the failure surface).
  * `docs/geps/0023-egress-proxy-with-filtering.md` history gained
    a 2026-04-25 entry (status stays Implemented) explaining the
    spec line stays in §Proxy daemon §7 as a documented opt-out
    but no implementation path is planned.

**Design calls I made without you.**

  * **Don't delete the spec line in §Proxy daemon §7.** Leaving
    `kbps_cap: 512` in the example block is fine — it documents
    the field shape future readers might encounter in legacy
    AGENT.md files. Only the implementation is shelved; the
    schema fragment stays as an interpretable opt-out should the
    decision flip later.

**Gates.** Tree clean before next task; nothing to gate beyond
the doc edits.

**Skipped / not done.** No code changes. The half-edited parser/
spec/proxy_tokens patches are reverted, not stashed — no resurrection
path needed.

**Commit.** Bundled with task 2 below.

---

## Task 2 — FileSpec.Formatter `|` block-scalar preservation

**Task picked.** P3 todo entry from GEP-40's wake — multi-line
`done_when:` (and `handoff_chain[].reason`) round-tripped through
the formatter as `"line1\nline2"` (literal `\n` in a double-quoted
scalar), valid YAML but hostile to read. Bounded, single-module
scope; fits L3 cleanly.

**What shipped.** `lib/glorbo/file_spec/formatter.ex`:

  * `block_scalar?/1` predicate: any binary whose `String.trim_
    trailing("\n")` still contains `\n` qualifies.
  * `emit_block_scalar_body/2`: returns iodata of indented lines
    joined by `\n` *without* trailing newline — caller controls
    terminator. Handles blank lines as bare `""`. Strips all
    trailing `\n` chars first since `|` (clip) chomping always
    re-adds exactly one.
  * `emit_key_value/3` for binaries: branches on `block_scalar?`,
    emits `key: |\n<indented lines>\n` for multi-line, plain
    `key: value\n` otherwise.
  * `emit_list_item_pair/4`: new helper extracted from the inline
    closure inside `emit_list_item/2` for map items. Handles
    `key: |\n<indented lines>` for multi-line nested values
    (handoff_chain reasons, future paragraph fields in
    list-of-maps).
  * `emit_list_item/2` rewritten to call the new helper; first +
    rest pairs share the same emission path; rest pairs prefix
    `\n + pad`; outer `emit_key_value` adds the trailing `\n` per
    list item.

5 new tests in `test/glorbo/file_spec/formatter_test.exs`:

  * top-level multi-line emits as `|` block scalar
  * single-line strings still emit as plain scalars (refute `|`)
  * blank lines mid-paragraph survive the round-trip + idempotent
  * round-trip idempotence on a 3-line `done_when`
  * multi-line nested in `handoff_chain[].reason` uses block scalar
    and is idempotent

**Design calls I made without you.**

  * **Single trailing newline is the canonical form.** YAML `|`
    (clip) chomping produces exactly one trailing `\n`; the
    formatter strips all trailing `\n` from input first and lets
    the YAML reader re-add one on round-trip. Means a string
    written by the agent without a trailing newline will gain
    one after the first format pass — `:changed`. Second pass is
    `:unchanged`. This matches the existing trailing-newline
    normalisation for the body section.
  * **Nested-in-list-of-maps gets the same treatment.** The
    reported bug only mentioned `done_when` (top-level), but
    `handoff_chain[].reason` has the same shape and the same
    visual ugliness. Bundling both is one continuous patch
    instead of two.
  * **`kind` parameter on `emit_list_item_pair` is unused today.**
    Kept it in the signature anticipating future divergence
    (e.g. inline-flow style for the first pair); deletable if it
    stays dead. One short comment notes the dead parameter.
  * **No new public API.** Block-scalar emission is purely
    internal to the formatter; `format_content/2` callers see no
    behaviour change beyond the emitted bytes.

**Gates.**

  * `mix test` — 2080/2080 green, 1 skipped (42 excluded as
    integration). 0 failures.
  * `mix precommit` — full pipeline ran; tests + format + credo
    + docs check all green.
  * `mix credo --strict` — 449 source files, 5021 mods/funs, 0
    issues; exit 0.
  * `mix format --check-formatted` — clean; exit 0.
  * `mix glorbo.docs.file_formats --check` — clean (25 files).
  * Pre-existing 16-failure integration suite (LM Studio live,
    EPMD up-down, Burrito binary path) confirmed unchanged on
    clean main; not regressed by this work.

**Skipped / not done.**

  * **Block-scalar style picker.** Only `|` (literal) emitted; no
    automatic switch to `>` (folded) for prose-style paragraphs
    where line wrapping doesn't matter. Folded scalars are valid
    but their reader-side handling is more surprising — `|` is
    the safer default for everything Glorbo writes. Revisit only
    if a future field truly needs paragraph-style folding.
  * **Block-scalar in nested *map* values** (not list-of-maps).
    `emit_key_value` for nested maps recurses into
    `emit_key_value(to_string(mk), mv, indent + 2)`, which
    already handles binaries via the new branch. So in theory
    nested-map multi-line values work; not regression-tested
    because Glorbo's frontmatter doesn't yet have any (`goals:`,
    `budget:`, etc. all use scalar leaves). Test that path if a
    future schema adds one.

**Commit.** One commit covering both tasks (kbps_cap won't-fix
docs + formatter feature + tests).

---

## Things I'd like your review

1. **GEP-23 `kbps_cap` recorded as won't-fix permanently.** I
   went with "stays in §Proxy daemon §7 as documented opt-out"
   instead of redacting the spec. If you'd rather strike the
   field from the spec entirely, say so — it's a one-edit
   follow-up. Today's stance: the schema fragment is harmless
   documentation, the implementation isn't planned.

2. **Formatter trailing-newline normalisation.** A
   `"line1\nline2"` (no trailing `\n`) input writes back as
   `"line1\nline2\n"` after the first format pass. That's a
   one-time `:changed` for any pre-existing file with no
   trailing newline in a multi-line field, then forever
   `:unchanged`. Acceptable, but worth flagging in case any tool
   downstream depends on the no-trailing-`\n` form.

3. **Dead `kind` parameter in `emit_list_item_pair`.** Kept it
   as future-proofing. Happy to drop if you'd rather keep the
   surface tight.
