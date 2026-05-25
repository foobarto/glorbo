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
  alias Glorbo.HomeHistory
  alias Glorbo.HomeHistory.Tx

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
  # Gemini round-5 finding (PR #37): `id` flowed from a
  # LiveView WS frame into `Path.join` without slug validation
  # and `AgentWritableFile.ensure_writable/1` only does lstat,
  # not `..` normalisation. A logged-in dashboard session could
  # send `id: "../<other-co>/proposals/<their-id>"` to flip
  # proposals in ANOTHER company — bypassing the URL's
  # `:company` scoping. Defense: validate id against the same
  # slug regex the router uses (`\A[a-z0-9][a-z0-9_-]*\z` —
  # mirrors `Glorbo.Slug.valid?/1`).
  @proposal_id_re ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @spec flip(String.t(), String.t(), :approved | :denied, keyword()) ::
          :ok | {:error, term()}
  def flip(company, id, decision, opts \\ [])
      when is_binary(company) and is_binary(id) and decision in [:approved, :denied] do
    base = Keyword.get(opts, :base, Hierarchy.default_root())
    actor = Keyword.get(opts, :actor, "director")
    denial_reason = Keyword.get(opts, :denial_reason)
    audit = Keyword.get_lazy(opts, :audit, fn -> resolve_audit(company) end)

    cond do
      not Glorbo.Slug.valid?(company) ->
        {:error, :invalid_company}

      not Regex.match?(@proposal_id_re, id) ->
        {:error, :invalid_proposal_id}

      true ->
        do_flip(company, id, decision, base, actor, denial_reason, audit)
    end
  end

  defp do_flip(company, id, decision, base, actor, denial_reason, audit) do
    path = Path.join([base, "companies", company, "proposals", "#{id}.md"])

    history_meta = %{
      actor: HomeHistory.actor_from_string(actor),
      action: "proposal.#{Atom.to_string(decision)}",
      target: "companies/#{company}/proposals/#{id}.md"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        with {:ok, proposal} <- read_one!(path),
             :ok <- require_pending(proposal),
             :ok <- reject_self_flip(proposal, actor) do
          do_flip_write(tx_id, path, base, company, id, proposal, decision,
            actor: actor,
            denial_reason: denial_reason,
            audit: audit
          )
        end
      end)

    case history_result do
      {:ok, :ok, _tx_id} -> :ok
      {:error, _} = err -> err
    end
  end

  defp do_flip_write(tx_id, path, base, company, id, proposal, decision, opts) do
    actor = Keyword.fetch!(opts, :actor)
    denial_reason = Keyword.get(opts, :denial_reason)
    audit = Keyword.fetch!(opts, :audit)

    merged_fm =
      proposal.frontmatter
      |> Map.merge(flip_updates(decision, actor, denial_reason))

    new_content = serialize(merged_fm, proposal.body)

    case FrontmatterWriter.atomic_write(path, new_content) do
      :ok ->
        :ok = Tx.mark_path(tx_id, path)

        _ =
          audit.(company, %{
            actor: actor,
            action: "proposal.#{Atom.to_string(decision)}",
            target: "proposals/#{id}.md",
            detail: %{proposed_by: proposal.proposed_by, denial_reason: denial_reason}
          })

        :ok = Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(base, company))
        :ok

      other ->
        other
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  # Codex round-6 finding (PR #38, LOW): agent-controlled
  # frontmatter scalars (subtype, proposed_at, proposed_by,
  # denial_reason, etc.) flowed into the LiveView render
  # unbounded. The 10 MiB AgentWritableFile cap bounds the
  # worst per-file blast radius, but a single proposal can
  # still inflate ~10 MiB of HTML per list refresh. Cap each
  # scalar at the source so EVERY render path benefits.
  @scalar_cap 240

  defp read_one(path) do
    # Wave 27: lstat + bounded read so a planted proposal symlink
    # in the agent-RW proposals/ tree won't be followed and a
    # multi-MB body can't OOM the dashboard. Frontmatter.parse/1
    # has its own cap but only after the slurp.
    with {:ok, content} <- Glorbo.Filesystem.AgentWritableFile.read(path),
         {:ok, meta, body} <- Frontmatter.parse(content) do
      id = Path.basename(path, ".md")

      %{
        id: id,
        subtype: scalar_cap(Map.get(meta, "subtype")),
        status: Map.get(meta, "status"),
        proposed_by: scalar_cap(Map.get(meta, "proposed_by")),
        proposed_at: scalar_cap(Map.get(meta, "proposed_at")),
        approved_by: scalar_cap(Map.get(meta, "approved_by")),
        approved_at: scalar_cap(Map.get(meta, "approved_at")),
        denial_reason: scalar_cap(Map.get(meta, "denial_reason")),
        superseded_by: scalar_cap(Map.get(meta, "superseded_by")),
        body: body,
        path: path,
        frontmatter: meta
      }
    else
      _ -> nil
    end
  end

  defp scalar_cap(nil), do: nil

  defp scalar_cap(value) when is_binary(value) do
    Glorbo.Util.UTF8.safe_byte_slice(value, @scalar_cap)
  end

  defp scalar_cap(value), do: value |> to_string() |> String.slice(0, @scalar_cap)

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

  # `AuditLog.append_for/2` resolves the per-company AuditLog GenServer
  # via its Registry-registered name and logs on failure. Codex round-3
  # flagged a prior version that called `AuditLog.append(co, record)`
  # — that positional first arg is treated as the `server` handle by
  # `append/2`, which is a string slug, not a pid/module. Production
  # approve/deny events were silently dropped.
  defp resolve_audit(_company) do
    fn co, record ->
      _ = AuditLog.append_for(co, record)
      :ok
    end
  end
end
