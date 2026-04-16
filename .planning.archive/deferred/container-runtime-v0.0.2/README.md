# Deferred: Container Agent Runtime (target v0.0.2+)

**Deferred:** 2026-04-16 — mid-execution of Phase 3.

## Why these artifacts are here

The original Phase 3 of milestone v0.0.1 was scoped around a Python-in-Podman-container agent runtime with:

- `litellm` as unified LLM dispatch layer
- POSIX ACL enforcement inside containers (via `setfacl` + `--userns keep-id`)
- Per-agent Linux user provisioning
- Network policy via Podman + netavark/nftables
- FastAPI worker at `/run` and `/cancel` over Unix domain sockets

Mid-planning, we pivoted to a CLI-first agent runtime (Claude Code, Gemini CLI, Codex) with `bwrap` (bubblewrap) for lightweight isolation. The CLI-agent approach ships faster, leverages each tool's native auth, and gives users immediate value. The container runtime remains a v0.0.2+ goal — it's the right isolation story for untrusted agents and arbitrary LLMs — but deferred so v0.0.1 can ship.

## What's in this archive

- `03-CONTEXT.md` — 45 locked decisions for the container-runtime design
- `03-RESEARCH.md` — Technical research: Netavark firewall limits, `/etc/subuid` UID allocation, litellm cost reporting, Elixir cron libraries, prompt-injection sandboxing patterns
- `03-VALIDATION.md` — Nyquist validation framework (template-filled, not yet authored)
- `03-02-PLAN.md` — Router + Scheduler + BudgetTracker (pattern still relevant; invocation target changes)
- `03-03-PLAN.md` — Agent.Server + Dispatch + Skills.Resolver + LLM.Provider
- `03-04-PLAN.md` — Approvals.Gate + TaskDefinition (fully reusable, nothing container-specific)
- `03-05-PLAN.md` — NetworkPolicy + ACLReconciler + UserProvisioner + 7-child supervisor + 6 integration tests
- `03-DISCUSSION-LOG.md` — Full discussion log of original decisions

## What remains in `phases/03-*` (not deferred)

- `03-01-PLAN.md` + `03-01-SUMMARY.md` — Wave-0 foundations (Ecto schemas, ACLMapper pure module, UidAllocator, worker skills/usage extensions, AUDIT_EVENTS.md) — mostly reusable across both the CLI-agent and container-agent paths. Executed; in `lib/`.
- `AUDIT_EVENTS.md` — Stable audit-event key registry; shared by both runtimes.

## Carry-forward notes for future milestone

When container runtime returns:

1. **litellm is still the right unified LLM layer** inside the container — design holds.
2. **Netavark still has no per-container egress allow-list** as of 2026-04 — plan must ship nftables in-container + pre-resolved CIDR. Research this again before planning.
3. **`--cap-add NET_ADMIN` narrowly scoped to `api-only` mode** is the right deviation from RT-04 — deliberate, auditable.
4. **UidAllocator is already shipped** (in `lib/glorbo/runtime/uid_allocator.ex`) — reads `/etc/subuid` for subordinate UID block assignment.
5. **ACLMapper is already shipped** (in `lib/glorbo/security/acl_mapper.ex`) — pure function from permission strings to `setfacl` commands. When container runtime revives, this module gets exercised.
6. **The glorbo-runtime OCI image already exists** (Phase 2 built it, CI publishes to `ghcr.io/foobarto/glorbo-runtime`). Container runtime phase extends it with `acl` + `nftables` + entrypoint.

## New Phase 3 scope (v0.0.1)

See `.planning/ROADMAP.md` Phase 3 (post-restructure) for the CLI-agent + bwrap design.
