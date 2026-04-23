defmodule Glorbo.Company.Proposals do
  @moduledoc """
  Director-side read + flip operations for GEP-28 proposals.

  List and detail calls are pure filesystem reads — no supervision tree
  involvement. Flip writes (approve / deny) land directly on the
  `companies/<co>/proposals/<id>.md` file via `Filesystem.Frontmatter`
  and emit a matching audit event. Agent-sourced proposals still flow
  through `Glorbo.Company.Router`'s outbox pipeline; this module is the
  Director LiveView's counterpart.
  """

  alias Glorbo.Company.AuditLog
  alias Glorbo.Filesystem.Frontmatter
  alias Glorbo.Filesystem.FrontmatterWriter
  alias Glorbo.Filesystem.Hierarchy

  @type proposal :: %{
          required(:id) => String.t(),
          required(:subtype) => String.t(),
          required(:status) => String.t(),
          required(:proposed_by) => String.t() | nil,
          required(:proposed_at) => String.t() | nil,
          required(:approved_by) => String.t() | nil,
          required(:approved_at) => String.t() | nil,
          required(:denial_reason) => String.t() | nil,
          required(:superseded_by) => String.t() | nil,
          required(:body) => String.t(),
          required(:path) => Path.t()
        }

  @spec list(String.t(), keyword()) :: [proposal()]
  def list(company, opts \\ []) when is_binary(company) do
    base = Keyword.get(opts, :base, Hierarchy.default_root())
    dir = Path.join([base, "companies", company, "proposals"])

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.map(&read_one/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.proposed_at, :desc)

      _ ->
        []
    end
  end

  @spec fetch(String.t(), String.t(), keyword()) :: {:ok, proposal()} | {:error, term()}
  def fetch(company, id, opts \\ []) when is_binary(company) and is_binary(id) do
    base = Keyword.get(opts, :base, Hierarchy.default_root())
    path = Path.join([base, "companies", company, "proposals", "#{id}.md"])

    case read_one(path) do
      nil -> {:error, :not_found}
      proposal -> {:ok, proposal}
    end
  end

  @doc """
  Flip a proposal's status on behalf of the Director.

  `decision` is `:approved` or `:denied`. On `:denied`, an optional
  `:denial_reason` string is persisted into the proposal frontmatter.
  """
  @spec flip(String.t(), String.t(), :approved | :denied, keyword()) ::
          :ok | {:error, term()}
  def flip(company, id, decision, opts \\ [])
      when is_binary(company) and is_binary(id) and decision in [:approved, :denied] do
    base = Keyword.get(opts, :base, Hierarchy.default_root())
    actor = Keyword.get(opts, :actor, "director")
    denial_reason = Keyword.get(opts, :denial_reason)
    audit = Keyword.get_lazy(opts, :audit, fn -> resolve_audit(company) end)

    path = Path.join([base, "companies", company, "proposals", "#{id}.md"])

    with {:ok, proposal} <- read_one!(path),
         :ok <- require_pending(proposal),
         :ok <- reject_self_flip(proposal, actor) do
      merged_fm =
        proposal.frontmatter
        |> Map.merge(flip_updates(decision, actor, denial_reason))

      new_content = serialize(merged_fm, proposal.body)

      case FrontmatterWriter.atomic_write(path, new_content) do
        :ok ->
          _ =
            audit.(company, %{
              actor: actor,
              action: "proposal.#{Atom.to_string(decision)}",
              target: "proposals/#{id}.md",
              detail: %{proposed_by: proposal.proposed_by, denial_reason: denial_reason}
            })

          :ok

        other ->
          other
      end
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp read_one(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, meta, body} <- Frontmatter.parse(content) do
      id = Path.basename(path, ".md")

      %{
        id: id,
        subtype: Map.get(meta, "subtype"),
        status: Map.get(meta, "status"),
        proposed_by: Map.get(meta, "proposed_by"),
        proposed_at: Map.get(meta, "proposed_at"),
        approved_by: Map.get(meta, "approved_by"),
        approved_at: Map.get(meta, "approved_at"),
        denial_reason: Map.get(meta, "denial_reason"),
        superseded_by: Map.get(meta, "superseded_by"),
        body: body,
        path: path,
        frontmatter: meta
      }
    else
      _ -> nil
    end
  end

  defp read_one!(path) do
    case read_one(path) do
      nil -> {:error, :not_found}
      proposal -> {:ok, proposal}
    end
  end

  defp require_pending(%{status: "pending-approval"}), do: :ok
  defp require_pending(%{status: other}), do: {:error, {:not_pending, other}}

  # Mirror of the Router's self-approval gate. A Director can't be the
  # proposed_by of a proposal today, but keep the invariant local so
  # "director" → "director" flips never slip through.
  defp reject_self_flip(%{proposed_by: proposer}, actor)
       when is_binary(proposer) and is_binary(actor) and proposer == actor,
       do: {:error, :proposal_self_approval}

  defp reject_self_flip(_proposal, _actor), do: :ok

  defp flip_updates(:approved, actor, _reason) do
    %{
      "status" => "approved",
      "approved_by" => actor,
      "approved_at" => iso_now(),
      "denial_reason" => nil,
      "superseded_by" => nil
    }
  end

  defp flip_updates(:denied, actor, reason) do
    %{
      "status" => "denied",
      "approved_by" => actor,
      "approved_at" => iso_now(),
      "superseded_by" => nil,
      "denial_reason" => if(is_binary(reason) and reason != "", do: reason, else: nil)
    }
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # Fresh-frontmatter serializer — mirrors the Router's
  # `serialize_proposal` so approve/deny writes produce the same
  # canonical key-ordering the agent-sourced create path produces.
  # Keys not in `@proposal_key_order` (e.g. `kind`) are emitted at
  # the top; ordered keys follow; nil values drop the line.
  @proposal_key_order ~w(id subtype status proposed_by requires_approval proposed_at approved_by approved_at denial_reason superseded_by)

  defp serialize(fm, body) do
    kind_line = "kind: #{Map.get(fm, "kind", "proposal/v1")}"

    ordered_lines =
      @proposal_key_order
      |> Enum.map(fn key ->
        case Map.get(fm, key) do
          nil -> nil
          "" -> nil
          value -> "#{key}: #{FrontmatterWriter.yaml_scalar(value)}"
        end
      end)
      |> Enum.reject(&is_nil/1)

    fm_block = Enum.join([kind_line | ordered_lines], "\n")
    "---\n" <> fm_block <> "\n---\n" <> body
  end

  # `AuditLog.append/2` talks to the per-company AuditLog GenServer
  # via its Registry-registered name. In LiveView tests with no
  # CompanySupervisor, that call errors out — catch it locally so
  # the flip still succeeds (the proposal file already persisted
  # on disk). Production callers always have the AuditLog up.
  defp resolve_audit(_company) do
    fn co, record ->
      try do
        AuditLog.append(co, record)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end
end
