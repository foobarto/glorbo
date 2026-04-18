defmodule Glorbo.CLI.Scaffold.TemplateRegistry do
  @moduledoc """
  Discovery layer for agent + skill templates (GEP-10).

  Templates live at `priv/templates/{agents,skills}/*.md` inside the
  release, with user overrides at `~/.glorbo/templates/{agents,skills}/`.
  A user file shadows the built-in entry by filename (GEP-10 D5).

  Two kinds:

    * `:agent` — produces an AGENT.md from
      `Glorbo.CLI.Scaffold.Agent`.
    * `:skill` — produces a skill markdown file from
      `Glorbo.CLI.Scaffold.Skill`.

  Entry shape:

      %{
        name: "engineer",
        kind: :agent,
        path: "/.../priv/templates/agents/engineer.md",
        source: :builtin | :user
      }
  """

  @type kind :: :agent | :skill
  @type source :: :builtin | :user

  @type entry :: %{
          name: String.t(),
          kind: kind(),
          path: Path.t(),
          source: source()
        }

  @name_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @doc """
  List all known templates of the given kind. User overrides shadow
  built-ins by filename.
  """
  @spec list(kind()) :: [entry()]
  def list(kind) when kind in [:agent, :skill] do
    builtins = scan(builtin_dir(kind), kind, :builtin)
    users = scan(user_dir(kind), kind, :user)

    # User entries first so Enum.uniq_by/2 keeps them over built-ins of
    # the same name (GEP-10 D5: user overrides shadow by filename).
    (users ++ builtins)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Look up a single template by name. Returns `{:ok, entry}` or
  `{:error, :not_found}`.
  """
  @spec fetch(kind(), String.t()) :: {:ok, entry()} | {:error, :not_found}
  def fetch(kind, name) when kind in [:agent, :skill] and is_binary(name) do
    case Enum.find(list(kind), &(&1.name == name)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc false
  @spec builtin_dir(kind()) :: Path.t()
  def builtin_dir(:agent), do: Application.app_dir(:glorbo, "priv/templates/agents")
  def builtin_dir(:skill), do: Application.app_dir(:glorbo, "priv/templates/skills")

  @doc false
  @spec user_dir(kind()) :: Path.t()
  def user_dir(:agent), do: Path.expand("~/.glorbo/templates/agents")
  def user_dir(:skill), do: Path.expand("~/.glorbo/templates/skills")

  defp scan(dir, kind, source) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.rootname(&1, ".md"))
        |> Enum.filter(&Regex.match?(@name_regex, &1))
        |> Enum.map(fn name ->
          %{name: name, kind: kind, path: Path.join(dir, "#{name}.md"), source: source}
        end)

      {:error, _} ->
        []
    end
  end
end
