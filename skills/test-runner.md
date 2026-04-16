# Skill: Test Runner

## When to Use

When writing tests, running test suites, or updating test status tracking.

## Running Tests

### Elixir (ExUnit)
```bash
# Run all tests
mix test

# Run specific file
mix test test/glorbo/agent_test.exs

# Run specific test (by line number)
mix test test/glorbo/agent_test.exs:42

# Run with coverage
mix test --cover

# Run with verbose output
mix test --trace
```

### Check Code Quality
```bash
# Format check
mix format --check-formatted

# Compiler warnings
mix compile --warnings-as-errors

# Static analysis (if credo is configured)
mix credo
```

## Writing Tests

### ExUnit Conventions
```elixir
defmodule Glorbo.AgentTest do
  use ExUnit.Case, async: true

  # Use tmp_dir for filesystem tests
  @tag :tmp_dir
  test "loads agent from markdown file", %{tmp_dir: tmp_dir} do
    agent_md = Path.join(tmp_dir, "agent.md")
    File.write!(agent_md, """
    ---
    name: TestAgent
    role: Test Role
    provider: ollama
    model: qwen3:8b
    ---
    You are a test agent.
    """)

    assert {:ok, agent} = Glorbo.Agent.load(agent_md)
    assert agent.name == "TestAgent"
  end

  describe "lifecycle" do
    test "starts in idle state" do
      {:ok, pid} = start_supervised!({Glorbo.Agent, name: "test"})
      assert Glorbo.Agent.status(pid) == :idle
    end

    test "transitions to working on task" do
      {:ok, pid} = start_supervised!({Glorbo.Agent, name: "test"})
      :ok = Glorbo.Agent.assign_task(pid, task)
      assert Glorbo.Agent.status(pid) == :working
    end
  end
end
```

### Test Categories
- **Unit:** Individual module functions
- **Integration:** Module interactions (e.g., Router + FileWatcher)
- **LiveView:** Dashboard rendering and events
- **Property:** Data validation with StreamData

## Updating Test Status

After every run, update `.state/test-status.md`:

1. Update the Summary table with component-level status
2. Update each component section with:
   - Pass/fail counts
   - Timestamp
   - Failure details (if any)
   - Missing coverage notes

## What to Test

Priority order:
1. Permission enforcement (security-critical)
2. Message routing (correctness-critical)
3. Agent lifecycle (state machine correctness)
4. File parsing (YAML frontmatter, markdown)
5. Dashboard rendering (user-facing)
