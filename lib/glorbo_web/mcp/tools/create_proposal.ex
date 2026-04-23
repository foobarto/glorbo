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

  alias Glorbo.Filesystem.FrontmatterWriter
  alias GlorboWeb.MCP.Args

  @mcp_sender "mcp"

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

    outbox_dir =
      Path.join([base, "companies", company, "agents", @mcp_sender, "outbox", "proposals"])

    with :ok <- ensure_company_exists(base, company),
         :ok <- File.mkdir_p(outbox_dir),
         path = Path.join(outbox_dir, "#{id}.md"),
         :ok <- FrontmatterWriter.atomic_write(path, proposal_body(id, subtype, body)) do
      {:ok,
       %{
         "id" => id,
         "subtype" => subtype,
         "outbox_path" => Path.relative_to(path, Path.join([base, "companies", company])),
         "status" => "submitted"
       }}
    else
      {:error, err} -> {:error, {:submit_failed, err}}
    end
  end

  defp ensure_company_exists(base, company) do
    if File.dir?(Path.join([base, "companies", company])),
      do: :ok,
      else: {:error, {:company_not_found, company}}
  end

  defp proposal_body(id, subtype, body) do
    """
    ---
    kind: proposal/v1
    id: #{id}
    subtype: #{subtype}
    status: pending-approval
    requires_approval: director
    ---

    #{String.trim_trailing(body)}
    """
  end

  defp require_nonempty(s, field) when is_binary(s) do
    if String.trim(s) == "", do: {:error, {:empty, field}}, else: :ok
  end
end
