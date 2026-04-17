defmodule Glorbo.Agent.FileLayout do
  @moduledoc """
  Canonical file paths inside an agent's directory.

  User-facing convention (2026-04-17): all agent-consumed markdown files
  are ALLCAPS — `AGENT.md`, `HEARTBEAT.md`, `SKILLS.md` (future). This
  module centralises the lookup so callers never branch on the casing
  themselves.

  ## Soft migration from `agent.md`

  Existing installs carry `agent.md` (lowercase). We read either shape —
  `AGENT.md` preferred, `agent.md` fallback — but **write only `AGENT.md`**
  so new/updated files rehome onto the new convention. Once the whole
  fleet is on `AGENT.md`, the fallback can be deleted without a
  compatibility shim.
  """

  @agent_md_candidates ["AGENT.md", "agent.md"]
  @heartbeat_md "HEARTBEAT.md"

  @doc """
  Resolve the agent frontmatter file inside `agent_dir`.

  Returns the path to `AGENT.md` if present, falling back to `agent.md`
  if only the legacy name exists. Returns the canonical `AGENT.md` path
  even when neither file exists — callers use `File.read/1` against the
  result and handle ENOENT themselves.
  """
  @spec agent_md(Path.t()) :: Path.t()
  def agent_md(agent_dir) when is_binary(agent_dir) do
    Enum.find_value(@agent_md_candidates, Path.join(agent_dir, "AGENT.md"), fn name ->
      path = Path.join(agent_dir, name)
      if File.exists?(path), do: path, else: false
    end)
  end

  @doc """
  Canonical (always-ALLCAPS) path for writing a new agent frontmatter
  file. Use this for scaffolders and tests.
  """
  @spec agent_md_canonical(Path.t()) :: Path.t()
  def agent_md_canonical(agent_dir), do: Path.join(agent_dir, "AGENT.md")

  @doc "Canonical heartbeat instruction file path for the given agent dir."
  @spec heartbeat_md(Path.t()) :: Path.t()
  def heartbeat_md(agent_dir), do: Path.join(agent_dir, @heartbeat_md)

  @doc "List of filenames that count as an agent's frontmatter file."
  @spec agent_md_candidates() :: [String.t()]
  def agent_md_candidates, do: @agent_md_candidates
end
