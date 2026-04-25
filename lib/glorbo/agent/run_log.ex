defmodule Glorbo.Agent.RunLog do
  @moduledoc """
  Read-side view of an agent's past dispatches, derived from the
  company's audit JSONL.

  A **run** is the pair of `agent.dispatch` + `agent.complete` audit
  entries that share the same `invocation_id`. This module groups
  them into a single record for UI consumption (the AgentLive Runs
  tab).

  Pure reader — no writes, no GenServer. Test-friendly: pass a list
  of parsed audit entries directly to `group_runs/2`.
  """

  @type run :: %{
          invocation_id: String.t(),
          agent: String.t(),
          task_path: String.t() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          trigger: String.t() | nil,
          start_ts: DateTime.t() | nil,
          end_ts: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          exit_status: String.t() | nil,
          reply_preview: String.t() | nil,
          tool_calls: %{String.t() => non_neg_integer()} | nil,
          prompt_tokens: non_neg_integer() | nil,
          completion_tokens: non_neg_integer() | nil,
          cost_usd_cents: non_neg_integer() | nil,
          status: :complete | :running | :unknown
        }

  @doc """
  Read the agent's runs from the current-month audit JSONL under
  `<base>/companies/<company>/audit/YYYY-MM.jsonl`.

  Returns runs sorted newest-first. `limit` caps the list.
  """
  @spec list(Path.t(), String.t(), String.t(), keyword()) :: [run()]
  def list(base, company, agent, opts \\ []) do
    month = Keyword.get_lazy(opts, :month, fn -> month_bucket(DateTime.utc_now()) end)
    limit = Keyword.get(opts, :limit, 50)

    path = Path.join([base, "companies", company, "audit", "#{month}.jsonl"])

    entries = read_entries(path)

    entries
    |> group_runs(agent)
    |> Enum.take(limit)
  end

  @doc """
  Group parsed audit entries into runs for a specific agent. Exposed
  for tests that want to avoid disk I/O.
  """
  @spec group_runs([map()], String.t()) :: [run()]
  def group_runs(entries, agent) when is_list(entries) and is_binary(agent) do
    entries
    |> Enum.filter(&agent_match?(&1, agent))
    |> Enum.reduce(%{}, &accumulate_run/2)
    |> Map.values()
    |> Enum.sort_by(& &1.start_ts, {:desc, DateTime})
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp read_entries(path) do
    case File.read(path) do
      {:ok, content} -> content |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)
      {:error, _} -> []
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} -> [map]
      _ -> []
    end
  end

  defp agent_match?(entry, agent) do
    detail = Map.get(entry, "detail") || %{}

    Map.get(entry, "agent") == agent or
      Map.get(detail, "agent") == agent or
      (Map.get(entry, "action") in ["agent.dispatch", "agent.complete"] and
         (Map.get(entry, "actor") == agent or Map.get(detail, "actor") == agent))
  end

  defp accumulate_run(entry, acc) do
    detail = Map.get(entry, "detail") || %{}
    inv_id = Map.get(entry, "invocation_id") || Map.get(detail, "invocation_id")

    if is_nil(inv_id) do
      acc
    else
      Map.update(acc, inv_id, seed_run(entry, detail, inv_id), &merge_run(&1, entry, detail))
    end
  end

  defp seed_run(entry, detail, inv_id) do
    base = %{
      invocation_id: inv_id,
      agent: Map.get(entry, "agent") || Map.get(detail, "agent"),
      task_path: Map.get(entry, "target") || Map.get(detail, "task_path"),
      provider: Map.get(detail, "provider"),
      model: Map.get(detail, "model"),
      trigger: Map.get(detail, "trigger"),
      start_ts: nil,
      end_ts: nil,
      duration_ms: nil,
      exit_status: nil,
      reply_preview: nil,
      tool_calls: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      cost_usd_cents: nil,
      status: :unknown
    }

    merge_run(base, entry, detail)
  end

  defp merge_run(run, entry, detail) do
    ts = parse_ts(Map.get(entry, "ts"))
    action = Map.get(entry, "action")

    case action do
      "agent.dispatch" ->
        %{
          run
          | start_ts: ts,
            provider: Map.get(detail, "provider") || run.provider,
            model: Map.get(detail, "model") || run.model,
            trigger: Map.get(detail, "trigger") || run.trigger,
            task_path: Map.get(detail, "task_path") || Map.get(entry, "target") || run.task_path,
            status: if(run.status == :complete, do: :complete, else: :running)
        }

      "agent.complete" ->
        duration = parse_duration_ms(Map.get(detail, "duration_ms"), run.duration_ms)

        %{
          run
          | end_ts: ts,
            duration_ms: duration,
            exit_status: Map.get(detail, "exit_status") || run.exit_status,
            reply_preview: Map.get(detail, "reply_preview") || run.reply_preview,
            tool_calls: Map.get(detail, "tool_calls") || run.tool_calls,
            prompt_tokens: Map.get(detail, "prompt_tokens") || run.prompt_tokens,
            completion_tokens: Map.get(detail, "completion_tokens") || run.completion_tokens,
            cost_usd_cents: Map.get(detail, "cost_usd_cents") || run.cost_usd_cents,
            status: :complete
        }

      _ ->
        run
    end
  end

  defp parse_ts(nil), do: nil

  defp parse_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil

  # Threatmodel: audit JSONL is append-only but a tampered or
  # malformed entry can carry duration_ms as garbage.
  # `String.to_integer/1` raises on non-numeric strings, which
  # would propagate out of every reader of the run log
  # (TaskLive, AgentLive history, …). `Integer.parse/1` gives a
  # safe :error fallback that degrades to the prior duration.
  defp parse_duration_ms(n, _fallback) when is_integer(n), do: n

  defp parse_duration_ms(s, fallback) when is_binary(s) do
    case Integer.parse(s) do
      {n, _rest} -> n
      :error -> fallback
    end
  end

  defp parse_duration_ms(_other, fallback), do: fallback

  defp month_bucket(%DateTime{} = dt) do
    dt |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
  end
end
