defmodule Glorbo.Agent.FileLayout do
  @moduledoc """
  Canonical file paths inside an agent's directory.

  User-facing convention (GEP-15): all agent-consumed markdown files
  are ALLCAPS — `AGENT.md`, `HEARTBEAT.md`, `SKILLS.md` (future). This
  module centralises the lookup so callers never branch on the casing
  themselves.
  """

  @agent_md "AGENT.md"
  @heartbeat_md "HEARTBEAT.md"

  @doc """
  Canonical path to an agent's frontmatter file. Callers use
  `File.read/1` against the result and handle ENOENT themselves.
  """
  @spec agent_md(Path.t()) :: Path.t()
  def agent_md(agent_dir) when is_binary(agent_dir), do: Path.join(agent_dir, @agent_md)

  @doc """
  Alias for `agent_md/1` — kept so existing scaffolders that asked for
  the "canonical" write path keep reading cleanly. Both return the same
  ALLCAPS path now that the soft-migration lowercase fallback is gone.
  """
  @spec agent_md_canonical(Path.t()) :: Path.t()
  def agent_md_canonical(agent_dir), do: agent_md(agent_dir)

  @doc "Canonical heartbeat instruction file path for the given agent dir."
  @spec heartbeat_md(Path.t()) :: Path.t()
  def heartbeat_md(agent_dir), do: Path.join(agent_dir, @heartbeat_md)
end
