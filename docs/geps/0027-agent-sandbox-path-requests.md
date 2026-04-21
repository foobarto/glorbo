---
gep: 27
title: Agent sandbox path requests via director approval
author: Glorbo Maintainers <noreply@example.invalid>
status: Draft
type: Standards
created: 2026-04-21
history:
  - date: 2026-04-21
    status: Draft
    note: Initial draft.
requires: [2, 5, 19]
see-also: [23]
---

# GEP-27: Agent sandbox path requests via director approval

## Problem

Agents are sandboxed to their company directory via `bwrap` mount namespaces.
Permissions in `agent.md` grant static, coarse-grained access to projects,
channels, and tasks within that company. There is no mechanism for an agent
to request access to a specific path outside its sandbox — whether a host
path (e.g. `/etc/myapp/config.yaml`, `/shared/data/`) or a directory in
another company's tree — even temporarily for a single task dispatch.

Directors who want an agent to read a specific external file must either
edit `agent.md` permissions (permanent, coarse-grained, requires knowing
the right permission tuple) or copy the file into the agent's workspace
(manual, error-prone, no audit trail). Neither approach is task-scoped or
director-approved at the moment of need.

## Goals

- Agents can request access to a specific host path for a specific task.
- Director approves or denies each request, and can choose read-only or
  read-write access independently of what the agent asked for.
- Access is task-scoped: granted only for the duration of one dispatch,
  revoked automatically when the dispatch completes.
- Cross-company access follows the same flow — the director of the
  requesting company approves; no cross-company trust is assumed.
- Every request, approval, denial, and revocation is audited.

## Non-goals

- **Persistent permissions.** This does not add a way for agents to gain
  permanent access to external paths. That would require `agent.md` edits.
- **Cross-company director coordination.** The director of the *requesting*
  company approves. If the path belongs to another company, it is the
  requesting director's responsibility to ensure they have the right to
  grant access. No inter-company approval protocol is introduced.
- **Fine-grained file-level ACLs beyond bwrap binds.** The kernel mount is
  the unit of access. If a path is a directory, the agent sees the whole
  directory. Per-file filtering is out of scope.
- **Network access requests.** This is purely filesystem. Network egress
  is covered by GEP-23 (smart mode / proxy).

## Design

### 2.1 Agent request mechanism

An agent requests path access by writing a sentinel file to its outbox:

```
agents/<slug>/outbox/path-request-<task_id>.md
```

Body format:

```markdown
---
kind: path-request/v1
task_id: <task_id>
paths:
  - path: /absolute/host/path
    mode: read        # read | write
    reason: >-
      Need to read config for deployment task
---

## Context

Additional context for the director...
```

Validation:
- `path` must be an absolute path (starts with `/`).
- `path` must not be `..`-relative after normalization.
- `path` must not be inside the agent's own company directory (those
  are already covered by `agent.md` permissions).
- `mode` must be `read` or `write`.
- Maximum 5 paths per request.
- `reason` is required, min 10 chars.

The Router classifies this outbox path (new route: `path-request`) and
hands it to a new per-company `PathRequestGate` GenServer.

### 2.2 Director approval flow

`PathRequestGate` writes a sentinel to the agent's state directory:

```
agents/<slug>/state/path-pending-<task_id>-<seq>.md
```

The sentinel is visible in the UI (InboxLive or a dedicated panel on
AgentLive). The director sees:
- The requested paths with their requested mode.
- The reason provided by the agent.
- The task this request is associated with.
- Approve / Deny buttons.

On approve, the director can:
- Accept the request as-is.
- Downgrade `write` → `read` for any path.
- Remove individual paths from the grant.

On deny, the request is archived and the agent is notified via inbox.

### 2.3 Task-scoped mount injection

Approved path grants are stored in an ETS table keyed by
`{company, agent, task_id}`. When `Agent.Dispatch` builds the bwrap
context for a dispatch, it queries the ETS table for any active grants
for this `{agent, task_id}` pair and passes them as `approved_paths`
into the bwrap opts.

`Bwrap.build_argv/1` emits mount flags for approved paths:

