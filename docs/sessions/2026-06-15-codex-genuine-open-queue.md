# Session 2026-06-15 — codex genuine-open queue

## Task: L3 provider registry permissions (§B verified medium)

**Task picked:** Work genuine-open queue — first theme L3 (world-readable
`providers.toml` on Enable).

**Mode:** Bugfix (re-verify before fix).

**What shipped:** L3 fix — `Enable.append_entry/2` chmods config dir `0700` +
`providers.toml` `0600`; regression test; GEP-32 history + notes.md.
PR #77 (rebased after #78/#79 landed out of order).

**Gates:** precommit + credo --strict + sobelow — green.

**Commit(s):** `c8f3f17b` → PR #77

---

## Task: L57 director slug + L118 restore staging perms

**What shipped:** Merged via PR #78 (`513cf0bd` on main).

---

## Task: release.yml tap hardening

**What shipped:** Merged via PR #79 (`afde3a47` on main). CHANGELOG entry for
tap retry still missing on main — follow-up if desired.

---

## Blockers / operator decisions

- **PR #77** — was CONFLICTING after #78/#79 merged first; rebased locally.
  Auto-merge enabled; needs green CI re-run + approval if ruleset requires it.

## Things I'd like your review

- Merge #77 when CI green (L3 is the only codex fix not yet on main).
- Optional: add Homebrew tap retry CHANGELOG bullet (missed in #79 squash).
