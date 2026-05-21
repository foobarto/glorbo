defmodule Glorbo.Task.Snapshot do
  @moduledoc """
  Builds a `Glorbo.Task.DependencyGate.snapshot()` — `task_id => task_info`
  for every task in a company — by reading task frontmatter from disk.

  Shared by `Glorbo.Company.TaskScheduler` (the scheduler fire gate +
  cycle detection) and `Glorbo.Company.Router` (the F10 `auto_dispatch`
  gate, GEP-47 v2). `DependencyGate` itself stays a pure rule module
  (it owns classification, not IO); this module owns the read-from-disk
  side so both callers share one snapshot shape.

  On-disk-truth read; the SQLite-derived index is GEP-47 D9 (queued).
  For typical task counts (<100) the per-call directory walk is fast
  enough; large rosters are what the index is for.
  """

  alias Glorbo.Filesystem.{AgentWritableFile, Frontmatter}

  @max_task_bytes 1_048_576

  @doc """
  Walk `companies/<company>/projects/*/tasks/*.md` under `base` and
  return the dependency snapshot. Unparseable files are skipped.
  """
  @spec build(String.t(), String.t()) :: Glorbo.Task.DependencyGate.snapshot()
  def build(base, company) do
    projects_dir = Path.join([base, "companies", company, "projects"])

    case File.ls(projects_dir) do
      {:ok, projects} ->
        projects
        |> Enum.flat_map(&project_task_paths(projects_dir, &1))
        |> Enum.flat_map(&snapshot_entry_for/1)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp project_task_paths(projects_dir, project) do
    tasks_dir = Path.join([projects_dir, project, "tasks"])

    case File.ls(tasks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join([projects_dir, project, "tasks", &1]))

      _ ->
        []
    end
  end

  defp snapshot_entry_for(path) do
    with {:ok, content} <- AgentWritableFile.read_bounded(path, @max_task_bytes),
         {:ok, fm, _body} <- Frontmatter.parse(content) do
      info = %{
        status: Map.get(fm, "status") || "",
        peer_review_required: Map.get(fm, "peer_review_required") == true,
        peer_review_verdict: Map.get(fm, "peer_review_verdict"),
        depends_on: coerce_depends_on(Map.get(fm, "depends_on"))
      }

      [{task_id_from_path(path), info}]
    else
      _ -> []
    end
  end

  @doc """
  Coerce a raw `depends_on` frontmatter value into a clean list of
  task-id strings (drop non-string/empty entries, dedupe) — the same
  shape `TaskDefinition` produces, without pulling in its full parser.
  """
  @spec coerce_depends_on(term()) :: [String.t()]
  def coerce_depends_on(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      s when is_binary(s) and s != "" -> [s]
      _ -> []
    end)
    |> Enum.uniq()
  end

  def coerce_depends_on(_), do: []

  defp task_id_from_path(path), do: path |> Path.basename() |> Path.rootname(".md")
end
