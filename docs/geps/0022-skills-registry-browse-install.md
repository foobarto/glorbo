---
gep: 22
title: skills.sh Registry — Browse and Install Skills
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-04-21
requires: [2, 3, 5]
see-also: [15, 21]
history:
  - date: 2026-04-21
    status: Draft
    note: Initial draft — first external HTTP dependency; establishes cert-pinning + sha256 + fail-safe patterns for future external integrations.
---

# GEP-22: skills.sh Registry — Browse and Install Skills

## Problem

SkillsLive (shipped pre-GEP-21) is read-only: it shows builtins from
`priv/templates/skills/` plus user overrides under `<base>/skills/`.
Directors who want a new skill must leave the app, find the skill on
skills.sh, copy the markdown, paste it into a file. The workflow is
hostile enough that custom skills are rare — most agents rely on the
handful of builtins.

This GEP introduces the first outbound HTTP dependency in Glorbo.
That's architecturally significant: we've been offline-by-default
since day one. The design has to earn the trust this breaks.

## Goals

- Director can browse skills.sh from within SkillsLive.
- One-click install writes to `<base>/skills/<slug>.md`.
- Every byte that lands on disk is sha256-verified against what the
  registry advertised.
- TLS pinned; no downgrade path.
- Rate-limited outbound (we don't DDoS skills.sh from a button).
- Auditable — every install + every failed install is an audit event.
- Fail-safe — any error at any stage leaves the filesystem unchanged.

## Non-goals

- **No updates in v1.** An installed skill is frozen; a new version
  requires explicit re-install (director deletes local file, then
  clicks install again).
- **No skills.sh authentication.** The registry is public.
- **No custom registries.** skills.sh is the only supported origin.
  ClawdHub and others are follow-ups.
- **No bidirectional sync** (DB row for each installed skill).
  `<base>/skills/<slug>.md` is the source of truth (GEP-3); no
  derivation needed.
- **No upload.** Directors contribute back to skills.sh by their own
  mechanism (web form, PR — whatever skills.sh offers).
- **No per-agent install UI.** Skills are company-wide; agents opt in
  via AGENT.md `skills:` frontmatter (GEP-10). Install + opt-in are
  two separate director actions.

## Design

### Module layout

| Module | Role |
|--------|------|
| `Glorbo.Skills.Registry` | HTTP client against skills.sh. `list/1`, `fetch/1`. |
| `Glorbo.Skills.Installer` | Sha256 verify + write to disk atomically. `install/2`. |
| `Glorbo.Skills.RateLimiter` | GenServer token bucket for outbound requests. |
| `GlorboWeb.SkillsLive` | Extended: "Browse registry" tab. |

### HTTP dependency

- **Client**: `Req` (already in deps via Phoenix) with:
  - `decode_body: :json` for `/api/v1/skills` endpoints.
  - `receive_timeout: 10_000`, `connect_options: [timeout: 5_000]`.
  - `max_redirects: 0` — skills.sh published endpoints should be
    direct; a redirect is a red flag we treat as failure.
- **TLS pinning**: `:ssl` options restrict `cacerts:` to the
  system trust store **plus** a pinned SPKI fingerprint of
  skills.sh's cert. Configured via `config :glorbo,
  :skills_sh, spki_sha256: "..."`. On mismatch, request fails with
  `{:error, :spki_mismatch}`.
  - Initial SPKI recorded at GEP acceptance time; rotation requires a
    new GEP or amendment. The value is not agent-facing; changing it
    is a config change, not a data change.
- **URL template**: `https://skills.sh/api/v1/skills?q=<q>&limit=<n>`
  for listing; `https://skills.sh/raw/<slug>` for content.

### Registry API shape (agreed with skills.sh)

`GET /api/v1/skills?q=elixir&limit=20` →

```json
{
  "skills": [
    {
      "slug": "elixir-refactor",
      "title": "Elixir refactoring helper",
      "description": "Mechanical refactors for Elixir 1.18",
      "author": "@kafit",
      "size_bytes": 3421,
      "sha256": "abc123...",
      "updated_at": "2026-04-18T09:23:01Z"
    }
  ],
  "next_page": null
}
```

`GET /raw/elixir-refactor` → the markdown body (content-type:
`text/markdown`).

Missing fields on any skill in the list response → that entry is
dropped client-side, not the whole list.

### Install flow

```
director clicks "install"
         ↓
Glorbo.Skills.RateLimiter.take/0 — block if bucket empty
         ↓
Glorbo.Skills.Registry.fetch/1 → {:ok, %{body, advertised_sha, slug}}
         ↓
sha256(body) == advertised_sha?    (else reject, audit)
         ↓
body size <= @max_skill_bytes ?    (else reject)
         ↓
parse markdown with Frontmatter.parse/1: has `name:`? size < 10 MB?
         ↓
conflict check: <base>/skills/<slug>.md exists?
  - absent → install
  - present + overwrite: true → install (shadows existing)
  - present + overwrite: false → reject with :conflict
         ↓
atomic write (tmp + rename) to <base>/skills/<slug>.md
         ↓
emit `skill.install` audit event
```

### Validation constants

- **`@max_skill_bytes`**: 100 KB. Matches the 10 MB outer `Frontmatter.parse/1`
  cap with two orders of magnitude of headroom — a skill larger than
  100 KB is either malformed or trying to smuggle data.
- **Skill slug regex**: reuse `@skill_name_regex` from
  `Glorbo.Agent.Parser` (`[a-z][a-z0-9_-]{0,63}`). Reject slugs that
  don't fit before writing.
- **Frontmatter requirement**: parsed markdown must have frontmatter
  with at least a `name:` field. Empty / missing frontmatter rejected.

### Rate limiting

- **Bucket**: 1 token/sec, capacity 10. Covers burst of 10 fetches
  (typical "look at 10 results, install 1-2") without annoying the
  registry.
- **Implementation**: `Glorbo.Skills.RateLimiter` as a GenServer with
  monotonic refill on every `take/0` call (no background timer).
- **Failure**: `take/0` returns `{:error, :rate_limited}` if bucket
  is empty; SkillsLive flashes "Slow down — try again in a moment"
  and doesn't queue.

### SkillsLive UI

New "Browse registry" tab next to the existing listing. Renders:

```
[Search: ______________]       (debounced 250ms → Registry.list/1)

<results>
  elixir-refactor · @kafit · 3.4 KB       [install] [overwrite]
  elixir-format   · @ana   · 1.2 KB       [install]
  ...
</results>
```

- Debounced search input triggers `handle_event("skills_search", …)`.
- `handle_event("install_skill", %{"slug" => s}, socket)` runs the
  install flow. Flashes "Installed <slug>" or an error.
- `handle_event("install_overwrite", %{"slug" => s}, socket)` same
  but passes `overwrite: true`. Button only shows when conflict
  detected.
- Tab falls back to a "registry unavailable" empty state on any
  network error, with a retry button. No crash.

### Audit events

- `skill.install` — `%{slug, source: "skills.sh", sha256, size_bytes,
  overwrote: boolean}`
- `skill.install_failed` — `%{slug, reason: :sha_mismatch | :size |
  :rate_limited | :http_error | :conflict | ...}`

`AuditEntry.action_phrase/4` gains renderers:
- `skill.install` → "installed skill `<slug>`"
- `skill.install_failed` → "failed to install `<slug>` (`<reason>`)"

### Where the code lives

```
lib/glorbo/skills/
├── registry.ex       # HTTP client, TLS pinning, JSON parse
├── installer.ex      # sha verify + atomic write
├── rate_limiter.ex   # GenServer token bucket
```

`SkillsLive` grows a tab + two handle_events; no changes to
`Glorbo.Skills.Resolver` (the existing skill materializer —
installed skills flow through it identically to user-authored ones).

## Migration / rollout

- Zero breakage: SkillsLive's existing listing is unchanged; the
  new tab is additive.
- Config requirement: `config :glorbo, :skills_sh, spki_sha256: "..."`
  must be set for the feature to activate. Missing config → "Browse
  registry" tab renders a "feature disabled" notice + link to docs.
- Feature flag: `config :glorbo, :skills_registry_enabled, true` —
  defaults true once the SPKI is set; directors can disable the
  outbound path entirely.
- Packaging: skills.sh SPKI value lands in the Glorbo repo at GEP
  acceptance. Rotation requires:
  1. skills.sh rotates cert.
  2. Glorbo ships a new release with the new SPKI.
  3. Old releases `skill.install_failed`s until upgrade.
  This is intended — cert rotation should be a visible, auditable
  event, not a silent trust change.

## Failure modes

| Failure | Surface |
|---------|---------|
| skills.sh DNS / network unreachable | empty results + "registry unavailable" banner; no audit (noise) |
| skills.sh 5xx | same; timed retry on user action |
| SPKI mismatch | `skill.install_failed` audit with `:spki_mismatch`; loud flash for director |
| sha256 mismatch | `skill.install_failed` audit with `:sha_mismatch`; **never** write to disk |
| Body > 100 KB | `skill.install_failed` with `:size`; skill advertised size compared first, then actual |
| Bad frontmatter | `skill.install_failed` with `:invalid_frontmatter` |
| Slug regex mismatch | `skill.install_failed` with `:invalid_slug`; includes the advertised slug for forensics |
| Write fails (disk full) | `skill.install_failed` with `:write_failed`; tmp file cleaned up |
| Conflict without overwrite | "Skill exists — use overwrite to shadow" flash; no audit (not an error, a user choice) |
| Rate-limit hit | "Slow down" flash; no audit |

Every failure leaves the filesystem unchanged. The `tmp + rename`
pattern from `TaskDefinition.write/2` is reused verbatim.

## Test strategy

- **Unit** (`Glorbo.Skills.RateLimiter`): bucket depletion + refill.
- **Unit** (`Glorbo.Skills.Installer`): sha verify, size check,
  frontmatter validation, atomic write, conflict handling.
- **Mock** (`Glorbo.Skills.Registry`): `:req_test` (Req's built-in
  mock adapter) to simulate list/fetch responses without real HTTP.
  Covers TLS plumbing configuration path without cert chain testing
  (that's TLS's job, not ours).
- **Integration** (`GlorboWeb.SkillsLive`): browse tab renders mock
  results, install → file lands at expected path, audit emitted.
- **Property** (size + sha combos): round-trip random bytes through
  Registry.fetch-mock → Installer.install, assert either the file
  contents match or an error is surfaced. Never a silent success
  with wrong bytes.

No real skills.sh hits in CI. A separate `@tag :live_network` set of
smoke tests can probe the real endpoint from developer machines; not
part of CI.

## Open questions

- **Install history**: do we track "which skills this company has
  installed + when + who installed them"? Audit events capture this
  but there's no UI. Deferred — if a director needs the list, the
  current file listing answers it; a dedicated view is a follow-up.
- **Version pinning**: if skills.sh later ships a `version:` field,
  what do we do with it? Deferred — not in current skills.sh schema.
- **Signature verification beyond sha**: the skill body itself is not
  signed, only sha'd. If skills.sh starts signing contents (e.g.
  Sigstore), we should verify. Deferred until upstream ships it.