```elixir
# read → --ro-bind, write → --bind
approved_path_flags(approved_paths)
# => ["--ro-bind", "/etc/myapp/config.yaml", "/external/config.yaml",
#     "--bind", "/shared/data", "/shared/data"]
```

Sandbox paths are derived from the host path:
- For files: `/external/<basename>` (e.g. `/etc/myapp/config.yaml` →
  `/external/config.yaml`).
- For directories: `/external/<basename>` (e.g. `/shared/data` →
  `/external/data`).

This avoids collisions with the existing `/workspace`, `/projects`,
`/channels`, etc. mount points.

After the dispatch completes (success or failure), the grant is removed
from ETS and a `path_access.revoked` audit event is emitted.

### 2.4 Security constraints

- **Path validation on approval.** The director's approval is the trust
  boundary, but the system still validates: no symlinks that escape the
  declared path, no paths under `/proc`, `/sys`, `/dev` (except
  `/dev/null`, `/dev/zero`, `/dev/random` which are already mounted by
  bwrap).
- **No `--bind` of parent directories.** If an agent requests
  `/etc/myapp/config.yaml`, only that file is mounted — not `/etc/` or
  `/etc/myapp/`.
- **Cross-company paths.** If the path is inside `~/.glorbo/companies/`,
  it is mounted read-only regardless of the requested mode. Cross-company
  writes are never permitted.
- **Audit trail.** Every step is audited: `path_access.requested`,
  `path_access.approved`, `path_access.denied`, `path_access.granted`
  (at dispatch start), `path_access.revoked` (at dispatch end).

### 2.5 UI surfaces

- **InboxLive** renders path-request rows alongside approval and stuck
  agent rows. The row shows paths, mode, reason, and approve/deny
  buttons.
- **AgentLive** gains a "Path requests" tab listing pending and recent
  requests for that agent.
- **TaskLive** shows active path grants in the usage strip when a task
  has an approved path request.

## Migration / rollout

Pre-1.0, atomic cut. No migration shim needed:
- New `kind: path-request/v1` files are ignored by the existing Router
  (falls through to unknown-file handling).
- ETS table is empty on boot; no grants persist across restarts.
- No `agent.md` schema change — this is a separate request mechanism.

## Failure modes

- **Agent writes a path request but no task exists.** The request is
  rejected with a `path_access.invalid_task` audit. The sentinel is not
  written; the outbox file is moved to `history/`.
- **Dispatch starts but grant was revoked mid-flight.** The ETS lookup
  happens at dispatch build time, not at wake time. Once the dispatch
  starts, the mount list is fixed. If the director revokes mid-dispatch,
  the running sandbox still has access (kernel mounts can't be torn down
  from outside the namespace). A `path_access.revoked_mid_dispatch`
  audit is emitted; the revocation takes effect on the next dispatch.
- **Path doesn't exist on host.** The bwrap `--bind` / `--ro-bind` fails
  at mount time. The dispatch fails with a structured error; the grant
  is still revoked on completion.
- **ETS table lost on crash.** Grants are ephemeral by design. A crash
  loses all active grants — the agent must re-request. This is
  acceptable for task-scoped access.

## Test strategy

- Unit tests on the Router's new `path-request` classification path.
- Unit tests on `PathRequestGate` lifecycle (request → approve → grant →
  revoke, request → deny).
- Unit tests on `approved_path_flags/1` mount composition (read vs write,
  file vs directory, path sanitization).
- Integration test: full flow from agent outbox write → Router → Gate →
  director approve → dispatch with mount → grant revoked.
- Security tests: path traversal attempts, cross-company write rejection,
  forbidden path rejection (`/proc`, `/sys`).
- E2E test with a real CLI agent (skipped when no agent is available):
  agent writes a path request, director approves via UI, agent reads the
  file in the next dispatch.

## Open questions

- **Should the agent be able to request access to a path by a descriptive
  name** (e.g. "config file") rather than an absolute path? The agent
  might not know the exact host path. Deferred — the agent can describe
  the need in the `reason` field and the director fills in the actual
  path on approval.
