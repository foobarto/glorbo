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

  alias Glorbo.Filesystem.FrontmatterWriter
  alias GlorboWeb.MCP.Args

  @mcp_sender "mcp"
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

    outbox_dir =
      Path.join([base, "companies", company, "agents", @mcp_sender, "outbox", "proposals"])

    with :ok <- ensure_proposal_exists(base, company, id),
         :ok <- File.mkdir_p(outbox_dir),
         path = Path.join(outbox_dir, "#{id}.md"),
         :ok <- FrontmatterWriter.atomic_write(path, flip_body(id, decision, args)) do
      {:ok,
       %{
         "id" => id,
         "decision" => decision,
         "outbox_path" => Path.relative_to(path, Path.join([base, "companies", company])),
         "status" => "submitted"
       }}
    else
      {:error, err} -> {:error, {:submit_failed, err}}
    end
  end

  defp ensure_proposal_exists(base, company, id) do
    path = Path.join([base, "companies", company, "proposals", "#{id}.md"])
    if File.exists?(path), do: :ok, else: {:error, {:proposal_not_found, id}}
  end

  defp require_decision(d) do
    if d in @valid_decisions,
      do: :ok,
      else: {:error, {:invalid_decision, d, @valid_decisions}}
  end

  defp flip_body(id, decision, args) do
    denial = nilify(args["denial_reason"])
    superseded = nilify(args["superseded_by"])

    extras =
      case {decision, denial, superseded} do
        {"denied", r, _} when is_binary(r) -> "denial_reason: #{yaml_escape(r)}\n"
        {"superseded", _, s} when is_binary(s) -> "superseded_by: #{s}\n"
        _ -> ""
      end

    # NOTE: The subtype field is required by the Router for the
    # outbox classifier; we don't know it here without a round-trip
    # read, so we trust the Router's `flip_proposal/4` path which
    # preserves the existing subtype from the on-disk file. A bogus
    # placeholder here is fine — the Router overwrites it.
    """
    ---
    kind: proposal/v1
    id: #{id}
    subtype: flip
    status: #{decision}
    #{extras}---

    Flip submitted by MCP.
    """
  end

  defp yaml_escape(s) do
    if s =~ ~r/[:\[\]{}#,&*!|>'"%@`\s]/ do
      escaped = String.replace(s, "\"", "\\\"")
      "\"" <> escaped <> "\""
    else
      s
    end
  end

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(v) when is_binary(v), do: v
  defp nilify(_), do: nil
end
