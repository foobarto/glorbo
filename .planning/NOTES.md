# Project Forward-Notes

Running log of forward questions and deferred architectural decisions surfaced during
planning/execution but not owned by the current phase. Each entry is consumed by the
discuss-phase workflow for the phase that owns the decision.

## N-001 — Dynamic agent supervisor shape (Phase 3)

**Surfaced:** 2026-04-15, during Phase 1 post-completion quality review.
**Owning phase:** Phase 3 (Agents, Routing, Kernel Permissions, Budgets).

**Question:** `Glorbo.Company.Supervisor` is a plain `Supervisor` with 5 named static
children (FileWatcher, Router, Scheduler, BudgetTracker, AuditLog), per Phase 1 Plan
01 interfaces. Phase 3 spawns `Glorbo.Agent.Server` instances *dynamically* per Director
action. Where do those GenServers live in the tree?

**Leading hypothesis:** A nested `DynamicSupervisor` under `Glorbo.Company.Supervisor`,
e.g. `Glorbo.Company.AgentSupervisor`, added as a sixth static child. This preserves
the crash-isolation invariant from CLAUDE.md: agent crash → restarted by AgentSupervisor
(one_for_one), company crash → all agents + siblings restarted together by
CompanySupervisor, other companies unaffected (they're separate branches under the
top-level `Glorbo.CompanySupervisor :: DynamicSupervisor`).

**To resolve in Phase 3 CONTEXT.md:**
- Confirm the nested-DynamicSupervisor approach or document an alternative
- Specify the AgentSupervisor restart strategy (one_for_one vs rest_for_one)
- Document the contract: how does the Router address specific agents
  (via registry, via-tuple, or direct pid)?

**Blocks:** Phase 3 planner cannot write the AgentSupervisor spec without this decision.
Not blocking Phase 2 (Phase 2 doesn't spawn agents).
