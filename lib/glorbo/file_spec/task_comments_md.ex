defmodule Glorbo.FileSpec.TaskCommentsMd do
  @moduledoc """
  Spec for `companies/<co>/projects/<project>/tasks/<task-id>.comments.md` —
  sibling append-only comment thread for a task (GEP-30 D8).

  Task files themselves carry frontmatter + a director-authored body
  (the agent prompt); the thread lives in a separate file so the
  task file stays diff-clean while the Kanban drawer / TaskLive
  page render discussion inline.

  **Path shape:** `<task-id>.comments.md` — the base name matches the
  adjacent task file without the trailing `.md`. Body format matches
  the channel log: `## <iso-ts> | <author>\\n<body>` entries in
  chronological order.

  **No rotation.** Per D14, comment threads never rotate — they stay
  bounded by the task lifecycle and tend to be shorter than a
  channel log. If a thread grows unwieldy that's a signal the
  discussion should move to a channel instead.
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r{/projects/[^/]+/tasks/[^/]+\.comments\.md\z}

  @impl true
  def kind, do: "task-comments/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :task_id],
      optional: [:created_at],
      enums: %{},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [:kind, :task_id, :created_at]
  end

  @impl true
  def docs do
    %{
      title: "<task-id>.comments.md — task comment thread",
      summary: """
      Sibling file to a task markdown carrying the discussion
      thread for that task. Body is an append-only sequence of
      `## <iso-ts> | <author>` entries identical to channel logs.
      Never rotates (GEP-30 D14); threads are bounded by the task
      lifecycle.
      """,
      examples: [
        """
        ---
        kind: task-comments/v1
        task_id: blog-2
        created_at: 2026-04-22T10:00:00Z
        ---
        ## 2026-04-22T10:00:00Z | director
        ceo — please draft against the launch outline.

        ## 2026-04-22T10:12:00Z | ceo
        on it. I'll ping here when the draft lands.
        """
      ]
    }
  end
end
