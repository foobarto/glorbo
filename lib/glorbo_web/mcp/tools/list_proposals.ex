defmodule GlorboWeb.MCP.Tools.ListProposals do
  @moduledoc """
  MCP tool: `glorbo.list_proposals` (GEP-29 wave b).

  Enumerates `proposal/v1` files directly under
  `companies/<co>/proposals/`. Optional `status` filter narrows to
  `pending-approval` / `approved` / `denied` / `superseded`.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Filesystem.Frontmatter
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.list_proposals"

  @impl true
  def description,
    do: """
    List GEP-28 proposals for the given company. Returns one entry
    per direct-child `.md` file under `proposals/` with id, subtype,
    status, proposed_by, proposed_at. Use the `status` argument to
    filter by current state.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "status" => %{
          "type" => ["string", "null"],
          "enum" => ["pending-approval", "approved", "denied", "superseded", nil]
        }
      },
      "required" => ["company"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company} = args, context) when is_binary(company) do
    with :ok <- Args.require_slug(company, :company) do
      do_call(company, args, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_company_arg}

  defp do_call(company, args, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    proposals_dir = Path.join([base, "companies", company, "proposals"])
    status_filter = nilify(args["status"])

    case File.ls(proposals_dir) do
      {:ok, entries} ->
        proposals =
          entries
          |> Enum.sort()
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&load(Path.join(proposals_dir, &1), &1))
          |> Enum.reject(&is_nil/1)
          |> maybe_filter_status(status_filter)

        {:ok, %{"proposals" => proposals}}

      {:error, :enoent} ->
        {:ok, %{"proposals" => []}}

      {:error, reason} ->
        {:error, {:ls_failed, reason}}
    end
  end

  defp load(path, filename) do
    id = Path.basename(filename, ".md")

    case File.read(path) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, meta, _body} ->
            %{
              "id" => Map.get(meta, "id", id),
              "subtype" => Map.get(meta, "subtype"),
              "status" => Map.get(meta, "status"),
              "proposed_by" => Map.get(meta, "proposed_by"),
              "proposed_at" => Map.get(meta, "proposed_at"),
              "approved_by" => Map.get(meta, "approved_by"),
              "approved_at" => Map.get(meta, "approved_at")
            }

          _ ->
            %{"id" => id, "error" => "malformed frontmatter"}
        end

      _ ->
        nil
    end
  end

  defp maybe_filter_status(proposals, nil), do: proposals

  defp maybe_filter_status(proposals, status),
    do: Enum.filter(proposals, &(&1["status"] == status))

  defp nilify(""), do: nil
  defp nilify(nil), do: nil
  defp nilify(v) when is_binary(v), do: v
  defp nilify(_), do: nil
end