- **Offline cache**: should we cache fetched-but-not-installed skill
  metadata locally so Browse works without network (stale but
  better than empty)? Deferred — network failure is rare enough
  that the director can retry.

## Decision log

### D1. HTTP CONNECT via Req (not raw `:httpc`)

- **Decided:** use `Req` for all outbound HTTP.
- **Alternatives:** Erlang's `:httpc`, `Mint` directly, `Tesla`.
- **Why:** Req is already a transitive dep via Phoenix; it's the
  idiomatic HTTP client in modern Elixir apps; it handles JSON
  decoding, redirects, retries uniformly. `:httpc` is low-level and
  has known TLS default issues on older OTPs. `Mint` is a primitive
  we'd wrap anyway. `Tesla` is adapter-heavy and slower to set up.

### D2. SPKI pinning, not full-cert pinning

- **Decided:** pin the subject public key info sha256, not the whole
  certificate.
- **Alternatives:** pin the leaf cert; pin the CA; trust on first
  use (TOFU).
- **Why:** SPKI pinning survives cert rotation that keeps the same
  key (RFC 7469 approach). Full-cert pinning forces a Glorbo release
  on every skills.sh cert renewal, which is an ops burden we don't
  want to inflict on downstream users. CA pinning is too loose — any
  certificate the CA issues passes. TOFU is insufficient for an
  install path.

