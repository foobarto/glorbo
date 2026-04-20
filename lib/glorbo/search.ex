defmodule Glorbo.Search do
  @moduledoc """
  Content search across a company's filesystem for the Ctrl+K palette
  (#232 T2-B).

  Scope v1: task titles + task IDs under `projects/*/tasks/*.md`.
  Future: audit rows, channel messages, agent slugs. Each result
  carries a `kind`, a human-readable `label`, and an `href` the
  caller can navigate to.

  The search is O(n) over task files, synchronous. Glorbo is
  single-director / single-company-at-a-time, so a few hundred task
  files is the realistic cap. For scale, a proper SQLite FTS index
  would go here — not yet.
  """

  @type result :: %{
          kind: String.t(),
          label: String.t(),
          href: String.t(),
          score: integer()
        }

  @doc """
  Search `query` inside company `co` rooted at `base`. Returns up
  to `limit` results ranked by a simple heuristic (title prefix
  match > substring > id match). Empty `query` returns [].
  """
  @spec search(Path.t(), String.t(), String.t(), keyword()) :: [result()]
  def search(base, co, query, opts \\ [])

  def search(_base, _co, "", _opts), do: []
  def search(_base, _co, nil, _opts), do: []

  def search(base, co, query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    normalised = String.downcase(String.trim(query))

    if normalised == "" do
      []
    else
      base
      |> scan_tasks(co)
      |> Enum.flat_map(&score_task(&1, normalised, co))
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp scan_tasks(base, co) do
    projects_dir = Path.join([base, "companies", co, "projects"])

    case File.ls(projects_dir) do
      {:ok, projects} ->
        Enum.flat_map(projects, fn project ->
          tasks_dir = Path.join([projects_dir, project, "tasks"])

          case File.ls(tasks_dir) do
            {:ok, files} ->
              files
              |> Enum.filter(&String.ends_with?(&1, ".md"))
              |> Enum.flat_map(&read_task(tasks_dir, &1))

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp read_task(tasks_dir, filename) do
    path = Path.join(tasks_dir, filename)
    task_id = Path.basename(filename, ".md")

    case File.read(path) do
      {:ok, content} ->
        title =
          case Glorbo.Filesystem.Frontmatter.parse(content) do
            {:ok, fm, _body} -> to_string(fm["title"] || task_id)
            _ -> task_id
          end

        [%{task_id: task_id, title: title, path: path}]

      _ ->
        []
    end
  end

  # Score each candidate against the query. Higher score = better
  # match. Results with score 0 are dropped.
  defp score_task(%{task_id: id, title: title}, query, co) do
    lid = String.downcase(id)
    ltitle = String.downcase(title)

    score =
      cond do
        String.starts_with?(ltitle, query) -> 100
        String.starts_with?(lid, query) -> 90
        String.contains?(ltitle, query) -> 50
        String.contains?(lid, query) -> 40
        true -> 0
      end

    if score == 0 do
      []
    else
      [
        %{
          kind: "task",
          label: "#{id} · #{title}",
          href: "/companies/#{co}/tasks/#{id}",
          score: score
        }
      ]
    end
  end
end
