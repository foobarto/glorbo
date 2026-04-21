defmodule Glorbo.FileSpec.PathRequestMd do
  @moduledoc """
  Spec for `companies/<co>/agents/<slug>/outbox/path-request-<task_id>.md`
  — an agent's request for temporary sandbox access to an external path
  (GEP-27). Written by the agent to its outbox; parsed and routed by the
  Router to `PathRequestGate`. Cleared on approval or denial.
  """
  @behaviour Glorbo.FileSpec

  @path_request_regex ~r{/outbox/path-request-[a-z0-9][a-z0-9-]*\.md\z}

  @impl true
  def kind, do: "path-request/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_request_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :task_id, :paths, :reason],
      optional: [],
      enums: %{},
      patterns: %{},
      caps: %{reason: 500}
    }
  end

  @impl true
  def canonical_key_order do
    [:kind, :task_id, :paths, :reason]
  end

  @impl true
  def docs do
    %{
      title: "path-request-<task_id>.md — sandbox path request",
      summary: """
      Agent-written request for temporary access to an external host
      path during a specific task dispatch. The `paths` list contains
      maps with `path` (absolute host path) and `mode` (`read` or
      `write`). The director approves via `PathRequestGate` and can
      downgrade or trim paths before granting. Access is task-scoped
      and revoked automatically after dispatch completes (GEP-27).
      """,
      examples: [
        """
        ---
        kind: path-request/v1
        task_id: deploy-01
        paths:
          - path: /etc/myapp/config.yaml
            mode: read
        reason: Need to read deployment config for the release task
        ---

        The config contains the database host for the staging environment.
        """
      ]
    }
  end
end
