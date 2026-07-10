defmodule GlorboWeb.MCP.Tools.CreateProposal do
  @moduledoc """
  MCP tool: `glorbo.create_proposal` (GEP-29 wave c.2).

  Files a new `proposal/v1` via the GEP-28 D7 outbox-indirection
  path: writes `agents/mcp/outbox/proposals/<id>.md` and lets the
  company Router validate + move it to `proposals/<id>.md`. The
  Router stamps `proposed_by: mcp` (forge-proof; matches the
  synthetic outbox sender).

  The `mcp` agent dir is created on demand if absent — it's a
  Router-visible sender slug, not a live agent process.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Actions.Proposals
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.create_proposal"

  @impl true
  def description,
    do: """
    Submit a new proposal for Director review (GEP-28). Writes the
    proposal file via the synthetic `agents/mcp/outbox/proposals/`
    directory so the company Router validates + moves it the same
    way it does for agent-sourced proposals. Subtype must be one
    of the known kinds (hire, fire, budget, project, custom) or a
    custom string. Body is the markdown rationale; keep it short.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "id" => %{"type" => "string", "description" => "Proposal id (filename stem)"},
        "subtype" => %{"type" => "string"},
        "body" => %{"type" => "string"}
      },
      "required" => ["company", "id", "subtype", "body"],
      "additionalProperties" => false
    }

  @impl true
  def call(
        %{"company" => co, "id" => id, "subtype" => subtype, "body" => body},
        context
      )
      when is_binary(co) and is_binary(id) and is_binary(subtype) and is_binary(body) do
    with :ok <- Args.require_slugs(company: co, id: id),
         :ok <- require_nonempty(subtype, :subtype),
         :ok <- require_nonempty(body, :body) do
      do_call(co, id, subtype, body, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, id, subtype, body, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()

    opts =
      [actor: mcp_actor(context), base: base]
      |> then(fn opts ->
        if context[:audit], do: Keyword.put(opts, :audit, context[:audit]), else: opts
      end)

    case Proposals.submit(company, id, subtype, body, opts) do
      {:ok, %{rel_path: rel_path}} ->
        {:ok,
         %{
           "id" => id,
           "subtype" => subtype,
           "outbox_path" => rel_path,
           "status" => "submitted"
         }}

      {:error, error} ->
        {:error, {:submit_failed, error}}
    end
  end

  defp require_nonempty(s, field) when is_binary(s) do
    if String.trim(s) == "", do: {:error, {:empty, field}}, else: :ok
  end

  defp mcp_actor(context), do: "mcp:#{Map.get(context, :client, "unknown")}"
end
