defmodule GlorboWeb.MCP.Tools.DecideProposal do
  @moduledoc """
  MCP tool: `glorbo.decide_proposal` (GEP-29 wave c.2).

  Flips an existing proposal's status to `approved`, `denied`, or
  `superseded` via GEP-28 D7 outbox indirection — drops a payload
  into `agents/mcp/outbox/proposals/<id>.md`, the Router validates
  and rewrites `proposals/<id>.md`.

  The Router enforces self-approval protection (`approved_by` must
  not equal `proposed_by`). If the proposal was created via MCP
  (`proposed_by: mcp`), decide attempts from the same synthetic
  sender will be rejected — that's the intended guardrail.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Actions.Proposals
  alias GlorboWeb.MCP.Args

  @valid_decisions ~w(approved denied superseded)

  @impl true
  def name, do: "glorbo.decide_proposal"

  @impl true
  def description,
    do: """
    Flip a proposal's status. `decision` ∈ {approved, denied,
    superseded}. Provide `denial_reason` for denied, or
    `superseded_by` for superseded. Goes through the Router's
    outbox pipeline; self-approval is rejected by the Router
    when the original proposed_by matches the flipping sender.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "id" => %{"type" => "string"},
        "decision" => %{"type" => "string", "enum" => @valid_decisions},
        "denial_reason" => %{"type" => ["string", "null"]},
        "superseded_by" => %{"type" => ["string", "null"]}
      },
      "required" => ["company", "id", "decision"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => co, "id" => id, "decision" => decision} = args, context)
      when is_binary(co) and is_binary(id) and is_binary(decision) do
    with :ok <- Args.require_slugs(company: co, id: id),
         :ok <- require_decision(decision) do
      do_call(co, id, decision, args, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, id, decision, args, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()

    opts =
      [actor: mcp_actor(context), base: base]
      |> then(fn opts ->
        if context[:audit], do: Keyword.put(opts, :audit, context[:audit]), else: opts
      end)

    case Proposals.decide(company, id, decision, args, opts) do
      {:ok, %{rel_path: rel_path}} ->
        {:ok,
         %{
           "id" => id,
           "decision" => decision,
           "outbox_path" => rel_path,
           "status" => "submitted"
         }}

      {:error, error} ->
        {:error, {:submit_failed, error}}
    end
  end

  defp require_decision(d) do
    if d in @valid_decisions,
      do: :ok,
      else: {:error, {:invalid_decision, d, @valid_decisions}}
  end

  defp mcp_actor(context), do: "mcp:#{Map.get(context, :client, "unknown")}"
end
