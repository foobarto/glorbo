---
gep: 0046
title: Parallelisation of company agents — per-agent and per-company concurrency caps
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-05-07
history:
  - date: 2026-05-07
    status: Draft
    note: Initial draft.
  - date: 2026-05-07
    status: Accepted
    note: Design Q&A converged; D1–D8 settled. Ready to ship.
  - date: 2026-05-07
    status: Implemented
    note: Code shipped in 17af5c5; CI green on 9a27fc0 (x86_64 flake fix). Frontmatter `extends:` collapsed into `requires:` so the GEP-16 ↔ GEP-46 link is bidirectional per GEP-1.
requires: [2, 16]
see-also: [12, 14, 25]
---

# GEP-46: Parallelisation of company agents

## Problem

Glorbo's per-agent runtime is single-instance and one-at-a-time. Each
agent is a single `Glorbo.Agent.Server` GenServer registered at
`{:agent_server, company, slug}`; its state machine is `:idle | :busy`
with a one-slot most-recent-wins wake-queue. Concurrent wakes coalesce
into that single slot; a dispatch in progress blocks any subsequent
work for that agent until the underlying CLI tool exits. For long-
running providers (claude-code with deep tool-call trees, stado in
ACP mode with multi-turn budgets) and chatty triggers (frequent
heartbeats, dense inbox traffic), the agent serialises work that
could safely run in parallel — different inbox messages, independent
heartbeat passes, multiple director requests.

At the company level the situation is the inverse. Per-company
isolation is absolute (GEP-2), and each agent has its own subtree
under `Glorbo.Company.AgentSupervisor`, so different agents in the
same company *do* run in parallel today — but with no upper bound.
Companies with dense rosters and aggressive heartbeats can spike to
double-digit concurrent dispatches, saturating the provider's API
quota or the host's resources, with no operator-visible knob to
throttle without rewriting every `AGENT.md`.

The wake-dispatch pipeline (GEP-16) documents the seven layers of
boundary glue but does not specify the state-transition contract or
busy-coalescing semantics. The current single-slot model is an
implementation detail of `Glorbo.Agent.Server`, not a captured
decision. No GEP today discusses per-company concurrency caps, and
no GEP documents the implicit atomicity of `BudgetTracker` as the
serialisation point for budget-relevant operations. This GEP fills
all three gaps.

## Goals

- Add a per-agent `max_concurrency: N` field to `AGENT.md`. Default
  `1` preserves today's behaviour; `N>1` permits up to N concurrent
  invocations of the same agent.
- Add a per-company `max_concurrent_dispatches: N` field to
  `company.md`. Default unset (unbounded); when set, the company runs
  at most N concurrent dispatches across its entire roster.
- Document the cross-company parallelism that already works
  (`Glorbo.CompanySupervisor` → per-company subtrees) and add an
  integration test that asserts it.
- Define a clean state-machine extension to `Glorbo.Agent.Server` —
  in-flight invocations as a `%{ref => invocation_struct}` map — that
  reduces to today's behaviour when `max_concurrency = 1`.
- Define the per-company semaphore as a new
  `Glorbo.Company.DispatchSemaphore` GenServer registered as
  `{:company_child, <co>, :dispatch_semaphore}` per GEP-12.
- Capture the budget-overshoot bound under concurrency in writing.

## Non-goals

- **Cross-host distribution / clustering.** GEP-2 D1 locks Glorbo to
  a single Elixir node per host. Concurrency caps are in-process,
  enforced via OTP primitives. No `pg`, no consensus, no multi-node
  coordination.
- **Provider-side rate limiting.** This GEP caps how many dispatches
  Glorbo runs concurrently. It does not enforce per-provider API
  quotas (claude.ai's per-minute limit, stado's session caps, etc.) —
  that remains the provider's concern.
- **Priority queues among queued tasks.** When at the cap, the
  pending wake stays one-slot-coalescing; the inbox itself is the
  durable queue. No priority field, no preemption, no per-trigger
  weighting.
- **Dynamic runtime resizing via API.** Caps are read from
  `AGENT.md` / `company.md` at boot and on file-watcher reloads. No
  runtime knob to nudge `max_concurrency` mid-run.

## Design

### File-format changes (GEP-25 machinery)

Two new optional frontmatter keys, both defaulting to "preserve
today's behaviour":

```yaml
# AGENT.md
max_concurrency: 1     # optional; integer >= 1; default 1
```

```yaml
# company.md
max_concurrent_dispatches: 10   # optional; integer >= 1; default unset
```

