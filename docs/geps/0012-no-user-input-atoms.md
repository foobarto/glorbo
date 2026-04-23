---
gep: 12
title: No User-Input Atoms — Registry Over Process Names
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-17
requires: [2]
see-also: [5]
history:
  - date: 2026-04-17
    status: Draft
    note: Initial draft — promotes an existing informal rule (T-03-15) to an enforced standard after an audit surfaced one violation in Company.Supervisor.
  - date: 2026-04-23
    status: Implemented
    note: "Fully landed on `main`: `Company.Supervisor.via/2` is the canonical `{:via, Registry, {Glorbo.Agent.Registry, {:company_child, company, role}}}` registration (lib/glorbo/company/supervisor.ex:86); `Credo.Check.Warning.UnsafeToAtom` is enabled in `.credo.exs:162` so `mix credo --strict` blocks regressions; and every per-company child (audit_log, file_watcher, router, scheduler, task_scheduler, budget_tracker, agent_sup, network_proxy, approvals_gate, path_request_gate, proposals_sink) routes through `via/2`."
---

# GEP-12: No User-Input Atoms — Registry Over Process Names

## Problem

The BEAM's atom table is fixed-size (default 1,048,576 entries) and
atoms are never garbage-collected. Any code path that calls
`String.to_atom/1`, `:erlang.binary_to_atom/2`, `List.to_atom/1`, or
`Module.concat/2` on a value derived from user input is an
atom-exhaustion DoS vector: an attacker (or a bug) that produces enough
distinct inputs eventually crashes the node with
`system_limit :atom_limit`, and there is no recovery short of a BEAM
restart.

Glorbo already treats this as a policy. Two modules state it in their
moduledocs:

- `lib/glorbo/agent/parser.ex:13` — "Never calls `String.to_atom/1` on
  user input (T-03-15 mitigation)."
- `lib/glorbo/security/acl_mapper.ex:14` — "No `String.to_atom` or
  `String.to_existing_atom` is ever called on user input."

The agent-layer process tree follows the policy correctly:
`Agent.Registry` registers per-agent processes via
`{:via, Registry, {Glorbo.Agent.Registry, {kind, company, agent}}}`
tuples (`lib/glorbo/agent/registry.ex:33-36`,
`lib/glorbo/company/agent_supervisor.ex:48-50`,
`lib/glorbo/agent/server.ex:91`). Zero atoms are created from user
slugs on that path.

One function in the codebase violates the policy:

```elixir
# lib/glorbo/company/supervisor.ex:89
defp child_name(company, role), do: String.to_atom("#{company}_#{role}")
```

`company` is a user-controlled slug. Every unique company produces 6–7
atoms (`<co>_audit_log`, `<co>_file_watcher`, `<co>_router`,
`<co>_scheduler`, `<co>_budget_tracker`, `<co>_agent_sup`, plus the
conditional `<co>_network_proxy` and `<co>_approvals_gate`). Slug
regex (`~r/\A[a-z0-9-]+\z/` in
`lib/glorbo/cli/scaffold/company.ex:17`) caps per-request input but
doesn't cap *uniqueness across time* — renaming
`acme-q1-2026 → acme-q2-2026 → …` leaks atoms forever, and any bypass
of the scaffold path (direct `Company.Supervisor.start_link/1`,
filesystem-driven company boot) defeats the gate entirely.

Credo ships a check that would catch this —
`Credo.Check.Warning.UnsafeToAtom` — but `.credo.exs:213` has it in
the `disabled:` list with a comment that says "Controversial and
experimental checks (opt-in)." The one-line config flip turns a
tribal policy into a CI-enforced one.

Summary: Glorbo has a named T-03-15 policy, a canonical pattern that
implements it correctly (Agent.Registry), an isolated violation, and
a disabled Credo check that would catch future regressions. GEP-12
promotes the policy to a codified Standards rule, fixes the violation,
and enables the guardrail.

## Goals

- Establish **"no `String.to_atom/1` (or equivalent) on user input"**
  as a load-bearing Glorbo rule, with a stable threat code (T-03-15)
  every comment and test can reference.
- Replace `Company.Supervisor.child_name/2`'s atom construction with
  a `{:via, Registry, {Glorbo.Agent.Registry, tuple}}` registration
  pattern, matching the agent layer.
- Enable `Credo.Check.Warning.UnsafeToAtom` in `.credo.exs` so `mix
  credo --strict` (and the CI gate that runs it) blocks regressions.
