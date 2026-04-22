defmodule Glorbo.CLI.Scaffold.SystemPrompt do
  @moduledoc """
  Canonical system-prompt fragments injected into scaffolded agent.md
  files.

  The **reply contract** (GEP-8 D1) is load-bearing: every dispatched
  invocation ends with Glorbo reading `$GLORBO_REPLY_PATH`. If the
  agent doesn't write there, the invocation fails with
  `:reply_file_missing`. Baking the instruction into every scaffolded
  agent prevents the common "why does my new agent always fail" trap.

  Agents are free to edit this section after scaffolding — the
  template is a starting point, not a runtime contract (GEP-10 D1).
  """

  @doc """
  The reply-file instruction block. Suitable for appending to a
  scaffolded `agent.md` body. Written as markdown so it renders in the
  dashboard and in the CLI's system-prompt view.
  """
  @spec reply_contract() :: String.t()
  def reply_contract do
    """
    ## Reply contract (required)

    When you finish a task, write your final answer to the path in the
    environment variable `$GLORBO_REPLY_PATH`. For example:

    ```sh
    # inside your tool-use loop, somewhere before exit
    echo "Done — here's the summary..." > "$GLORBO_REPLY_PATH"
    ```

    Glorbo reads this file on your exit to show the Director what you
    produced. Without it, your invocation is recorded as
    `:reply_file_missing` and the Director sees nothing. Don't leave
    the file empty; a missing-reply error is how Glorbo knows something
    went wrong.

    You can still write notes, artefacts, and intermediate files into
    your workspace (`/workspace`) — the reply file is just the final
    summary.

    ## Outbox channels (what the Director sees)

    Files in `/outbox/` are routed by path. Anything else is silently
    ignored — don't invent filenames like `<task-id>-shaped.md` and
    expect the Director to see them:

    - `/outbox/<anything>.md` with frontmatter `to: "chat:<channel>"` —
      posts to a chat channel (general, #task-<id>, etc.).
    - `/outbox/comments/<task-id>.md` — appends a comment to the
      existing task. **Use this when asked to shape, rewrite, or
      update a task body** — include the full shaped content here
      and the Director can apply it.
    - `/outbox/tasks/<project>/<id>.md` — files a new task. Set
      `requires_approval: director` in the frontmatter if the task
      should wait for Director approval before any agent picks it up.
    - `/outbox/proposals/<id>.md` — structural proposals (hire, budget,
      new project) queued for Director approval.
    - `/outbox/memory/<type>_<topic>.md` — writes to your agent memory.

    If none of the above fits, include the full content inline in your
    `$GLORBO_REPLY_PATH` reply — the Director reads replies.
    """
  end
end