### D3. sha256 + size verification, no code signing

- **Decided:** verify the advertised sha256 matches the downloaded
  bytes before writing; enforce 100 KB size cap.
- **Alternatives:** trust the server; Ed25519-signed manifests;
  full code signing (Sigstore).
- **Why:** sha256 catches MITM or corrupt download; pairs with
  SPKI-pinned TLS for end-to-end integrity. Code signing is a much
  bigger commitment (key management, revocation, signing infra on
  skills.sh) and not yet offered upstream. We adopt it if and when
  skills.sh ships it.

### D4. No updates in v1

- **Decided:** installed skills are frozen; updates require explicit
  delete + reinstall.
- **Alternatives:** auto-update on a schedule; update-on-demand button.
- **Why:** skills read by agents shape agent behaviour; silent
  updates would mean agents behave differently across dispatches for
  reasons the director can't audit. Explicit delete + reinstall is a
  visible director action with an audit trail. Keeps scope tight.

### D5. Rate limit at 1/sec with burst 10

- **Decided:** `RateLimiter` GenServer, 1 token/sec refill, 10
  capacity.
- **Alternatives:** no rate limit; per-minute cap; distributed rate
  limit (across restarts).
- **Why:** single-director tool — one person won't realistically
  exceed 10 clicks in a second. The purpose is to prevent runaway
  behaviour (rapid-fire palette install events, or a misconfigured
  heartbeat) from hitting skills.sh. Crash-on-restart cap reset is
  fine; directors don't install across process restarts frequently
  enough for it to matter.

