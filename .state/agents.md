# Agent Registry

> Tracks which agents are available and what tools back them.
> Any AI CLI tool that can read/write files can act as an agent.

## Active Agents

### developer
- **Tools:** Claude Code, Codex CLI, Gemini CLI
- **Status:** available
- **Skills:** elixir-otp, phoenix-liveview, code-review, test-runner
- **Handles:** Implementation, bug fixes, refactoring, architecture
- **Current task:** none

### researcher
- **Tools:** Claude Code, Gemini CLI
- **Status:** available
- **Skills:** web-search, code-review
- **Handles:** Architecture investigation, library evaluation, trade-off analysis
- **Current task:** none

### tester
- **Tools:** Claude Code, Codex CLI
- **Status:** available
- **Skills:** test-runner, code-review
- **Handles:** Test writing, test execution, coverage tracking, test-status updates
- **Current task:** none

### reviewer
- **Tools:** Claude Code, Gemini CLI
- **Status:** available
- **Skills:** code-review, elixir-otp, phoenix-liveview
- **Handles:** Code review, design review, PR review
- **Current task:** none

## Tool Configuration

### Claude Code
- **Invocation:** `claude` or IDE integration
- **Slash commands:** `.claude/commands/*.md`
- **Strengths:** Deep reasoning, large context, tool use, code generation
- **Agent activation:** `/developer`, `/tester`, `/researcher`, `/reviewer`

### Gemini CLI
- **Invocation:** `gemini`
- **Strengths:** Large context window, web grounding, multimodal
- **Agent activation:** Read CLAUDE.md, read assigned task, follow protocol

### Codex CLI
- **Invocation:** `codex`
- **Strengths:** Code generation, code editing, test writing
- **Agent activation:** Read CLAUDE.md, read assigned task, follow protocol

## How to Add an Agent

Any new CLI tool can participate. Requirements:
1. Can read markdown files
2. Can write/edit markdown files
3. Can execute shell commands (for running tests, builds)

Add a new section above with the tool name, status, and capabilities.