`Glorbo.FileSpec.AgentMd.frontmatter_schema/0` adds
`:max_concurrency` to `optional`. `Glorbo.FileSpec.CompanyMd.frontmatter_schema/0`
adds `:max_concurrent_dispatches` to `optional`. Both spec modules
update their `canonical_key_order/0` callbacks. `mix glorbo.docs.file_formats`
regenerates `docs/file-formats/agent_v1.md` and `docs/file-formats/company_v1.md`
in the same PR (GEP-25 D5: precommit fails on drift).

The `Glorbo.Agent.Spec` struct gains `max_concurrency: pos_integer()`
with a default of `1`. The `Glorbo.Company` struct gains
`max_concurrent_dispatches: pos_integer() | nil` with a default of `nil`.

### Per-agent state machine

`Glorbo.Agent.Server`'s `state` shape changes from a single
`current_task_*` tuple plus a boolean status to:

```elixir
%State{
  in_flight: %{
    reference() => %{
      task_id: String.t(),
      task_path: String.t() | nil,
      trigger: trigger(),
      pid: pid(),
      invocation_id: String.t(),
      started_at: DateTime.t()
    }
  },
  pending_wake: {trigger(), DateTime.t()} | nil,
  max_concurrency: pos_integer(),
  ...
}
```

Status is derived: `:idle` when `map_size(in_flight) == 0`, `:busy`
when `1 <= map_size(in_flight) < max_concurrency`, `:full` when at
the cap.

`handle_info({ref, result})` looks up the completed invocation by
ref in O(1), removes it from `in_flight`, and records the result.

The wake handlers reduce to a single rule: on every dispatch
completion AND every fresh wake, attempt to drain the inbox and
launch dispatches up to `max_concurrency`. The `pending_wake` slot
is kept as a coalescing signal for the case where wakes arrive
faster than the slot frees but the inbox scan is empty. With
`max_concurrency = 1` the behaviour collapses to today's exact
semantics — a single slot, one-slot pending, status `:idle | :busy`.

### Per-company semaphore

A new `Glorbo.Company.DispatchSemaphore` GenServer is added as a
sibling under `Glorbo.Company.Supervisor`, registered via the
existing per-company Registry as
`{:company_child, <co>, :dispatch_semaphore}`. Public API:

```elixir
@spec acquire(GenServer.server(), %{
        agent: String.t(),
        invocation_id: String.t()
      }) :: {:ok, token()} | :throttled
def acquire(server, %{} = ctx)

@spec release(GenServer.server(), token()) :: :ok
def release(server, token)
```

The GenServer holds `%{cap: pos_integer() | :unbounded, in_flight:
%{token => holder_info}}`. `acquire/2` is a `call/2` (serialised by
the GenServer mailbox; this is the atomicity boundary). When `cap`
is `:unbounded`, every acquire returns `{:ok, token}` immediately
and only counts for observability. When at cap, `acquire/2` returns
`:throttled` and the caller queues a `pending_wake`. The semaphore
monitors the holder pid (the `Agent.Server`); if it crashes, the
slot is released automatically — no stale tokens.

`Glorbo.Agent.Dispatch.execute/3` calls `DispatchSemaphore.acquire/2`
between budget check and prompt write. On `:throttled`, it returns
`{:throttled, :company_dispatch_cap}` to the `Agent.Server`, which
treats this exactly like the per-agent at-cap case (drop into
`pending_wake`, retry on next free).

### Cross-company parallelism

Already provided by `Glorbo.CompanySupervisor`'s
`DynamicSupervisor` over per-company subtrees (GEP-2). Each
company's `Agent.Server`s, `BudgetTracker`, `Scheduler`, and now
`DispatchSemaphore` live in their own subtree; nothing serialises
across companies. This GEP commits to maintaining that invariant
and adds an integration test (`test/integration/cross_company_concurrent_test.exs`)
that drives two companies in parallel and asserts overlapping
`agent.dispatch` audit timestamps.

### Workspace coexistence

Each invocation already gets its own `.glorbo-run/<task_id>/`
namespace (GEP-8 reply contract). The shared
`agents/<slug>/stdout.log` becomes per-invocation:
`agents/<slug>/stdout-<invocation_id>.log`. The agent root sees a
small set of log files (one per recent invocation) rather than a
single interleaved tail. Operators tailing logs grep by
`invocation_id`. `Glorbo.Sandbox.Bwrap.start/2`'s `stdout_log` opt
already accepts a per-call path; only the path-construction site in
`Glorbo.Agent.Dispatch.default_run_fun/4` changes.

