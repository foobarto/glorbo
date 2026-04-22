defmodule GlorboWeb.MCP.Tools.CreateAgent do
  @moduledoc """
  MCP tool: `glorbo.create_agent` (GEP-29 wave c.2).

  Scaffolds an agent directory under `companies/<co>/agents/<slug>/`.
  Wraps `Glorbo.CLI.Scaffold.Agent.scaffold/3` so the layout matches
  `glorbo new agent <co>/<slug> [--role …] [--provider …] [--model …]
  [--template …] [--reports-to …]`. Idempotent: scaffolding an
  existing agent returns status="existed".
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.CLI.Scaffold.Agent, as: Scaffold
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.create_agent"

  @impl true
  def description,
    do: """
    Scaffold a new agent in the given company. Creates
    agents/<slug>/ with AGENT.md, SOUL.md, HEARTBEAT.md, and the
    standard inbox/outbox/state/workspace subtree. Optional fields
    (role, provider, model, reports_to, template) mirror the CLI
    flags on `glorbo new agent`. Returns the new path and status.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "slug" => %{"type" => "string"},
        "role" => %{"type" => ["string", "null"]},
        "provider" => %{"type" => ["string", "null"]},
        "model" => %{"type" => ["string", "null"]},
        "reports_to" => %{"type" => ["string", "null"]},
        "template" => %{
          "type" => ["string", "null"],
          "description" => "Role template (e.g. ceo, engineer, writer)"
        }
      },
      "required" => ["company", "slug"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company, "slug" => slug} = args, context)
      when is_binary(company) and is_binary(slug) do
    with :ok <- Args.require_slugs(company: company, slug: slug) do
      do_call(company, slug, args, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, slug, args, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()

    opts =
      [base: base]
      |> maybe_put(:role, args["role"])
      |> maybe_put(:provider, args["provider"])
      |> maybe_put(:model, args["model"])
      |> maybe_put(:reports_to, args["reports_to"])
      |> maybe_put(:template, args["template"])

    case Scaffold.scaffold(company, slug, opts) do
      {:new_agent, 0, msg} ->
        status = if msg =~ "already exists", do: "existed", else: "created"

        {:ok,
         %{
           "company" => company,
           "slug" => slug,
           "status" => status,
           "message" => String.trim(msg)
         }}

      {:new_agent, _, msg} ->
        {:error, {:scaffold_failed, String.trim(msg)}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
