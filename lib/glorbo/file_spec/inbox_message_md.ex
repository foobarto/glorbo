defmodule Glorbo.FileSpec.InboxMessageMd do
  @moduledoc """
  Spec for `companies/<co>/agents/<slug>/inbox/<msgid>.md` —
  director- or scheduler-filed inbox messages (GEP-4 / #237
  scheduler). Transient: agents consume them and the inbox
  watcher removes them after dispatch.

  The message body is free-form markdown the agent CLI sees as
  "new instruction"; the frontmatter carries routing metadata.
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r{/agents/[^/]+/inbox/[^/]+\.md\z}

  @impl true
  def kind, do: "inbox-message/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :from],
      optional: [
        :task_id,
        :task_path,
        :scheduled_at,
        :cron,
        :subkind,
        :delivered_at
      ],
      enums: %{},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [
      :kind,
      :from,
      :subkind,
      :task_id,
      :task_path,
      :scheduled_at,
      :cron,
      :delivered_at
    ]
  end

  @impl true
  def docs do
    %{
      title: "inbox/<msgid>.md — agent inbox message",
      summary: """
      Transient message filed into an agent's inbox by the director
      (via Kanban reassignment) or by the scheduler (GEP-24 fired
      dispatch). Body is the prompt addendum the agent CLI sees;
      frontmatter records origin + context. Agents are the sole
      reader and Elixir is the sole writer.
      """,
      examples: [
        """
        ---
        kind: inbox-message/v1
        from: scheduler
        task_path: projects/ops/tasks/nightly-digest.md
        scheduled_at: 2026-04-21T03:00:00Z
        cron: "every morning"
        ---

        Time to run the nightly digest.
        """
      ]
    }
  end
end
