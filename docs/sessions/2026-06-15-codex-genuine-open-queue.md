# Session 2026-06-15 — codex genuine-open queue

## Task: L3 provider registry permissions (§B verified medium)

**Task picked:** Work genuine-open queue — first theme L3 (world-readable
`providers.toml` on Enable).

**Mode:** Bugfix (re-verify before fix).

**What shipped:** L3 fix — `Enable.append_entry/2` chmods config dir `0700` +
`providers.toml` `0600` after write; regression test + CHANGELOG entry.
PR #77 opened.

**Gates:** precommit + credo --strict + sobelow — all pass on branch.

**Commit(s):** `c8f3f17b` on `fix/codex-l3-provider-registry-perms` → PR #77

---

## Task: L57 director slug + L118 restore staging perms

**Task picked:** Second permissions/slug theme from TRIAGE §B.

**What shipped:** Reserve `director` in scaffold + MCP create_agent; restore
staging `chmod 0700`; tests + CHANGELOG.

**Gates:** _(pending precommit on this branch)_

**Commit(s):** _(pending)_

---

## Blockers / operator decisions

_(none logged)_

## Things I'd like your review

- Merge order: #77 then #78 (L57+L118) then release.yml PR when ready.