- **Should there be a rate limit on path requests?** An agent could spam
  requests. Could add a per-agent, per-hour cap. Deferred to
  implementation.
- **Should the director be able to pre-approve paths** (like a whitelist
  the agent can use without per-request approval)? This would blur the
  line with `agent.md` permissions. Deferred — the explicit per-request
  flow is the MVP.

## Decision log

### D1. Outbox sentinel file as the request mechanism

- **Decided:** Agents request path access by writing a specially named
  file to their outbox (`path-request-<task_id>.md`), parsed by the
  Router and routed to `PathRequestGate`.
- **Alternatives:** (a) A new CLI command the agent invokes inside the
  sandbox; (b) a special section in the task frontmatter; (c) a PubSub
  message from the agent process.
- **Why:** The outbox sentinel pattern is already established for
  approvals, stuck detection, and memory writes. It requires no new
  in-band channel, works with any CLI agent (no API dependency), and
  leaves an audit trail on disk.

### D2. ETS for ephemeral grant storage

- **Decided:** Active grants are stored in an ETS table, keyed by
  `{company, agent, task_id}`, and removed after each dispatch.
- **Alternatives:** (a) SQLite rows with TTL; (b) filesystem sentinel
  files; (c) Agent.Server process state.
- **Why:** ETS is fast, per-BEAM, and naturally ephemeral — a restart
  clears all grants, which is the correct behaviour for task-scoped
  access. SQLite would persist grants across restarts (wrong semantics).
  Filesystem sentinels would require cleanup logic and race handling.
  Agent.Server state would not survive agent crashes.

### D3. Mount point namespace: `/external/<basename>`

- **Decided:** Approved paths are mounted under `/external/<basename>` in
  the sandbox, with `--ro-bind` for read and `--bind` for write.
- **Alternatives:** (a) Mount at the same absolute path inside the
  sandbox; (b) a dedicated `/requested/` namespace; (c) mount into the
  agent's workspace.
- **Why:** `/external/` is a clear, distinct namespace that doesn't
  collide with existing mount points (`/workspace`, `/projects`,
  `/channels`, `/outbox`, `/inbox`). Mounting at the same absolute path
  could conflict with existing mounts or leak directory structure.
  Workspace mounts would give the agent write access to the parent dir.

### D4. Cross-company paths always read-only

- **Decided:** If the requested path is inside `~/.glorbo/companies/`,
  it is always mounted read-only, regardless of the agent's requested
  mode.
- **Alternatives:** (a) Allow cross-company writes with explicit director
  approval; (b) block cross-company requests entirely.
- **Why:** Company isolation is absolute (CLAUDE.md invariant). Allowing
  cross-company writes would violate this at the kernel layer. Read-only
  access is a pragmatic compromise — an agent can read another company's
  config or data without being able to modify it. Blocking entirely would
  prevent legitimate read-only use cases (e.g. reading a shared model
  config from a template company).

### D5. Director can downgrade or trim paths on approval

- **Decided:** When approving a request, the director can change `write`
  → `read` for any path and remove individual paths from the grant.
- **Alternatives:** (a) Approve or deny the request as-is; (b) allow the
  director to add additional paths.
- **Why:** The principle of least privilege means the director should be
  able to reduce the scope of a request. Adding paths is unnecessary —
  the director can always approve a reduced request and the agent can
  request more if needed.

## Related

- GEP-2 — architecture overview (company isolation, bwrap sandboxing).
- GEP-5 — bwrap sandboxing (the kernel-as-policy-engine invariant).
- GEP-19 — director approval workflow protocol (sentinel contract,
  approval UI patterns).
- GEP-23 — egress proxy (smart mode for network; this GEP is the
  filesystem analog).
- DESIGN.md §5 — Sandboxing (bwrap mount namespace composition).
- `Glorbo.Sandbox.Bwrap` — bwrap argv composition.
- `Glorbo.Sandbox.PermissionMapper` — permission-to-mount mapping.
- `Glorbo.Approvals.Gate` — existing approval gate lifecycle.
