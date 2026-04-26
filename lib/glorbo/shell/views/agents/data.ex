defmodule Glorbo.Shell.Views.Agents.Data do
  @moduledoc """
  GEP-37 Phase 3d — read path for the Agents view.

  Walks `<base>/companies/<co>/agents/*/AGENT.md` (or legacy
  `agent.md`) and returns a slim row per agent. Mirrors the
  light slice of `CompanyLive.load_agents/3` — the heavier
  budget / last-wake / pill-status columns require Repo +
  audit-map reads and ship in Phase 3e.

  Each row carries:

    * `:slug` — agent dir name.
    * `:name` — `name:` from frontmatter, falls back to slug.
    * `:role` — `role:` from frontmatter, falls back to `"—"`.
    * `:provider` — `provider:` from frontmatter or `"—"`.
    * `:model` — `model:` from frontmatter or empty string.
    * `:network` — `network:` from frontmatter, defaults to
      `"loopback"` matching the LV's behaviour.
    * `:reports_to` — `reports_to:` from frontmatter or nil.
  """

  alias Glorbo.Filesystem.Frontmatter

  @typedoc "Slim per-agent row for the TUI Agents view."
  @type agent_row :: %{
          slug: String.t(),
          name: String.t(),
          role: String.t(),
          provider: String.t(),
          model: String.t(),
          network: String.t(),
          reports_to: String.t() | nil
        }

  @spec load_agents(Path.t(), String.t()) :: [agent_row()]
  def load_agents(base, company) do
    agents_dir = Path.join([base, "companies", company, "agents"])

    case File.ls(agents_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.filter(fn slug ->
          # Hide `.archive/` and other dotfiles — retired agents
          # live elsewhere.
          not String.starts_with?(slug, ".") and File.dir?(Path.join(agents_dir, slug))
        end)
        |> Enum.flat_map(&load_agent(agents_dir, &1))

      _ ->
        []
    end
  end

  defp load_agent(agents_dir, slug) do
    agent_path = Path.join(agents_dir, slug)

    case read_agent_md(agent_path) do
      nil ->
        # Hide agents whose AGENT.md is missing entirely — they're
        # not bootable. The LV behaves the same way.
        []

      meta ->
        [
          %{
            slug: slug,
            name: meta["name"] || slug,
            role: meta["role"] || "—",
            provider: meta["provider"] || "—",
            model: meta["model"] || "",
            network: meta["network"] || "loopback",
            reports_to: meta["reports_to"]
          }
        ]
    end
  end

  defp read_agent_md(agent_path) do
    # AGENT.md is canonical; agent.md is the legacy lowercase form
    # still tolerated per the wave-30-era reindex pattern.
    paths = [Path.join(agent_path, "AGENT.md"), Path.join(agent_path, "agent.md")]

    case Enum.find_value(paths, &maybe_read_md/1) do
      nil -> nil
      {:ok, meta} -> meta
    end
  end

  defp maybe_read_md(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, meta, _body} <- Frontmatter.parse(content) do
      {:ok, meta}
    else
      _ -> nil
    end
  end
end
