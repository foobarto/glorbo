# Phase 1: Compilable Skeleton + CI Release Pipeline - Context

**Gathered:** 2026-04-15
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver a fresh-checkout-to-signed-binary pipeline: Phoenix/OTP skeleton with SQLite WAL, domain-nested module layout from `DESIGN.md` §4.1, the `mix glorbo.doctor` CLI task, and GitHub Actions CI that produces signed x86_64 + aarch64 single-binary artifacts runnable on hosts with no Erlang installed.

Runtime functionality (filesystem layout, Podman bootstrap, Ollama, agents, permissions, LiveView dashboard) is **out of scope** for this phase — module stubs only. This phase proves the build contract, not the runtime contract.

</domain>

<decisions>
## Implementation Decisions

### Project generation
- **D-01:** Initialize with `mix phx.new . --app glorbo --database sqlite3 --no-mailer --no-gettext`
- **D-02:** Keep Phoenix LiveView dependencies (needed in Phase 4); strip only the generated example routes, `/dev` dashboards, and page controller boilerplate
- **D-03:** Reshape the generated layout into the domain-nested structure in `DESIGN.md` §4.1 (`lib/glorbo/{company,agent,router,...}`, `lib/glorbo_web/`) before any other work

### Database
- **D-04:** SQLite via `ecto_sqlite3`, WAL journal mode enabled in `config/dev.exs`, `config/test.exs`, and `config/runtime.exs` (verified by grep-level checks)
- **D-05:** No migrations or schemas in this phase beyond what Phoenix generates — real schemas land with their owning phase

### Module stubs
- **D-06:** Create stubs for every top-level domain module listed in `DESIGN.md` §4.1 (supervisors, servers, router, file watcher, audit log, budget tracker). Functions return `{:error, :not_implemented}` or equivalent placeholders
- **D-07:** Wire all stubs into `Glorbo.Application`'s supervision tree — the tree must *start* cleanly, even though every branch is a stub. This locks the OTP shape early (crash-isolation invariant from `CLAUDE.md`)

