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

  # Gemini round-3 finding: `:month` was interpolated into the audit
  # file path with no validation. Currently no live web/MCP path
  # exposes `:month` directly from a request param, but the function
  # is a public-API foot-gun — one MCP tool already accepts month-
  # range options, and a future caller dropping it through here
  # could path-traverse into any JSONL on disk (`../../etc/foo`).
  # Defense-in-depth: only `YYYY-MM` reaches `Path.join`.
  @month_re ~r/\A\d{4}-(0[1-9]|1[0-2])\z/

  @doc """
  List audit entries for a task, newest-first, capped at `limit`.

  `:month` (optional) must be `YYYY-MM`; invalid month strings are
  ignored and the current UTC month is used instead.
  """
  @spec for_task(Path.t(), String.t(), String.t(), keyword()) :: [entry()]
  def for_task(base, company, task_path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    month = resolve_month(opts)
    task_id = task_id_from_path(task_path)

    path = Path.join([base, "companies", company, "audit", "#{month}.jsonl"])

    # Threatmodel wave 23: stream the JSONL line-by-line and keep a
    # rolling-window of the last `limit` matches, so memory stays
    # bounded by N regardless of file size.
    #
    # Copilot review on PR #36: `for_task/4` now backs security
    # gates (loop-detector + peer-review corroboration), so a
    # symlink planted under `audit/` (or any ancestor) would let an
    # attacker redirect the corroboration read to an arbitrary host
    # path and spoof the audit row. Mirror the dashboard audit-read
    # hardening (3 sites in PR #36) by walking ancestors with
    # `SymlinkGuard` + an `lstat` on the leaf before streaming.
    if audit_path_safe_to_read?(path) do
      # `[entry | Enum.take(acc, limit-1)]` keeps the rolling window
      # sorted newest-first as the stream progresses, since the file
      # is chronologically oldest-first. The final acc IS already
      # newest-first; no Enum.reverse needed.
      path
      |> File.stream!([], :line)
      |> Enum.reduce([], &push_match(&1, &2, task_path, task_id, limit))
    else
      []
    end
  rescue
    _ -> []
  end

  defp audit_path_safe_to_read?(path) do
    Glorbo.Sandbox.SymlinkGuard.assert_no_symlink_segment!(
      path,
      "audit/query: audit JSONL"
    )

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  defp push_match(line, acc, task_path, task_id, limit) do
    case decode_line(line) do
      [entry] ->
        if matches?(entry, task_path, task_id),
          do: [entry | Enum.take(acc, limit - 1)],
          else: acc

      _ ->
        acc
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

  # Validate the caller-supplied `:month`. Strings that don't match
  # `YYYY-MM` (including `..`, slashes, or anything else that would
  # let `Path.join` escape the audit dir) fall back to the current
  # UTC month rather than raising — callers that didn't pass a month
  # at all already get this fallback via `Keyword.get_lazy/3`.
  defp resolve_month(opts) do
    case Keyword.get(opts, :month) do
      m when is_binary(m) ->
        if Regex.match?(@month_re, m), do: m, else: current_year_month()

      _ ->
        current_year_month()
    end
  end
end
