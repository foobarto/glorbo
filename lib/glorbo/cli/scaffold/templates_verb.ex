defmodule Glorbo.CLI.Scaffold.TemplatesVerb do
  @moduledoc """
  `glorbo templates {list,show} [agent|skill]` (GEP-10).

  Thin CLI wrapper around `Glorbo.CLI.Scaffold.TemplateRegistry`.
  Lives under the `Scaffold` namespace because templates exist purely
  to serve scaffolding — the CLI verb is an inspection helper, not a
  separate subsystem.
  """

  alias Glorbo.CLI.Scaffold.TemplateRegistry

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run([]), do: {:templates, 0, help_text()}
  def run(["help" | _]), do: {:templates, 0, help_text()}
  def run(["-h" | _]), do: {:templates, 0, help_text()}
  def run(["--help" | _]), do: {:templates, 0, help_text()}

  def run(["list"]), do: {:templates, 0, list_all()}

  def run(["list", kind_str]) do
    case parse_kind(kind_str) do
      {:ok, kind} -> {:templates, 0, list_kind(kind)}
      :error -> {:templates, 1, "Unknown kind: #{kind_str}\n"}
    end
  end

  def run(["show", kind_str, name]) do
    with {:ok, kind} <- parse_kind(kind_str),
         {:ok, entry} <- TemplateRegistry.fetch(kind, name) do
      content = File.read!(entry.path)
      header = "# source: #{entry.source} · path: #{entry.path}\n\n"
      {:templates, 0, header <> content}
    else
      :error -> {:templates, 1, "Unknown kind: #{kind_str}\n"}
      {:error, :not_found} -> {:templates, 1, "Template not found: #{name}\n"}
    end
  end

  def run(_argv) do
    {:templates, 1,
     "Usage: glorbo templates list [agent|skill]\n" <>
       "       glorbo templates show {agent|skill} <name>\n"}
  end

  defp parse_kind("agent"), do: {:ok, :agent}
  defp parse_kind("agents"), do: {:ok, :agent}
  defp parse_kind("skill"), do: {:ok, :skill}
  defp parse_kind("skills"), do: {:ok, :skill}
  defp parse_kind(_), do: :error

  defp list_all do
    agents = list_kind(:agent)
    skills = list_kind(:skill)
    agents <> "\n" <> skills
  end

  defp list_kind(kind) do
    entries = TemplateRegistry.list(kind)

    header =
      case kind do
        :agent -> "AGENT TEMPLATES\n"
        :skill -> "SKILL TEMPLATES\n"
      end

    if entries == [] do
      header <> "  (none)\n"
    else
      rows =
        Enum.map(entries, fn e ->
          "  #{String.pad_trailing(e.name, 20)} [#{e.source}]"
        end)

      header <> Enum.join(rows, "\n") <> "\n"
    end
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo templates — list + inspect agent/skill templates (GEP-10).

    USAGE
      glorbo templates list [agent|skill]
      glorbo templates show {agent|skill} <name>

    Built-in templates ship with the release at `priv/templates/`.
    User overrides live under `~/.glorbo/templates/{agents,skills}/`
    and shadow built-ins by filename.
    """
  end
end
