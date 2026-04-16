# Skill: Phoenix LiveView Dashboard

## When to Use

When building Glorbo's real-time dashboard — company overview, kanban board,
agent monitoring, chat interface, approval queue.

## Key Patterns

### LiveView Structure

```elixir
defmodule GlorboWeb.DashboardLive do
  use GlorboWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to PubSub for real-time updates
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:acme")
    end

    {:ok, assign(socket, companies: list_companies())}
  end

  @impl true
  def handle_info({:company_updated, data}, socket) do
    {:noreply, assign(socket, ...)}
  end
end
```

### Real-Time Updates

Glorbo uses PubSub broadcasts triggered by file system changes:

1. `FileWatcher` detects change via inotify
2. Broadcasts to PubSub topic
3. LiveView `handle_info` receives and updates assigns
4. DOM patches automatically — no polling

### Dashboard Views (DESIGN.md Section 9)

- **Company overview:** Agent statuses, active tasks, budget burn
- **Kanban board:** Tasks across projects, drag-and-drop
- **Agent detail:** Config, current task, budget, live stdout
- **Chat:** Real-time channels, Director can post to any
- **Approval queue:** Pending approvals, one-click approve/reject
- **Audit log:** Searchable event history

### Components

Use function components for reusable UI:

```elixir
defmodule GlorboWeb.Components.TaskCard do
  use Phoenix.Component

  attr :task, :map, required: true

  def task_card(assigns) do
    ~H"""
    <div class="task-card">
      <h3><%= @task.title %></h3>
      <span class={"status-#{@task.status}"}><%= @task.status %></span>
    </div>
    """
  end
end
```

### No JavaScript Build Step

LiveView handles all interactivity. No npm, no webpack, no esbuild config.
The only JS is the LiveView client socket (included by Phoenix).

## Testing

- Use `Phoenix.LiveViewTest` for LiveView testing
- Test rendered HTML and event handling
- Mock PubSub for real-time update tests

## References

- DESIGN.md Section 9 (Dashboard)
- Phoenix LiveView docs: https://hexdocs.pm/phoenix_live_view
