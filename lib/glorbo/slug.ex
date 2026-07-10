defmodule Glorbo.Slug do
  @moduledoc """
  Shared slug-shape validator (WR-02).

  A slug is how the filesystem-source-of-truth layer (GEP-3) names
  companies, agents, channels, projects, and every other user-visible
  identifier that becomes a path component under `~/.glorbo/`. Every
  user-controlled string that will be joined into a path MUST pass
  `valid?/1` before `Path.join` touches it — a `..` or `/` would
  escape the agent's sandbox mount view and the kernel-layer
  enforcement would leak.

  This module lives in `lib/glorbo/` deliberately. Earlier revisions
  kept it in `lib/glorbo_web/` under the web-namespaced name, which forced the
  domain layer (`Router`, `AgentServer`, `ACLMapper`, `TaskScheduler`,
  `company_boot`) to reach up into the web layer — a dependency-
  direction smell codex + opencode reviews both flagged. The move is
  atomic per the pre-1.0 "no kid gloves on breaking changes" rule.

  Entity-specific validation is available through `valid?/2`. Agent slugs
  intentionally allow underscores; company/project/channel slugs retain the
  generic hyphen-only URL shape.
  """

  @slug_re ~r/\A[a-z0-9-]+\z/
  @agent_slug_re ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @doc """
  Returns `true` iff the value is a binary that matches
  `~r/\\A[a-z0-9-]+\\z/`. Everything else (nil, non-binary, empty
  string, any string with uppercase / whitespace / `..` / `/`) is
  rejected.
  """
  @spec valid?(term()) :: boolean()
  def valid?(s) when is_binary(s), do: Regex.match?(@slug_re, s)
  def valid?(_), do: false

  @doc "Validate an identifier using the rules for its entity kind."
  @spec valid?(term(), atom()) :: boolean()
  def valid?(s, :agent) when is_binary(s), do: Regex.match?(@agent_slug_re, s)
  def valid?(s, _kind), do: valid?(s)
end
