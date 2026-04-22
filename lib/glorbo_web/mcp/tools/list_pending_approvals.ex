defmodule GlorboWeb.MCP.Tools.ListPendingApprovals do
  @moduledoc """
  MCP tool: `glorbo.list_pending_approvals` (GEP-29 wave b.2).

  Scans `agents/*/state/awaiting-approval-*.md` sentinels and
  returns the set of tasks currently waiting on Director review
  (GEP-19). Filesystem-as-source-of-truth: no Ecto / GenServer /
  registry dependency.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.TaskDefinition
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.list_pending_approvals"

  @impl true
  def description,
    do: """
    List tasks currently awaiting Director approval under GEP-19.
    Walks `agents/*/state/awaiting-approval-*.md` sentinels and
    pairs each with its task file. Each entry carries task_id,
    task_path, title, requesting_agent, and the sentinel mtime as
    `requested_at`.
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
    agents_dir = Path.join([base, "companies", company, "agents"])

    case File.ls(agents_dir) do
      {:ok, agent_slugs} ->
        entries =
          agent_slugs
          |> Enum.sort()
          |> Enum.flat_map(&scan_agent(base, company, agents_dir, &1))

        {:ok, %{"pending" => entries}}

      {:error, :enoent} ->
        {:ok, %{"pending" => []}}

      {:error, reason} ->
        {:error, {:ls_failed, reason}}
    end
  end

  defp scan_agent(base, company, agents_dir, agent) do
    state_dir = Path.join([agents_dir, agent, "state"])

    case File.ls(state_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&awaiting_sentinel?/1)
        |> Enum.map(&build_entry(base, company, agent, state_dir, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp awaiting_sentinel?(name),
    do: String.starts_with?(name, "awaiting-approval-") and String.ends_with?(name, ".md")

  defp build_entry(base, company, agent, state_dir, filename) do
    task_id =
      filename
      |> String.replace_prefix("awaiting-approval-", "")
      |> String.replace_suffix(".md", "")

    case find_task_file(base, company, task_id) do
      nil ->
        %{
          "task_id" => task_id,
          "requesting_agent" => agent,
          "error" => "task_not_found"
        }

      {rel, abs} ->
        title =
          case TaskDefinition.parse_file(abs, base: base, company: company) do
            {:ok, task} -> task.title || task_id
            _ -> task_id
          end

        %{
          "task_id" => task_id,
          "task_path" => rel,
          "title" => title,
          "requesting_agent" => agent,
          "requested_at" => mtime_iso(Path.join(state_dir, filename))
        }
    end
  end

  defp find_task_file(base, company, task_id) do
    pattern =
      Path.join([base, "companies", company, "projects", "*", "tasks", "#{task_id}.md"])

    case Path.wildcard(pattern) do
      [abs | _] ->
        rel = Path.relative_to(abs, Path.join([base, "companies", company]))
        {rel, abs}

      [] ->
        nil
    end
  end

  defp mtime_iso(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        mtime
        |> DateTime.from_unix!(:second)
        |> DateTime.to_iso8601()

      _ ->
        nil
    end
  end
end
