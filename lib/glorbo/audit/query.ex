defmodule Glorbo.Audit.Query do
  @moduledoc """
  Task-scoped audit queries (#264).

  Reads the current-month audit JSONL and returns entries that
  pertain to a specific task. Matches on:

    * `target == task_path` (e.g. `projects/foo/tasks/t-1.md`)
    * `target` is the task_id (bare form, without the `projects/...`
      prefix — some action emitters use this shorter form)
    * `detail.task_path == task_path`
    * `detail.target` contains the task_id

  Pure reader — no writes, no GenServer. File doesn't exist →
  empty list; any decode error skips the line silently.

  Cross-month queries are not supported here; the director can
  navigate to the AuditLive month picker for older data.
  """

  @type entry :: map()

  @doc """
  List audit entries for a task, newest-first, capped at `limit`.
  """
  @spec for_task(Path.t(), String.t(), String.t(), keyword()) :: [entry()]
  def for_task(base, company, task_path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    month = Keyword.get_lazy(opts, :month, fn -> current_year_month() end)
    task_id = task_id_from_path(task_path)

    path = Path.join([base, "companies", company, "audit", "#{month}.jsonl"])

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_line/1)
        |> Enum.filter(&matches?(&1, task_path, task_id))
        |> Enum.reverse()
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = entry} -> [entry]
      _ -> []
    end
  end

  defp matches?(entry, task_path, task_id) do
    target = to_string(entry["target"] || "")
    detail = entry["detail"] || %{}
    detail_path = to_string(Map.get(detail, "task_path") || "")
    detail_target = to_string(Map.get(detail, "target") || "")

    target == task_path or
      target == task_id or
      detail_path == task_path or
      String.contains?(detail_target, task_id)
  end

  defp task_id_from_path(path) do
    path
    |> Path.basename(".md")
  end

  defp current_year_month do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.to_string()
    |> String.slice(0, 7)
  end
end
