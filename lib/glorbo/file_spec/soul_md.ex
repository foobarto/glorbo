defmodule Glorbo.FileSpec.SoulMd do
  @moduledoc """
  Spec for `companies/<co>/agents/<slug>/SOUL.md` — the agent's
  personality/voice file, composed into the prompt before the
  task body. Plain markdown with `kind:` frontmatter.
  """
  @behaviour Glorbo.FileSpec

  @body_cap_bytes 10_240

  @impl true
  def kind, do: "agent-soul/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    String.ends_with?(path, "/SOUL.md")
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind],
      optional: [],
      enums: %{},
      patterns: %{},
      caps: %{body: @body_cap_bytes}
    }
  end

  @impl true
  def canonical_key_order, do: [:kind]

  @impl true
  def docs do
    %{
      title: "SOUL.md — agent voice",
      summary: """
      Agent's persistent voice / personality / stylistic preferences.
      Loaded once and prepended to every prompt. 10 KiB cap.
      """,
      examples: [
        """
        ---
        kind: agent-soul/v1
        ---
        I am precise, direct, and I do not hedge. I fix bugs, I do
        not explain them. I write Elixir like a Phoenix contributor.
        """
      ]
    }
  end
end
