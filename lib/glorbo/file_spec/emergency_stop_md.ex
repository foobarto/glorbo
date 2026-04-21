defmodule Glorbo.FileSpec.EmergencyStopMd do
  @moduledoc """
  Spec for `companies/<co>/state/emergency-stop.md` — the
  company-level emergency-stop sentinel (T2-C). Presence of the
  file halts every dispatch for that company until it is removed
  (via `clear/2` or manual deletion).
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r{/state/emergency-stop\.md\z}

  @impl true
  def kind, do: "emergency-stop/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :engaged_by, :engaged_at],
      optional: [:reason],
      enums: %{},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order, do: [:kind, :engaged_by, :engaged_at, :reason]

  @impl true
  def docs do
    %{
      title: "emergency-stop.md — company-level dispatch halt",
      summary: """
      Written by `Glorbo.EmergencyStop.engage/2` and removed by
      `clear/2`. While present, no agent in this company is
      dispatched; the sentinel is queried on every wake via
      `engaged?/2`. Company-scoped (not agent-scoped).
      """,
      examples: [
        """
        ---
        kind: emergency-stop/v1
        engaged_by: director
        engaged_at: 2026-04-21T11:00:00Z
        reason: Budget blew past cap, pausing while we investigate
        ---

        # Emergency stop engaged

        All agent dispatch for this company is halted. Delete this
        file — or click "Clear" in the UI — to resume normal
        operation.
        """
      ]
    }
  end
end
