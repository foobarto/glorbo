defmodule Glorbo.Activity.Rollup do
  @moduledoc """
  14-day rollups for the CompanyLive sparkline tiles
  (paperclip-ux-gaps §4).

  Reads the last ~two months of `audit/YYYY-MM.jsonl` files for a
  company and derives four small histograms the UI renders as tiny
  sparklines:

    * `runs_per_day/2` — count of `agent.dispatch` events per calendar
      day, 14 entries ordered oldest → newest.
    * `success_rate_per_day/2` — ratio of `agent.complete` entries
      with `exit_status in ["0", 0]` over total `agent.complete` per
      day, expressed as an integer 0..100 (and `nil` where there were
      no completions).
    * `tasks_by_status/1` — current breakdown of the company's task
      files into {todo, in-progress, pending, approved, denied, done}.
    * `tasks_by_priority/1` — current breakdown into
      {low, medium, high, none}.

  Pure filesystem reads; returns sensible defaults when the company
  dir is missing or the audit log is empty.
  """

  @windows_days 14

  @doc """
  14-day histogram of `agent.dispatch` counts.

  Returns a list of `{Date.t(), non_neg_integer()}` ordered oldest
  to newest. Missing days show as 0.
  """
  @spec runs_per_day(Path.t(), String.t()) :: [{Date.t(), non_neg_integer()}]
  def runs_per_day(base, company_slug) do
    events = recent_events(base, company_slug, ["agent.dispatch"])

    buckets = index_events_by_day(events)
    days = last_n_days(@windows_days)

    Enum.map(days, fn date -> {date, Map.get(buckets, date, 0)} end)
  end

  @doc """
  14-day success rate derived from `agent.complete` entries.

  `nil` on days with no completions (distinguishes "0%" from "no
  data" in the sparkline).
  """
  @spec success_rate_per_day(Path.t(), String.t()) :: [{Date.t(), non_neg_integer() | nil}]
  def success_rate_per_day(base, company_slug) do
    events = recent_events(base, company_slug, ["agent.complete"])

    per_day =
      Enum.reduce(events, %{}, fn event, acc ->
        Map.update(acc, event_day(event), {1, success?(event)}, fn {total, wins} ->
          {total + 1, wins + if(success?(event) == 1, do: 1, else: 0)}
        end)
      end)

    days = last_n_days(@windows_days)

    Enum.map(days, fn date ->
      case Map.get(per_day, date) do
        nil -> {date, nil}
        {total, wins} when total > 0 -> {date, round(wins * 100 / total)}
        _ -> {date, nil}
      end
    end)
  end

  @doc """
  Breakdown of current task files by status.

  Returns a keyword-like list so rendering order is stable:
  `[{"todo", n}, {"in-progress", n}, {"pending", n}, {"approved", n},
  {"denied", n}, {"done", n}]`. Any unknown status is grouped under
  `"other"` and appended only if > 0.
  """
  @spec tasks_by_status(Path.t()) :: [{String.t(), non_neg_integer()}]
  def tasks_by_status(company_path) do
    known = ["todo", "in-progress", "pending", "approved", "denied", "done"]
    tasks_grouped(company_path, :status, known)
  end

  @doc """
  Breakdown of current task files by priority. Same shape as
  `tasks_by_status/1`.
  """
  @spec tasks_by_priority(Path.t()) :: [{String.t(), non_neg_integer()}]
  def tasks_by_priority(company_path) do
    known = ["high", "medium", "low", "none"]
    tasks_grouped(company_path, :priority, known)
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp recent_events(base, company_slug, actions) do
    actions_set = MapSet.new(actions)
    cutoff = Date.add(Date.utc_today(), -(@windows_days - 1))

    for ym <- last_n_year_months(2),
        path = audit_path(base, company_slug, ym),
        File.regular?(path),
        line <- read_lines(path),
        {:ok, ev} <- [Jason.decode(line)],
        MapSet.member?(actions_set, to_string(ev["action"] || "")),
        date = event_day(ev),
        Date.compare(date, cutoff) != :lt do
      ev
    end
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, c} -> String.split(c, "\n", trim: true)
      _ -> []
    end
  end

  defp audit_path(base, co, ym),
    do: Path.join([base, "companies", co, "audit", "#{ym}.jsonl"])

  defp last_n_year_months(n) do
    today = Date.utc_today()

    for offset <- 0..(n - 1) do
      date = Date.add(today, -offset * 30)
      :io_lib.format("~4..0B-~2..0B", [date.year, date.month]) |> IO.iodata_to_binary()
    end
    |> Enum.uniq()
  end

  defp last_n_days(n) do
    today = Date.utc_today()
    for offset <- (n - 1)..0//-1, do: Date.add(today, -offset)
  end

  defp index_events_by_day(events) do
    Enum.reduce(events, %{}, fn ev, acc ->
      Map.update(acc, event_day(ev), 1, &(&1 + 1))
    end)
  end

  defp event_day(%{"ts" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.to_date(dt)
      _ -> Date.utc_today()
    end
  end

  defp event_day(_), do: Date.utc_today()

  defp success?(%{"detail" => %{"exit_status" => s}}) when s in ["0", 0], do: 1
  defp success?(_), do: 0

  defp tasks_grouped(company_path, key, known) do
    frontmatters = collect_frontmatters(company_path)

    counts =
      Enum.reduce(frontmatters, %{}, fn fm, acc ->
        value = value_for(fm, key)
        Map.update(acc, value, 1, &(&1 + 1))
      end)

    base = Enum.map(known, fn k -> {k, Map.get(counts, k, 0)} end)
    other_keys = Map.keys(counts) -- known

    other_total =
      Enum.reduce(other_keys, 0, fn k, acc -> acc + Map.get(counts, k, 0) end)

    if other_total > 0, do: base ++ [{"other", other_total}], else: base
  end

  defp collect_frontmatters(company_path) do
    projects_dir = Path.join(company_path, "projects")

    case File.ls(projects_dir) do
      {:ok, projects} -> Enum.flat_map(projects, &collect_project_fms(projects_dir, &1))
      _ -> []
    end
  end

  defp collect_project_fms(projects_dir, project) do
    tasks_dir = Path.join([projects_dir, project, "tasks"])

    case File.ls(tasks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(&read_fm(Path.join(tasks_dir, &1)))

      _ ->
        []
    end
  end

  defp read_fm(path) do
    # Threatmodel wave 24: agent-RW path; lstat + 1 MiB cap guards
    # the read against symlinks/oversized files before parsing.
    with {:ok, content} <- Glorbo.Filesystem.AgentWritableFile.read_bounded(path, 1_048_576),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      [fm]
    else
      _ -> []
    end
  end

  # Threatmodel wave 24: status / priority can be agent-authored YAML
  # maps or lists. `to_string/1` on those raises Protocol.UndefinedError
  # and crashes the company-rollup render. Coerce only scalars.
  defp value_for(fm, :status), do: safe_scalar(fm["status"], "todo")

  defp value_for(fm, :priority) do
    case fm["priority"] do
      nil -> "none"
      "" -> "none"
      other -> safe_scalar(other, "none")
    end
  end

  defp safe_scalar(v, _default) when is_binary(v), do: v
  defp safe_scalar(v, _default) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp safe_scalar(v, _default) when is_number(v), do: to_string(v)
  defp safe_scalar(_, default), do: default
end
