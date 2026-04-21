defmodule Glorbo.FileSpec.MemoryIndexMd do
  @moduledoc """
  Spec for `companies/<co>/agents/<slug>/memory/MEMORY.md` — the
  agent's memory index (GEP-21). Required: one line per memory
  file (≤150 chars) in `- [Name](file.md) — hook` shape. Always
  loaded into the system prompt.

  The index itself has frontmatter for `kind:` but the body is
  line-oriented markdown the validator inspects line-by-line.
  """
  @behaviour Glorbo.FileSpec

  @max_line_bytes 150

  @impl true
  def kind, do: "agent-memory-index/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    String.ends_with?(path, "/memory/MEMORY.md")
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind],
      optional: [],
      enums: %{},
      patterns: %{},
      caps: %{line: @max_line_bytes}
    }
  end

  @impl true
  def canonical_key_order, do: [:kind]

  @impl true
  def docs do
    %{
      title: "MEMORY.md — memory index",
      summary: """
      Per-agent memory index. Each body line is
      `- [Name](<file>.md) — short hook`; ≤150 chars per line.
      Loaded into the prompt on every wake before the individual
      memory files.
      """,
      examples: [
        """
        ---
        kind: agent-memory-index/v1
        ---
        - [Director role](user_role.md) — Apache-2.0, Elixir preferred
        - [No emojis in reports](feedback_no_emojis.md) — plain text
        """
      ]
    }
  end
end
