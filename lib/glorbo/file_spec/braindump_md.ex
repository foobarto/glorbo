defmodule Glorbo.FileSpec.BraindumpMd do
  @moduledoc """
  Spec for `companies/<co>/braindump/<ts>.md` — director brain-dump
  entries captured via the dedicated UI (T1-E). Filename is an
  ISO-like timestamp slug; body is free-form markdown.
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r{/braindump/[^/]+\.md\z}

  @impl true
  def kind, do: "braindump/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :created_at],
      optional: [:title, :tags, :author],
      enums: %{},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order, do: [:kind, :created_at, :author, :title, :tags]

  @impl true
  def docs do
    %{
      title: "braindump/<ts>.md — director brain dump",
      summary: """
      Director's brain-dump entries captured via the dedicated UI.
      Filename is typically `YYYY-MM-DD-HHMMSS.md` or a slugified
      title. Body is free-form markdown — bullets, thoughts, links,
      screenshots referenced by path.
      """,
      examples: [
        """
        ---
        kind: braindump/v1
        created_at: 2026-04-21T10:30:00Z
        title: Rename tweaks drawer? sidebar is getting crowded
        author: director
        tags: [ui, sidebar, m6]
        ---
        The sidebar has ten rows now. Maybe fold Brain dump into a
        top-bar shortcut like /chat has.
        """
      ]
    }
  end
end
