defmodule GlorboWeb.MCP.Tools.CreateCompany do
  @moduledoc """
  MCP tool: `glorbo.create_company` (GEP-29 wave c.2).

  Scaffolds a new company directory under `companies/<slug>/`.
  Wraps `Glorbo.CLI.Scaffold.Company.scaffold/2` so the layout +
  audit shape matches the CLI `glorbo new company <slug>` path
  exactly. Idempotent: scaffolding an existing slug returns a
  short-circuit success.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.CLI.Scaffold.Company, as: Scaffold
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.create_company"

  @impl true
  def description,
    do: """
    Scaffold a new company directory. Creates companies/<slug>/
    with the canonical subtree (agents/, projects/, channels/,
    audit/, proposals/) and a minimal company.md. Returns the
    slug and a status string. If the company already exists the
    tool returns success with status="existed" — this is
    intentionally idempotent.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "slug" => %{"type" => "string", "description" => "Company slug"}
      },
      "required" => ["slug"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"slug" => slug}, context) when is_binary(slug) do
    with :ok <- Args.require_slug(slug, :slug) do
      do_call(slug, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_slug}

  defp do_call(slug, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()

    case Scaffold.scaffold(slug, base: base) do
      {:new_company, 0, msg} ->
        status = if msg =~ "already exists", do: "existed", else: "created"
        {:ok, %{"slug" => slug, "status" => status, "message" => String.trim(msg)}}

      {:new_company, _, msg} ->
        {:error, {:scaffold_failed, String.trim(msg)}}
    end
  end
end