### D6. Conflict = explicit overwrite, not silent replace

- **Decided:** install fails with `:conflict` when `<base>/skills/<slug>.md`
  already exists; director must click an overwrite button.
- **Alternatives:** silent replace (last-write-wins); version-suffix
  the new install (`elixir-refactor.2.md`).
- **Why:** director-authored custom skills matter more than registry
  downloads — silently replacing them would destroy work. A version
  suffix creates ambiguity about which file an agent reads. Two-step
  install (install → conflict → overwrite) preserves director intent.

### D7. Feature flag gated on SPKI config

- **Decided:** the feature is disabled if `:skills_sh, :spki_sha256`
  is missing or empty.
- **Alternatives:** always on with a default SPKI baked into the
  release; always on with TOFU.
- **Why:** a release without an explicit SPKI pin means the
  outbound path is unsafe by default. Making it opt-in via config
  ensures deployment operators have seen the security discussion;
  the baked-in default is embedded in the release artifact, not in
  a runtime-editable file, so operators must consciously accept it.

## Related

- GEP-2 — Architecture (Glorbo is offline-by-default; this is the
  first exception).
- GEP-3 — Filesystem as source of truth; installed skills live at
  `<base>/skills/<slug>.md` the same as user-authored ones.
- GEP-5 — Sandboxing; bwrap doesn't mount `<base>/skills/` writable
  to agents; the install path is application-level only.
- GEP-15 — ALLCAPS convention; skills files are lowercase-kebab
  because they're user-editable catalog entries, not agent contract.
- GEP-21 — File-based agent memory; similar one-way-write pattern at
  a different layer.
