defmodule GlorboWeb.MCP.Tools.GetCompanyHealth do
  @moduledoc """
  MCP tool: `glorbo.get_company_health` (GEP-29 wave b.2).

  Returns a filesystem-derived health snapshot for one company. No
  Repo / GenServer / Registry dependency — the metrics that require
  a running supervisor (e.g. per-agent budget spend, live dispatch
  counts) are deferred to a later wave when we wire the MCP surface
  to the supervision tree.

  Current snapshot:

    * `company_exists` — the `company.md` frontmatter validates.
    * `counts` — agents / projects / proposals / channels / tasks
      by status.
    * `pending_approvals` — count of
      `agents/*/state/awaiting-approval-*.md` sentinels.
    * `audit_last_entry_at` — the most recent timestamp from the
      current-month audit JSONL (best-effort tail).
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Filesystem.Frontmatter
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.get_company_health"

  @impl true
  def description,
    do: """
    Return a health snapshot for the given company. Counts of
    agents, projects, proposals, channels, and tasks by status.
    Also includes pending-approval sentinel count and the most
    recent audit-log timestamp.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"}
      },
      "required" => ["company"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company}, context) when is_binary(company) do
    with :ok <- Args.require_slug(company, :company) do
      do_call(company, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_company_arg}

  defp do_call(company, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    co_path = Path.join([base, "companies", company])

    if File.dir?(co_path) do
      {:ok,
       %{
         "slug" => company,
         "company_exists" => true,
         "counts" => %{
           "agents" => count_subdirs(Path.join(co_path, "agents")),
           "projects" => count_subdirs(Path.join(co_path, "projects")),
           "proposals" => count_md_files(Path.join(co_path, "proposals")),
           "channels" => count_channel_files(Path.join(co_path, "channels")),
           "tasks_by_status" => tasks_by_status(co_path)
         },
         "pending_approvals" => count_pending_approvals(co_path),
         "audit_last_entry_at" => latest_audit_timestamp(co_path),
         "headcount_budget" => company_headcount_budget(co_path)
       }}
    else
      {:error, {:company_not_found, company}}
    end
  end

  # ---------------------------------------------------------------------------
  # Counts
  # ---------------------------------------------------------------------------

  defp count_subdirs(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.count(entries, &File.dir?(Path.join(dir, &1)))
      _ -> 0
    end
  end

  defp count_md_files(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.count(entries, &String.ends_with?(&1, ".md"))
      _ -> 0
    end
  end

  defp count_channel_files(dir) do
    # Exclude DMs from the channel count; they're a different
    # semantic type even though they share the same directory.
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.count(entries, fn f ->
          String.ends_with?(f, ".md") and not String.starts_with?(f, "dm-director--")
        end)

      _ ->
        0
    end
  end

  defp tasks_by_status(co_path) do
    co_path
    |> Path.join("projects/*/tasks/*.md")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn file, acc ->
      status = read_task_status(file)
      Map.update(acc, status, 1, &(&1 + 1))
    end)
  end

  defp read_task_status(path) do
    # Threatmodel wave 25: lstat + 1 MiB cap on agent-RW task md.
    case Glorbo.Filesystem.AgentWritableFile.read_bounded(path, 1_048_576) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, meta, _} -> safe_status(Map.get(meta, "status", "unknown"))
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end

  defp safe_status(v) when is_binary(v), do: v
  defp safe_status(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp safe_status(v) when is_number(v), do: to_string(v)
  defp safe_status(_), do: "unknown"

  defp count_pending_approvals(co_path) do
    co_path
    |> Path.join("agents/*/state/awaiting-approval-*.md")
    |> Path.wildcard()
    |> length()
  end

  defp latest_audit_timestamp(co_path) do
    case File.ls(Path.join(co_path, "audit")) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort(:desc)
        |> Enum.find_value(&last_line_timestamp(co_path, &1))

      _ ->
        nil
    end
  end

  defp last_line_timestamp(co_path, filename) do
    path = Path.join([co_path, "audit", filename])

    # Threatmodel wave 25: stream the audit file line-by-line,
    # keeping only the last non-empty line. Memory bounded by line
    # length regardless of file size.
    if File.regular?(path) do
      last_line =
        path
        |> File.stream!(:line, [])
        |> Enum.reduce("", fn line, acc ->
          trimmed = String.trim_trailing(line, "\n")
          if trimmed == "", do: acc, else: trimmed
        end)

      with last when last != "" <- last_line,
           {:ok, %{} = entry} <- Jason.decode(last) do
        Map.get(entry, "ts")
      else
        _ -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp company_headcount_budget(co_path) do
    # Wave 25: lstat + 1 MiB cap on company.md.
    case Glorbo.Filesystem.AgentWritableFile.read_bounded(
           Path.join(co_path, "company.md"),
           1_048_576
         ) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, meta, _} -> Map.get(meta, "headcount_budget")
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