The `inbox/` and `outbox/` directories stay shared at the agent
level (Router is the single write channel; per-invocation isolation
isn't needed and would break the canonical one-way flow from GEP-2).

## Migration / rollout

Backward-compatible by construction:

1. **No file changes are required.** `AGENT.md` files without
   `max_concurrency:` continue to work at the default `1` — exact
   today's behaviour. `company.md` files without
   `max_concurrent_dispatches:` continue with no company-level cap.
2. **No supervisor restart is required for existing data on disk.**
   Glorbo upgrade implies a Glorbo restart anyway; the new
   `DispatchSemaphore` child is added to `Company.Supervisor`'s
   `start_link/1` and starts on next boot.
3. **`mix glorbo.docs.file_formats`** regenerates the two affected
   docs in the same PR.
4. **`glorbo validate`** treats the new optional keys as known. No
   `:unknown_key` warnings for files that adopt them.
5. **`glorbo fmt`** preserves the new keys per its existing
   syntactic-only contract (GEP-25 D3).

A file-watcher reload of `AGENT.md` (existing mechanism) re-parses
the spec; the `Agent.Server` picks up the new `max_concurrency` on
next dispatch attempt. Mid-flight invocations continue at the old
cap (no preemption); newly arriving wakes use the new cap. This is
documented as "changes take effect monotonically — current
invocations finish, then the new cap applies."

## Failure modes

- **`DispatchSemaphore` GenServer crash.** Per-company crash
  isolation (GEP-2): the semaphore restarts under
  `Glorbo.Company.Supervisor`. In-flight invocations that hold
  tokens are temporarily orphaned; on restart, the new semaphore
  starts with an empty `in_flight` map. Holders' pids are no longer
  monitored, but each holder is itself supervised by its own
  agent subtree, so the orphan window is short. Worst case: brief
  permissiveness (semaphore appears empty until next acquire). No
  durability guarantee is needed — concurrency caps are advisory,
  not security-load-bearing (GEP-2 D4 reserves "kernel is the policy
  engine" for permissions; capacity caps are application-layer
  only).
- **Budget overshoot under concurrency.** Soft cap with a documented
  bound: `overshoot ≤ N × max_per_dispatch_cost`. With default
  `max_concurrency = 1` this is the same bound Glorbo has today
  (single dispatch can already overshoot). For companies with
  `max_concurrent_dispatches: N`, the bound generalises naturally.
  Document in `docs/file-formats/company_v1.md`.
- **Cap reduced while at-cap.** Operator edits `AGENT.md` to lower
  `max_concurrency` from 3 to 1 while 3 invocations are in flight.
  All 3 finish (no preemption); the 4th wake waits until
  `map_size(in_flight) < 1`, i.e. all current ones are done.
  Predictable; documented.
- **Cap raised at-cap.** Symmetric: 1 in flight, cap raised to 3,
  next wake immediately allowed to dispatch. The drain-on-free path
  in the wake handler picks it up automatically.
- **Pathological wake floods.** Inbox-driven inotify burst causes 50
  wakes in a second; agent has `max_concurrency = 3`. First 3
  dispatch; 47 wake notifications coalesce to one `pending_wake`
  slot. Each slot completion drains the inbox: dispatches up to the
  cap, sets `pending_wake` if more inbox work remains. No unbounded
  state growth; the inbox itself is the durable queue.

## Test strategy

Three layers, matching the architecture:

1. **`test/glorbo/agent/server_test.exs`** — extended with cases
   that exercise `max_concurrency > 1`. Use the existing
   `dispatch_fun` injection seam: a fake that signals start/finish
   to the test pid via `send`. Assert: in_flight fills to cap, never
   exceeds it; pending_wake re-drains inbox on completion; cap = 1
   reproduces today's exact behaviour (regression guard).
2. **`test/glorbo/company/dispatch_semaphore_test.exs`** (NEW) — unit
   tests for the new GenServer. acquire → release → re-acquire;
   acquire at cap returns `:throttled`; crashed holder reclaims its
   slot via `Process.monitor`; `:unbounded` cap permits everything
   without bookkeeping growth (smoke check on `in_flight` map size).
3. **`test/integration/concurrent_dispatch_test.exs`** (NEW) — drives
   real `Agent.Server`s under a real `Company.Supervisor`. Two
   parallel asserts:
   (a) two agents in the same company with `max_concurrent_dispatches`
   unset run with overlapping `agent.dispatch` audit timestamps;
   (b) one agent with `max_concurrency = 3` produces 3 distinct
   `invocation_id`s in `agent.dispatch` audit before any
   `agent.complete` arrives.
4. **`test/integration/cross_company_concurrent_test.exs`** (NEW) —
   two companies, each with one agent dispatching simultaneously.
   Asserts overlapping `agent.dispatch` timestamps across companies.
   This codifies the GEP-2 invariant the gep-research surfaced as
   undocumented.

`mix gep.validate` covers structural concerns. `mix precommit` runs
the full suite plus regenerated file-format docs.

## Open questions

- **Hot-reload precision.** Changing `max_concurrency` mid-run is
  documented as "monotonic — applies on next dispatch attempt."
  An operator might want a per-agent kill-switch ("drain in flight,
  stop new dispatches"). Out of scope for this GEP; punt to a
  future "agent quiescence" GEP if real demand surfaces.
- **Observable metrics.** The dashboard could show "in_flight: 2/3"
  per agent and "company concurrent: 7/10" per company. Mechanical
  to add via the existing `broadcast_status/1` hook in `Agent.Server`
  + a similar `:telemetry` event from `DispatchSemaphore`. Implementation
  detail; not GEP-load-bearing.
- **Pre-flight cost reservation.** If the soft-cap bound proves too
  loose under heavy concurrency, a follow-up GEP can add per-provider
  cost estimation + reserve/commit/release. Deferred — most
  companies will never hit the regime where this matters.
- **Priority queues at cap.** The current design uses inbox-as-queue
  + one-slot pending_wake coalescing. If operators want
  fair-share per trigger (e.g. always reserve one slot for
  `:director_request`), it's a follow-up. Punt.

## Decision log

### D1. Per-company semaphore is its own GenServer, not extended `BudgetTracker`

- **Decided:** add a new `Glorbo.Company.DispatchSemaphore` GenServer
  as a sibling under `Glorbo.Company.Supervisor`, registered via the
  per-company Registry as `{:company_child, <co>, :dispatch_semaphore}`.
- **Alternatives:** extend `Company.BudgetTracker` with slot
  accounting; lock-free `:counters` / `:ets` table at supervisor
  scope.
- **Why:** single-purpose GenServer is consistent with every other
  per-company resource (Router, BudgetTracker, Scheduler) per
  GEP-12. Folding into `BudgetTracker` couples two responsibilities
  (spend caps + concurrency caps) and risks a slow budget audit-log
  scan blocking dispatch acquisition. ETS would preserve atomicity
  but doesn't compose with future budget-coordinated logic and is
  inconsistent with the codebase pattern.

### D2. Per-agent in-flight tracked as `%{ref => invocation}` map

- **Decided:** `Agent.Server` state changes from flat `current_task_*`
  fields to `in_flight: %{reference() => invocation_struct}` keyed
  by `Task.async_nolink` ref.
- **Alternatives:** list of invocation structs; lift each flat field
  to a list (`current_task_ids: [...]` etc.).
- **Why:** O(1) lookup in `handle_info({ref, _result})` to find the
  completing invocation; clean migration where today's single-slot
  is just `map_size(in_flight) <= 1`. List requires linear scan.
  Parallel lists lose per-invocation grouping (you'd zip-by-index
  to know which task_id pairs with which pid) — fragile.

### D3. One-slot coalescing wake-queue + drain-on-free

- **Decided:** keep `pending_wake` as a one-slot most-recent-wins
  coalesce signal. On every dispatch completion (slot freeing), the
  agent re-scans its inbox and immediately dispatches the next
  unread message if there's a free slot — repeat until all slots
  full or inbox empty.
- **Alternatives:** bounded FIFO of N pending wakes; unbounded
  `:queue.new()`.
- **Why:** the inbox itself is the durable queue (filesystem,
  Router-mediated). A separate wake queue duplicates state for no
  win. Drain-on-free preserves the wake-driven model while
  guaranteeing no inbox message gets stranded under N>1 — a
  regression that naive one-slot coalescing would introduce.

### D4. Defaults: per-agent 1, per-company unbounded

- **Decided:** `max_concurrency` default `1`;
  `max_concurrent_dispatches` default unset (unbounded).
- **Alternatives:** per-agent unbounded; per-company small constant
  (e.g. 5); require explicit values.
- **Why:** preserve today's behaviour for every existing AGENT.md /
  company.md without modification. Per-agent default 1 matches the
  current single-instance model. Per-company unbounded matches the
  current "different agents already run in parallel without a cap".
  Explicit-required would force every existing install to migrate
  on upgrade — violates GEP-25 D9 (no soft-migration ever).

### D5. Per-invocation `stdout-<invocation_id>.log` instead of shared log

- **Decided:** under N>1, each invocation writes to
  `agents/<slug>/stdout-<invocation_id>.log`. The existing
  `stdout.log` path becomes per-invocation.
- **Alternatives:** keep one shared `stdout.log` with file-locked or
  in-process write coordination.
- **Why:** interleaved output from N concurrent CLI invocations is
  hard to read and breaks `glorbo logs` / dashboard tail behaviour.
  Per-invocation files cost only a small file-count increase; the
  agent root already accumulates `history/` entries indefinitely
  without operator pain. Operators grep by `invocation_id`.

### D6. Soft budget cap with documented overshoot bound

- **Decided:** keep today's check-before/record-after pattern.
  Document the bound:
  `overshoot ≤ N × max_per_dispatch_cost` where `N` is the effective
  concurrency. With the default `max_concurrency = 1` this is the
  same bound Glorbo has had since v0.0.1 — a single in-flight
  dispatch can already overshoot.
- **Alternatives:** pre-flight cost reservation + commit/release;
  serialise budget-tracked dispatches (force `max_concurrency: 1`
  on any agent whose provider has `usage_parser != "none"`).
- **Why:** pre-flight estimation requires reliable per-provider cost
  prediction, which not every provider offers (variable-cost calls,
  tool-use loops). Adds two GenServer round-trips per dispatch.
  Forcing serialisation on tracked providers defeats the GEP for
  the most common provider class. The soft cap matches the existing
  invariant and generalises cleanly. If real-world overshoot proves
  problematic, a follow-up GEP can introduce reservation.

### D7. Concurrency caps are application-layer only, not kernel-enforced

- **Decided:** the per-agent and per-company caps are enforced in
  Elixir (the `DispatchSemaphore` GenServer + `Agent.Server` state
  machine). bwrap continues to know nothing about per-agent or
  per-company concurrency. There is no kernel mechanism that limits
  "at most N concurrent bwrap processes for agent X."
- **Alternatives:** cgroup-based concurrent-process caps via
  systemd-run; XDG-style flock chains.
- **Why:** GEP-2 D4 reserves dual-layer (application + kernel)
  enforcement for permissions — the security-load-bearing class
  where an agent escaping the application check could read host
  data. Concurrency caps are capacity controls; the worst-case
  failure is a brief overshoot of the cap, not a security boundary
  breach. Single-layer enforcement is correct here. Documenting
  this prevents future contributors from assuming the dual-layer
  pattern applies to capacity controls too.

### D8. Layered tests including new cross-company integration

- **Decided:** unit tests on `Agent.Server` (in_flight map shape,
  pending_wake coalescing, regression for cap=1) + unit tests on
  `DispatchSemaphore` (acquire/release/timeout/crash-recovery) +
  two new integration tests (per-company concurrency with two
  agents; cross-company concurrency with two companies).
- **Alternatives:** only unit tests; property-based tests with
  StreamData generating random wake/complete sequences.
- **Why:** the whole point of the GEP is concurrency; tests must
  exercise the cross-process path. The cross-company integration
  test also closes the gep-research-surfaced gap (no GEP currently
  documents the cross-company concurrency invariant). StreamData
  is powerful but heavyweight for the contract here; unit tests
  cover the deterministic state-machine transitions more legibly.
  Add property tests later if races surface.

## Related

- GEP-2 (architecture overview) — supervision-tree shape, per-company
  isolation, application-vs-kernel enforcement boundary.
- GEP-12 (no user-input atoms) — Registry naming convention for
  per-company children, used by the new `DispatchSemaphore`.
- GEP-14 (heartbeat semantics) — heartbeats are one of the dense wake
  triggers this GEP is motivated by.
- GEP-16 (agent wake-dispatch pipeline) — extended by this GEP. The
  state machine documented here was implicit in GEP-16.
- GEP-25 (file-format spec + tooling) — schema-extension machinery
  for adding the new optional keys to AGENT.md / company.md.
- `lib/glorbo/agent/server.ex` — current state machine.
- `lib/glorbo/company/agent_supervisor.ex` — current per-agent
  subtree wiring.
- `lib/glorbo/company/supervisor.ex` — where `DispatchSemaphore`
  will be added as a sibling child.
