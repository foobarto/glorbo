defmodule Glorbo.CLI.Scaffold.Renderer do
  @moduledoc """
  Template renderer for GEP-10 agent and skill templates.

  Dead-simple `{{ var }}` substitution — no EEx, no mustache dep, no
  conditionals. The 8 supported variables (GEP-10 D7) are the only
  customisation point; anything more specific is a post-scaffold hand
  edit.

  Placeholders tolerate optional whitespace inside the braces, so both
  `{{name}}` and `{{ name }}` resolve to the same substitution.
  """

  @supported_vars ~w(name slug company company_upper reports_to provider model date)a

  @type vars :: %{
          required(:name) => String.t(),
          required(:slug) => String.t(),
          required(:company) => String.t(),
          required(:company_upper) => String.t(),
          required(:reports_to) => String.t(),
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:date) => String.t()
        }

  @doc """
  The closed set of variable names every template can reference.
  """
  @spec supported_vars() :: [atom()]
  def supported_vars, do: @supported_vars

  @doc """
  Render a template string with the given variable map. Unknown
  placeholders pass through untouched — Director can hand-edit the
  result if a template references a variable we don't provide.
  """
  @spec render(String.t(), vars()) :: String.t()
  def render(template, vars) when is_binary(template) and is_map(vars) do
    Enum.reduce(@supported_vars, template, fn key, acc ->
      value = Map.fetch!(vars, key) |> to_string()
      String.replace(acc, ~r/\{\{\s*#{key}\s*\}\}/, value)
    end)
  end

  @doc """
  Build the standard variable map from CLI inputs + defaults.
  """
  @spec build_vars(keyword()) :: vars()
  def build_vars(opts) do
    slug = Keyword.fetch!(opts, :slug)
    company = Keyword.fetch!(opts, :company)

    %{
      name: Keyword.get(opts, :name) || String.upcase(slug),
      slug: slug,
      company: company,
      company_upper: String.upcase(company),
      reports_to: Keyword.get(opts, :reports_to) || "director",
      provider: Keyword.get(opts, :provider) || "claude-code",
      model: Keyword.get(opts, :model) || "claude-sonnet-4-5",
      date: Keyword.get(opts, :date) || Date.utc_today() |> Date.to_iso8601()
    }
  end
end
