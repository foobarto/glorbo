defmodule GlorboWeb.MCP.Tools.ListChannels do
  @moduledoc """
  MCP tool: `glorbo.list_channels` (GEP-29 wave b.2).

  Enumerates channel markdown files under
  `companies/<co>/channels/`. Director↔agent DMs (files matching
  `dm-director--<slug>.md`) are excluded by default — use
  `include_dms: true` to see them.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.list_channels"

  @impl true
  def description,
    do: """
    List chat channels for the given company. Each entry carries
    `name` (channel slug, e.g. "general") and `size_bytes`. DMs
    (dm-director--<slug>) are excluded unless `include_dms: true`.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "include_dms" => %{"type" => "boolean"}
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
    dir = Path.join([base, "companies", company, "channels"])
    include_dms = Map.get(args, "include_dms", false) == true

    case File.ls(dir) do
      {:ok, entries} ->
        channels =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.reject(fn f -> not include_dms and String.starts_with?(f, "dm-director--") end)
          |> Enum.sort()
          |> Enum.map(&describe(dir, &1))

        {:ok, %{"channels" => channels}}

      {:error, :enoent} ->
        {:ok, %{"channels" => []}}

      {:error, reason} ->
        {:error, {:ls_failed, reason}}
    end
  end

  defp describe(dir, filename) do
    name = Path.basename(filename, ".md")
    path = Path.join(dir, filename)

    %{
      "name" => name,
      "size_bytes" => file_size(path)
    }
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> nil
    end
  end
end