- Document the canonical "how to register a per-company /
  per-agent named process" pattern in one place so future contributors
  don't re-derive it.

## Non-goals

- Not auditing atoms that come from compile-time constants, module
  attributes, or literal source code. Those don't grow at runtime and
  aren't a DoS vector.
- Not switching existing `Agent.Registry` to a different process
  registry or renaming its key shape. The current
  `{kind, company, agent}` tuple is the target pattern — other
  subsystems adopt *it*, not the other way around.
- Not adding a soft company-count cap (`max_companies: N` in
  application config). That is a separate concern and would not
  protect against the atom-leak pathway anyway once atoms are
  user-derived.
- Not touching atoms in `mix.exs` dependency specs, test-support
  modules, migrations, or generated code (e.g. Phoenix route helpers).
  Those are compile-time and bounded.
- Not rewriting `Jason.decode(..., keys: :atoms)` call sites — `mix
  credo --strict` will flag them for separate triage.

## Design

### The rule

**T-03-15:** a public Glorbo function MUST NOT call any of the following
with an argument derived from user input (frontmatter fields, CLI args,
filesystem slugs, message payloads, PubSub messages, external LLM
output):

- `String.to_atom/1`
- `List.to_atom/1`
- `:erlang.binary_to_atom/1`, `:erlang.binary_to_atom/2`
- `:erlang.list_to_atom/1`
- `Module.concat/1`, `Module.concat/2`
- `Jason.decode(..., keys: :atoms)` — use `:atoms!` or omit the key

"Derived from user input" means there exists a call path from a
user-controlled value (HTTP body, CLI arg, file content, agent output)
to the function's argument, including through string interpolation,
concatenation, or formatting.

Permitted alternatives:

- `String.to_existing_atom/1` — safe when the caller can guarantee the
  atom was compiled into the application. Use when parsing a known
  enum where the set of valid atoms is closed and declared in source
  code.
- Tuple-keyed `Registry` via `{:via, Registry, {Module, {kind, …}}}`
  — the canonical pattern for per-instance named processes. Keys are
  plain terms; no atoms are created.
- Allowlist pattern-match — for config values with a small fixed set
  (e.g. `validate_provider/1` in
  `lib/glorbo/agent/parser.ex:181-190`), match the string literal
  against a compile-time list.

### Canonical registry pattern

All per-company and per-agent named processes register via
`Glorbo.Agent.Registry` (despite its name, the registry is generic —
see §Migration for the rename discussion) using tuple keys:

```elixir
# Per-company children (Company.Supervisor):
{:via, Registry, {Glorbo.Agent.Registry, {:company_child, company, :router}}}
{:via, Registry, {Glorbo.Agent.Registry, {:company_child, company, :audit_log}}}
# ... etc.

# Per-agent processes (already implemented):
{:via, Registry, {Glorbo.Agent.Registry, {:agent_server, company, agent}}}
{:via, Registry, {Glorbo.Agent.Registry, {:agent_subtree, company, agent}}}
{:via, Registry, {Glorbo.Agent.Registry, {:agent_task_sup, company, agent}}}
```

Key taxonomy: `{kind, company_slug, role_or_agent_slug}` where `kind`
is a compile-time atom (`:company_child`, `:agent_server`,
`:agent_subtree`, `:agent_task_sup`) and the remaining tuple elements
are strings. Lookup is O(1) via `Registry.lookup/2`.

### Enforcement

`.credo.exs` moves `{Credo.Check.Warning.UnsafeToAtom, []}` from the
`disabled:` list (line 213) to the `enabled:` list. `mix credo
--strict` is part of the precommit gate and CI (`mix precommit` in
the README), so the rule is enforced on every commit to `main`.

Credo's default trigger set covers `String.to_atom/1`, `List.to_atom/1`,
`:erlang.binary_to_atom`, `:erlang.list_to_atom`, `Module.concat/1`,
`Module.concat/2`, and `Jason.decode(..., keys: :atoms)` — exactly the
surface listed in T-03-15. No custom check is needed.

### What changes in code

| File | Change |
|---|---|
| `lib/glorbo/company/supervisor.ex` | Delete `child_name/2`. Replace each child spec's `name:` kwarg with `{:via, Registry, {Glorbo.Agent.Registry, {:company_child, company, role}}}`. |
| `.credo.exs` | Move `{Credo.Check.Warning.UnsafeToAtom, []}` from `disabled:` to `enabled:`. |
| `test/glorbo/company/supervisor_test.exs` | Tests that currently look up children by atom name (if any) switch to `Registry.lookup/2`. |

