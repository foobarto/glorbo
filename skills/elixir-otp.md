# Skill: Elixir/OTP Development

## When to Use

When implementing Glorbo's core orchestration layer — supervision trees,
GenServers, file watching, message routing, container management.

## Key Patterns

### Supervision Trees

Glorbo uses a layered supervision tree (DESIGN.md Section 4.1):

```
Glorbo.Application (root)
├── Glorbo.Repo (SQLite)
├── Glorbo.ContainerManager
├── GlorboWeb.Endpoint (Phoenix)
└── Glorbo.CompanySupervisor (DynamicSupervisor)
    └── Per-company: FileWatcher, Router, Scheduler, BudgetTracker, AuditLog
        └── Per-agent: GenServer managing lifecycle
```

- Use `DynamicSupervisor` for companies (added/removed at runtime)
- Use regular `Supervisor` for per-company children (fixed set per company)
- Crash isolation: agent crash restarts only that agent

### GenServer Conventions

```elixir
defmodule Glorbo.Agent do
  use GenServer

  # Public API
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts))
  end

  # Callbacks
  @impl true
  def init(opts) do
    # Load agent.md, set initial state
    {:ok, %{status: :idle, agent: load_agent(opts)}}
  end
end
```

- Always define a public API that wraps `GenServer.call/cast`
- Use `via_tuple` or `Registry` for process naming
- Keep state minimal — read from filesystem when needed
- Use `handle_continue` for expensive init work

### File Watching

Use the `file_system` hex package for inotify:

```elixir
{:ok, pid} = FileSystem.start_link(dirs: [company_path])
FileSystem.subscribe(pid)

# In GenServer handle_info:
def handle_info({:file_event, _pid, {path, events}}, state) do
  # Route based on path and event type
end
```

### Ecto + SQLite

```elixir
# In mix.exs
{:ecto_sqlite3, "~> 0.17"}

# Repo
defmodule Glorbo.Repo do
  use Ecto.Repo, otp_app: :glorbo, adapter: Ecto.Adapters.SQLite3
end
```

The database is disposable. `glorbo reindex` rebuilds it from markdown files.

## Testing

- Use `ExUnit` with `async: true` where possible
- Use `tmp_dir` tag for filesystem tests
- Test GenServer behaviour through the public API, not internal state
- Use `start_supervised!/1` in tests for proper cleanup

## References

- DESIGN.md Sections 4.1 (supervision tree), 5 (agent lifecycle)
- Elixir GenServer docs: https://hexdocs.pm/elixir/GenServer.html
- file_system hex: https://hex.pm/packages/file_system
