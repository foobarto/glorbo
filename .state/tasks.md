# Task Board

> Source of truth for all work items. Updated by agents as work progresses.

## Backlog

### TASK-001 — Scaffold Elixir/Phoenix project
- **Priority:** high
- **Assignee:** developer
- **Skills:** elixir-otp, phoenix-liveview
- **Description:** Initialize the Mix project with Phoenix, Ecto (sqlite3),
  and LiveView. Set up the supervision tree skeleton from DESIGN.md Section 4.1.
  Include basic config, router, and endpoint.
- **Acceptance criteria:**
  - `mix deps.get` succeeds
  - `mix compile` succeeds with zero warnings
  - `mix test` runs (even if empty)
  - Supervision tree matches DESIGN.md Section 4.1 sketch
- **Blocked by:** none

### TASK-002 — Implement filesystem directory structure
- **Priority:** high
- **Assignee:** developer
- **Skills:** elixir-otp
- **Description:** Implement the `glorbo init` command that creates the
  `~/.glorbo/` directory structure as specified in DESIGN.md Section 3.
  Parse and validate `company.md` and `agent.md` YAML frontmatter.
- **Acceptance criteria:**
  - Creates full directory tree from DESIGN.md Section 3
  - Parses YAML frontmatter from markdown files
  - Validates required fields
  - Tests cover happy path and validation errors
- **Blocked by:** TASK-001

### TASK-003 — Agent lifecycle GenServer
- **Priority:** high
- **Assignee:** developer
- **Skills:** elixir-otp
- **Description:** Implement the Agent GenServer that manages agent lifecycle:
  definition loading, waking, sleeping, status tracking. Per DESIGN.md
  Section 5.
- **Acceptance criteria:**
  - GenServer starts from agent.md definition
  - Tracks agent state (idle, working, sleeping)
  - Handles wake triggers (inbox, heartbeat, director request)
  - Tests cover lifecycle transitions
- **Blocked by:** TASK-001, TASK-002

### TASK-004 — File watcher (inotify integration)
- **Priority:** medium
- **Assignee:** developer
- **Skills:** elixir-otp
- **Description:** Implement FileWatcher using the `file_system` hex package.
  Watch company directories for inbox/outbox changes. Trigger agent wake
  events. Per DESIGN.md Section 5.2.
- **Acceptance criteria:**
  - Detects new files in watched directories
  - Triggers appropriate GenServer callbacks
  - Handles file watcher crashes gracefully (supervisor restarts)
  - Tests with temporary directories
- **Blocked by:** TASK-001, TASK-003

### TASK-005 — Message routing (inbox/outbox)
- **Priority:** medium
- **Assignee:** developer
- **Skills:** elixir-otp
- **Description:** Implement the Router module that reads agent outbox files,
  checks permissions, and delivers to recipient inbox or channel. Per
  DESIGN.md Section 6.1.
- **Acceptance criteria:**
  - Routes messages from outbox to inbox
  - Validates message format (YAML frontmatter)
  - Checks sender permissions before delivery
  - Moves delivered messages to history/
  - Tests cover routing, permission denial, malformed messages
- **Blocked by:** TASK-002, TASK-003, TASK-004

### TASK-006 — Research container runtime options
- **Priority:** medium
- **Assignee:** researcher
- **Description:** Evaluate Podman integration approaches for Elixir.
  System calls vs. library bindings. Rootless container setup.
  How to map host UIDs. How to set up ACLs inside containers.
- **Acceptance criteria:**
  - Written report in .state/inbox.md
  - Comparison of approaches with trade-offs
  - Recommended approach with rationale
- **Blocked by:** none

### TASK-007 — SQLite index schema
- **Priority:** medium
- **Assignee:** developer
- **Skills:** elixir-otp
- **Description:** Design and implement Ecto schemas and migrations for the
  SQLite index. Cover task index, budget ledger, agent status, audit events.
  Per DESIGN.md Section 4.5.
- **Acceptance criteria:**
  - Ecto schemas for all indexed data
  - Migrations create tables
  - `glorbo reindex` populates from filesystem
  - Tests verify schema and reindex
- **Blocked by:** TASK-001, TASK-002

### TASK-008 — Phoenix LiveView dashboard skeleton
- **Priority:** low
- **Assignee:** developer
- **Skills:** phoenix-liveview
- **Description:** Set up the basic LiveView dashboard with navigation.
  Company overview page, agent list, placeholder kanban. Per DESIGN.md
  Section 9.
- **Acceptance criteria:**
  - Dashboard serves on localhost:4000
  - Navigation between views works
  - Company overview shows basic data from filesystem
  - Tests cover LiveView rendering
- **Blocked by:** TASK-001, TASK-007

## In Progress

(none)

## In Review

(none)

## Done

(none)