### Single-binary release
- **D-08:** Use [Burrito](https://github.com/burrito-elixir/burrito) to wrap `mix release` (ERTS bundled via `include_erts: true`) into a true single-file executable
- **D-09:** Output binary names match `DESIGN.md` §10 curl URL: `glorbo-linux-x86_64` and `glorbo-linux-aarch64`
- **D-10:** Burrito targets configured for both x86_64-linux-gnu and aarch64-linux-gnu; NIF dependencies (exqlite/ecto_sqlite3) built natively on each target runner, not cross-compiled

### CI pipeline
- **D-11:** GitHub Actions as CI provider (matches `DESIGN.md` §10's GitHub Releases distribution)
- **D-12:** Two runners per build job: `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm` (native aarch64 — GA since 2025-01, free for public repos, no QEMU)
- **D-13:** Trigger matrix:
  - **Pull requests:** compile + test on both archs
  - **Push to `main`:** compile + test + upload development artifacts (not published to Releases)
  - **Tags `v*.*.*`:** compile + test + signed, versioned release published via GitHub Releases
- **D-14:** Cache `deps/` and `_build/` per-arch keyed on `mix.lock`

### Release signing & integrity
- **D-15:** Cosign **keyless** signing via Sigstore using the GitHub OIDC token (no long-lived keys to manage; verifiable provenance tied to the workflow run)
- **D-16:** Publish `SHA256SUMS` and `SHA256SUMS.sig` alongside every release; end users verify with `cosign verify-blob`
- **D-17:** Dev builds from `main` are **not** signed — signing only on tagged releases

### `mix glorbo.doctor` CLI
- **D-18:** Implemented as a `Mix.Task` at `lib/mix/tasks/glorbo.doctor.ex`
- **D-19:** Checks: Linux kernel version, `uidmap` package present, disk space ≥ 1 GB free in `$HOME`, write permission on `~/.glorbo/` (creates if missing), ERTS version sanity check
- **D-20:** Output modes:
  - Default: human-friendly table with ✓/✗ + terminal colors (auto-disable on non-TTY)
  - `--json`: machine-readable JSON, stable keys for scripting
  - Exit code `0` only when every check passes; `1` on any failure
- **D-21:** Doctor runs are non-destructive — it *detects* and *creates `~/.glorbo/`* but never installs system packages (that's `glorbo init` in Phase 2)

### Test stack
- **D-22:** ExUnit + Credo (strict mode) only in Phase 1 — cheap to add, catches style drift early
- **D-23:** Dialyzer, StreamData, and Mox deferred until Phase 3 when real logic exists to test
- **D-24:** CI fails on: compile warnings (`--warnings-as-errors`), test failures, Credo strict violations

### Claude's Discretion
- Exact layout/styling of the doctor table output
- Module docstring conventions (aim for useful, not comprehensive — this is a skeleton)
- `mix.exs` application metadata (version starting at `0.1.0`, SPDX license from `README.md`)
- Credo config tuning (start with strict defaults; loosen only on justified friction)
- GitHub Actions YAML file structure (one workflow vs split PR/release workflows — optimize for readability)
- Elixir and OTP version (pick current stable at planning time; lock via `.tool-versions`)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture (authoritative)
- `DESIGN.md` §4.1 — Domain-nested module layout (`lib/glorbo/{company,agent,router,channel,audit,budget,file_watcher,...}`, `lib/glorbo_web/`)
- `DESIGN.md` §7 (Tech stack table, line 197–199) — `ecto_sqlite3`, Podman CLI system calls, `mix release` with `include_erts: true`
- `DESIGN.md` §7 — Supervision tree sketch (all stubs in Phase 1 must fit this shape)
- `DESIGN.md` §10 — CLI surface including `glorbo doctor`; release URL pattern `github.com/glorbo/glorbo/releases/latest/download/glorbo-linux-{arch}` that determines binary naming

### Project-level constraints
- `CLAUDE.md` — Load-bearing invariants: kernel-is-policy-engine, filesystem-as-source-of-truth, one-way inbox/outbox, append-only audit, Python-never-on-host, company isolation, OTP crash isolation
- `.planning/PROJECT.md` — Core value, Key Decisions table (esp. "Full DESIGN.md scope for v1", "Elixir/OTP on host, Python only in containers")
- `.planning/REQUIREMENTS.md` — FND-01 through FND-06 (the six Phase 1 requirements this phase must satisfy)
- `.planning/ROADMAP.md` Phase 1 success criteria — five concrete must-pass checks

### External specs to investigate during research
- Burrito project: https://github.com/burrito-elixir/burrito (single-file Elixir binaries, NIF handling, target configuration)
- Sigstore cosign docs: https://docs.sigstore.dev/cosign/signing/overview/ (keyless signing with GitHub OIDC)
- GitHub Actions aarch64 runner announcement & usage (`ubuntu-24.04-arm` image)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
None — this is a greenfield skeleton. No prior Elixir code exists.

### Established Patterns
- `DESIGN.md` is the only prior-art pattern source; it dictates module names, supervision tree shape, and CLI verbs.
- Marketing page at `assets/index.html` is unrelated to the Phoenix app that will live here.

### Integration Points
- **Phase 2 handoff:** `mix glorbo.doctor` must be callable from Phase 2's `glorbo init` flow; the Mix task should be invocable programmatically (not just from the CLI) so `init` can chain to it.
- **Phase 2 handoff:** Module stubs for `Glorbo.FileSystem.*`, `Glorbo.ContainerManager`, `Glorbo.AuditLog` need public function signatures stable enough for Phase 2 to fill in without renaming.
- **Phase 4 handoff:** `lib/glorbo_web/` must exist as the Phoenix endpoint root so LiveView routes can be added later without restructuring.

</code_context>

<specifics>
## Specific Ideas

- `mix release` alone produces a tarball, not a single file — Burrito is the chosen wrapper because it matches the UX promised in `DESIGN.md` §10: `curl -L github.com/.../glorbo-linux-x86_64 | ... && chmod +x && ./glorbo init`.
- GitHub hosted `ubuntu-24.04-arm` runners are preferred over QEMU emulation because NIFs (specifically exqlite for ecto_sqlite3) compile natively — emulation has caused silent corruption and extreme build-time penalties for Elixir projects in practice.
- Cosign keyless signing is preferred over GPG because it ties the signature to the GitHub Actions run ID (verifiable via `cosign verify-blob --certificate-identity-regexp`), so anyone can prove a binary came from this repo's CI without trusting a maintainer keyring.
- Doctor's `--json` flag is required because Phase 2's `glorbo init` will call `doctor` programmatically and parse its result to decide next steps (e.g., "podman missing → auto-download").

</specifics>

<deferred>
## Deferred Ideas

- **Dialyzer integration:** Phase 3 (when real business logic and typespecs exist to check).
- **Property-based testing (StreamData):** Phase 3+ (router permission logic is a natural fit).
- **Mox-based mocking:** Phase 3 (agent runtime stubs out Podman calls in tests).
- **SBOM generation (CycloneDX / SPDX):** post-v1 (nice-to-have for supply-chain transparency; not blocking release).
- **Signed source-archive provenance:** post-v1.
- **Homebrew / Nix flake packaging:** out of scope — v1 ships a single binary, packaging is user-territory per `DESIGN.md`.
- **Release notes automation (changelog from PR labels):** post-v1 ergonomic improvement.

</deferred>

---

*Phase: 01-compilable-skeleton-ci-release-pipeline*
*Context gathered: 2026-04-15*