No change to `Agent.Registry` itself — its API (`via/3`) and key
taxonomy already match the canonical pattern.

## Migration / rollout

This GEP is a small blast-radius change:

1. **Supervisor rewrite (single commit).** `Company.Supervisor` is
   already supervised by a `DynamicSupervisor` per-company; changing
   the child naming does not change the supervision tree topology.
   Running instances restart cleanly.
2. **Credo flip (same commit or follow-up).** Enabling the check
   causes `mix credo --strict` to fail if any other violation exists.
   The audit in §Problem found exactly one; enable + fix happens
   atomically.
3. **No data migration.** Nothing on disk references the atom names.
   The pidfile (`~/.glorbo/run/glorbo.pid`) records an OS pid, not a
   BEAM registered-name atom.
4. **No downstream contract change.** External callers never saw the
   atom names — they were internal plumbing.

Rollback: revert the commit. No persistent state is involved.

## Failure modes

- **Credo false positives.** If `UnsafeToAtom` flags a call site
  that's provably safe (e.g. a compile-time-known string constant),
  the fix is a narrow `# credo:disable-for-next-line` annotation
  plus a one-line rationale comment. The current audit found zero
  such cases in `lib/`.
- **Registry-based lookup in hot paths.** `Registry.lookup/2` is ETS
  `:read_concurrency` + hash; per-lookup cost is ~1µs, comparable to
  an atom lookup via `Process.whereis/1`. No measurable regression
  expected.
- **Test breakage.** Any test that used `Process.whereis(:my_company_router)`
  needs to swap to `Registry.lookup(Glorbo.Agent.Registry,
  {:company_child, "my_company", :router})`. Surfaced at test time,
  fixed in the same commit.
- **Registry contention under high company counts.** Elixir's `Registry`
  partitions by default; for Glorbo's single-tenant deployment target
  this is not a scaling concern. If a multi-tenant fork ever wants
  thousands of companies, `Registry` partitions are tunable
  (`keys: :unique, partitions: System.schedulers_online()`) — but
  that's a future GEP, not this one.

## Test strategy

Three assertions drive the change:

1. **Unit:** `Glorbo.Company.Supervisor` tests assert each child is
   registered under the correct `{:via, Registry, {…, tuple}}` name
   and is looked up via `Registry.lookup/2`.
2. **Integration:** Boot two companies with distinct slugs, verify
   their children's registered names are disjoint and that no
   atoms were created for the slugs (assert
   `Enum.all?([co1, co2], &(&1 not in known_atoms()))`).
3. **Static:** `mix credo --strict` runs in CI and fails closed on
   any new `String.to_atom` introduction. The Credo rule *is* the
   regression test.

No new bench; `Registry.lookup` is a well-trodden path in the Elixir
ecosystem.

## Open questions

- **Rename `Glorbo.Agent.Registry` → `Glorbo.Registry`?** The registry
  is generic; it hosts agent processes today and will host company
  children after this GEP. A rename is a cross-cutting refactor that
  risks merge conflicts. Recommended: defer the rename to a follow-up,
  note the misnomer in the moduledoc, and move on. Not blocking for
  T-03-15 enforcement.
- **Should `Credo.Check.Warning.UnsafeToAtom` be bumped to
  `priority: :high`?** Currently default priority. Higher priority
  makes it impossible to ignore by accident if Credo's output is ever
  truncated. Low stakes either way.
- **Dialyzer rule?** There's no stock Dialyzer check for unsafe
  atom creation. A custom Gradient/Dialyxir plugin is out of scope.
  Credo + code review is sufficient for now.

## Decision log

### D1. Promote T-03-15 to a codified rule, not a new invariant

- **Decided:** GEP-12 documents T-03-15 as the canonical name for the
  "no user-input atoms" rule. The rule itself already exists informally
  across the codebase; this GEP does not invent a new policy.
- **Alternatives:** (a) introduce a new threat code; (b) leave the
  policy informal and rely on code review.
- **Why:** (a) adds a code for the same concept and confuses future
  readers cross-referencing moduledocs. (b) is what got us the
  `Company.Supervisor` violation — "informal" means "ignorable by
  anyone unfamiliar with the convention." Promoting the existing code
  to a Standards rule is the minimum change that fixes the cause.

