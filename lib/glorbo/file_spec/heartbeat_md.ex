defmodule Glorbo.FileSpec.HeartbeatMd do
  @moduledoc """
  Spec for `companies/<co>/agents/<slug>/HEARTBEAT.md` — the
  agent's heartbeat instructions file (GEP-14). 10 KiB cap on body;
  no frontmatter required in the original spec but `kind:` is added
  by GEP-25 D9 as the discriminator.

  Missing or whitespace-only HEARTBEAT.md is a documented runtime
  case ("skip wake with audit event") — the validator treats the
  file as optional on disk, but if it exists it must carry `kind:`.
  """
  @behaviour Glorbo.FileSpec

  # GEP-14: body cap (we declare it here for validator use).
  @body_cap_bytes 10_240

  @impl true
  def kind, do: "agent-heartbeat/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    String.ends_with?(path, "/HEARTBEAT.md")
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
      title: "HEARTBEAT.md — agent heartbeat prompt",
      summary: """
      Plain markdown prompt fed to the agent on every heartbeat
      wake (GEP-14). Body capped at 10 KiB. Frontmatter carries
      only `kind:` — the file's purpose is the body prose, which
      the dispatch pipeline composes into the prompt.
      """,
      examples: [
        """
        ---
        kind: agent-heartbeat/v1
        ---
        # Heartbeat — ceo

        Every 30 minutes:

        1. Check the inbox.
        2. Skim the audit tail for denials/errors.
        3. Exit cleanly if quiet.
        """
      ]
    }
  end
end
