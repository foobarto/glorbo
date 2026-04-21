defmodule Glorbo.FileSpec.ChannelLogMd do
  @moduledoc """
  Spec for `companies/<co>/channels/<channel>.md` — rolling
  append-only chat log (M4-ish, extended by #238 log rotation).
  Frontmatter carries `kind:` + optional roll-over pointers; the
  body is a sequence of message records separated by delimiters
  the parser understands.

  Archived rolled-out logs live next to the active one as
  `<channel>.YYYY-MM.md` — same spec, same `kind:`.
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r{/channels/[^/]+\.md\z}

  @impl true
  def kind, do: "channel-log/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :channel],
      optional: [:created_at, :rotated_from, :archive_of],
      enums: %{},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [:kind, :channel, :created_at, :rotated_from, :archive_of]
  end

  @impl true
  def docs do
    %{
      title: "channels/<channel>.md — rolling chat log",
      summary: """
      Append-only chat channel. Body carries a sequence of
      messages in the log format consumed by
      `GlorboWeb.ChannelLive`. Rotation spawns sibling archives
      under `<channel>.YYYY-MM.md` that link back via
      `archive_of:` / `rotated_from:`.
      """,
      examples: [
        """
        ---
        kind: channel-log/v1
        channel: general
        created_at: 2026-04-16T00:00:00Z
        ---
        # #general

        Company-wide channel. Append-only; Elixir is sole writer.
        """
      ]
    }
  end
end
