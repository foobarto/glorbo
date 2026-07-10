defmodule Glorbo.Actions.Proposals do
  @moduledoc """
  Canonical submission seam for proposal outbox mutations.

  MCP-originated proposals still pass through the company Router under the
  synthetic `mcp` sender, but frontend modules never create or overwrite the
  outbox payload themselves.
  """

  alias Glorbo.Actions.Support
  alias Glorbo.Company.AuditLog
  alias Glorbo.Filesystem.AgentWritableFile
  alias Glorbo.Filesystem.FrontmatterWriter

  @mcp_sender "mcp"
  @valid_decisions ~w(approved denied superseded)

  @spec submit(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{rel_path: String.t()}} | {:error, term()}
  def submit(company, id, subtype, body, opts \\ [])
      when is_binary(company) and is_binary(id) and is_binary(subtype) and is_binary(body) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- Support.validate_slug(company, :company),
         :ok <- Support.validate_slug(id, :proposal),
         :ok <- validate_nonempty(subtype, :subtype),
         :ok <- validate_nonempty(body, :body),
         :ok <- ensure_company_exists(base, company),
         {path, rel_path} <- outbox_path(base, company, id),
         :ok <- AgentWritableFile.create_exclusive(path, proposal_body(id, subtype, body)),
         :ok <- emit_submit_audit(audit, company, id, subtype, actor) do
      {:ok, %{rel_path: rel_path}}
    end
  end

  @spec decide(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, %{rel_path: String.t()}} | {:error, term()}
  def decide(company, id, decision, params, opts \\ [])
      when is_binary(company) and is_binary(id) and is_binary(decision) and is_map(params) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- Support.validate_slug(company, :company),
         :ok <- Support.validate_slug(id, :proposal),
         :ok <- validate_decision(decision),
         :ok <- ensure_proposal_exists(base, company, id),
         {path, rel_path} <- outbox_path(base, company, id),
         :ok <- AgentWritableFile.create_exclusive(path, decision_body(id, decision, params)),
         :ok <- emit_decision_audit(audit, company, id, decision, actor) do
      {:ok, %{rel_path: rel_path}}
    end
  end

  defp outbox_path(base, company, id) do
    rel_path = Path.join(["agents", @mcp_sender, "outbox", "proposals", "#{id}.md"])
    {Path.join([base, "companies", company, rel_path]), rel_path}
  end

  defp ensure_company_exists(base, company) do
    case File.lstat(Path.join([base, "companies", company])) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _ -> {:error, {:company_not_found, company}}
    end
  end

  defp ensure_proposal_exists(base, company, id) do
    path = Path.join([base, "companies", company, "proposals", "#{id}.md"])

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      _ -> {:error, {:proposal_not_found, id}}
    end
  end

  defp validate_nonempty(value, field) do
    if String.trim(value) == "", do: {:error, {:empty, field}}, else: :ok
  end

  defp validate_decision(decision) do
    if decision in @valid_decisions,
      do: :ok,
      else: {:error, {:invalid_decision, decision, @valid_decisions}}
  end

  defp proposal_body(id, subtype, body) do
    """
    ---
    kind: proposal/v1
    id: #{id}
    subtype: #{FrontmatterWriter.yaml_scalar(subtype)}
    status: pending-approval
    requires_approval: director
    ---

    #{String.trim_trailing(body)}
    """
  end

  defp decision_body(id, decision, params) do
    extras = decision_extras(decision, params)

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

  defp decision_extras("denied", params) do
    case nilify(params["denial_reason"]) do
      nil -> ""
      reason -> "denial_reason: #{FrontmatterWriter.yaml_scalar(reason)}\n"
    end
  end

  defp decision_extras("superseded", params) do
    case nilify(params["superseded_by"]) do
      nil -> ""
      id -> "superseded_by: #{FrontmatterWriter.yaml_scalar(id)}\n"
    end
  end

  defp decision_extras(_decision, _params), do: ""

  defp nilify(value) when value in [nil, ""], do: nil
  defp nilify(value) when is_binary(value), do: value
  defp nilify(_value), do: nil

  defp emit_submit_audit(audit, company, id, subtype, actor) do
    Support.append_audit(audit, company, %{
      actor: actor,
      action: "proposal.submit",
      target: "proposals/#{id}.md",
      subtype: subtype
    })
  end

  defp emit_decision_audit(audit, company, id, decision, actor) do
    Support.append_audit(audit, company, %{
      actor: actor,
      action: "proposal.decision_submit",
      target: "proposals/#{id}.md",
      decision: decision
    })
  end
end