### D2. `{:via, Registry, tuple}` over `String.to_existing_atom/1`

- **Decided:** per-company and per-agent named processes register via
  tuple-keyed `Registry` entries, not via atom names regardless of
  where the atom comes from.
- **Alternatives:** keep atom-based names but switch to
  `String.to_existing_atom/1` after a compile-time allowlist of
  company slugs; or use `:global` registration with string keys.
- **Why:** `String.to_existing_atom/1` requires the company name to be
  a compiled atom — impossible for user-created companies without an
  eval-at-boot step, which is itself an anti-pattern. `:global` is a
  cluster-wide registry with leader election and replication
  semantics that Glorbo doesn't need (single-node deployment). Local
  `Registry` with tuple keys is the idiomatic Elixir answer for
  per-instance named processes; the agent layer already uses it and
  it works.

### D3. Enforce via Credo, not a custom plugin

- **Decided:** enable the stock `Credo.Check.Warning.UnsafeToAtom`
  rule by moving it from `disabled:` to `enabled:` in `.credo.exs`.
- **Alternatives:** write a custom Credo check; integrate a Dialyzer
  plugin (Gradient, Dialyxir); rely on code review.
- **Why:** the stock rule covers the full T-03-15 surface out of the
  box — verified by reading `deps/credo/lib/credo/check/warning/unsafe_to_atom.ex`.
  A custom check adds maintenance cost for zero additional coverage.
  Dialyzer plugins add a second static-analysis pipeline to CI for the
  same benefit. Code review failed once already (this GEP exists
  because it did); the enforcement layer needs to be automated.

### D4. Fix the single violation in the same PR as the rule

- **Decided:** enabling the Credo rule and rewriting
  `Company.Supervisor.child_name/2` land in one commit or one PR.
- **Alternatives:** enable the rule first (fails CI), fix in a
  follow-up; or fix the supervisor first, enable the rule later.
- **Why:** shipping them separately leaves a window where either CI
  is red (option A) or the guardrail is absent (option B). The fix
  is small (≤30 LOC); bundling preserves the bisectability property
  — either a commit has the rule and the fix or it has neither.

### D5. Carve-out: allow `String.to_existing_atom/1` for closed enum parsing

- **Decided:** `String.to_existing_atom/1` remains permitted for
  parsing inputs against a closed, source-declared enum (e.g. agent
  `network:` field against `[:none, :proxy, :full]`). The
  `security/acl_mapper.ex` moduledoc ban on `String.to_existing_atom`
  is read as "on open-ended user input," not "never."
- **Alternatives:** ban `String.to_existing_atom/1` entirely in user-
  facing code; or allow it anywhere.
- **Why:** `String.to_existing_atom/1` is bounded by the compiled
  atom table — a user cannot leak atoms through it, only hit a
  guaranteed raise. For closed enums, pattern-matching against a
  whitelist of strings is noisier and offers no additional safety.
  For open-ended input (company slugs, agent slugs), it's still
  wrong because the caller can't guarantee the atom exists. The
  carve-out is narrow and documented at the call site.

### D6. Defer `Glorbo.Agent.Registry` rename

- **Decided:** the registry keeps its name despite now hosting
  non-agent processes. A rename is out of scope for this GEP.
- **Alternatives:** rename to `Glorbo.Registry` or
  `Glorbo.ProcessRegistry` in the same PR.
- **Why:** the rename touches every `{:via, Registry, {Glorbo.Agent.Registry, …}}`
  call site — ~10 files. The GEP's blast radius stays small by keeping
  the rename separate; misnomer is noted in the moduledoc. If the
  rename ever happens, it's a single mechanical search-and-replace
  commit and doesn't need its own GEP.

## Related

- [GEP-2](./0002-architecture-overview.md) — architectural baseline;
  documents the OTP supervision tree this GEP tunes.
- [GEP-5](./0005-sandboxing-bwrap-then-podman.md) — coins the T-XX-YY
  threat-code convention that T-03-15 follows.
- `lib/glorbo/agent/registry.ex` — canonical tuple-keyed registry
  implementation.
- `lib/glorbo/agent/parser.ex:13`,
  `lib/glorbo/security/acl_mapper.ex:14` — existing moduledoc
  statements of the T-03-15 policy that this GEP codifies.
- `deps/credo/lib/credo/check/warning/unsafe_to_atom.ex` — the Credo
  check this GEP enables.
