defmodule Glorbo.CLI.Parsers.StadoAcp do
  @moduledoc """
  Usage parser for stado-driven ACP dispatches (GEP-45 Phase 3).

  Stado tracks tokens / cost / tool calls in commit-trailer form on
  its per-session git refs under `~/.local/share/stado/sessions/<sid>`
  (works offline + airgap — source is the git audit log, not an
  OTel pipeline). Glorbo doesn't parse the trailers directly; instead
  it shells out to stado's own `stado stats --session <sid> --json`,
  which is the supported interface and survives stado's internal
  schema changes across versions.

  ## Source contract

  Unlike the file-based parsers (`claude_jsonl`, `codex_jsonl`,
  `gemini_stdout`), this parser doesn't take a path. The dispatcher
  hands it a `{:stado_session, ctx}` source where `ctx` carries the
  session id (returned by `Acp.Client` after `session/new`) and the
  host-side stado binary path:

      {:stado_session, %{
        session_id: "acp-abc123",
        host_binary: "/usr/local/bin/stado",
        stats_env: [{"XDG_DATA_HOME", "…/workspace/.local/share"}, …],
        command_fun: &System.cmd/3   # injectable for tests
      }}

  `command_fun` defaults to `&System.cmd/3` and can be overridden so
  tests don't need to spawn a real stado.

  `stats_env` (optional) is the XDG env handed in by the dispatcher so
  the host-side `stado stats` call reads the per-agent session trace
  that the relocated `XDG_DATA_HOME`/`XDG_STATE_HOME` wrote into the
  agent workspace, NOT the host's shared `~/.local/{share,state}/stado`
  (A-001 / B-006). When absent the call falls back to a bare
  `System.cmd` with no `:env` override.

  ## Output

  Maps `stado stats --session <sid> --json` to the canonical
  `Parsers.usage()` shape:

      %{
        prompt_tokens: integer,
        completion_tokens: integer,
        model: string | nil,
        tool_calls: %{tool_name => count},
        cost_usd: float,            # extra field for stado-aware callers
        duration_ms: integer        # extra field
      }

  The two extra fields (`cost_usd`, `duration_ms`) are above the
  `Parsers.usage()` minimum but harmless — downstream callers that
  care about cost (the budget ledger) can read them; callers that
  don't simply ignore them.

  ## Failure modes

    * `{:error, :stdout_not_supported}` — file/stdout sources don't
      apply.
    * `{:error, :missing_host_binary}` — ctx didn't include a path.
    * `{:error, :missing_session_id}` — Acp.Client didn't capture
      the session id (typical when the dispatch failed before
      `session/new` returned).
    * `{:error, {:stado_exit, code, output_tail}}` — stado returned
      non-zero. The first 8 lines of stderr-merged output are
      forwarded for debug.
    * `{:error, {:stado_stats_timeout, ms}}` — the host-side stats
      subprocess overran its hard timeout and was shut down so it
      could not block the dispatch pipeline.
    * `{:error, {:invalid_json, reason}}` — stado emitted something
      we couldn't decode.
  """

  alias Glorbo.CLI.Parsers

  # Hard upper bound on the host-side `stado stats` subprocess (B-006).
  # The stats walker only reads the session git refs from the per-agent
  # workspace — it needs no network and should finish in well under a
  # second. Bounding it stops a hung/wedged stats from blocking the
  # dispatch pipeline indefinitely.
  @stats_timeout_ms 15_000

  @spec parse(Parsers.source()) :: {:ok, Parsers.usage()} | {:error, term()}
  def parse({:stado_session, %{} = ctx}) do
    with {:ok, session_id} <- fetch(ctx, :session_id, :missing_session_id),
         {:ok, host_binary} <- fetch(ctx, :host_binary, :missing_host_binary),
         command_fun = Map.get(ctx, :command_fun, &System.cmd/3),
         stats_env = Map.get(ctx, :stats_env),
         timeout_ms = Map.get(ctx, :stats_timeout_ms, @stats_timeout_ms),
         {:ok, json} <-
           run_stado_stats(host_binary, session_id, command_fun, stats_env, timeout_ms),
         {:ok, decoded} <- decode_json(json) do
      {:ok, to_usage(decoded)}
    end
  end

  def parse({:jsonl_file, _}), do: {:error, :stdout_not_supported}
  def parse({:json_file, _}), do: {:error, :stdout_not_supported}
  def parse({:stdout, _}), do: {:error, :stdout_not_supported}

  defp fetch(ctx, key, missing_tag) do
    case Map.fetch(ctx, key) do
      {:ok, val} when is_binary(val) and val != "" -> {:ok, val}
      _ -> {:error, missing_tag}
    end
  end

  defp run_stado_stats(host_binary, session_id, command_fun, stats_env, timeout_ms) do
    args = ["stats", "--session", session_id, "--json"]

    # A-001/B-006: when the dispatcher relocated stado's XDG dirs into
    # the per-agent workspace, it hands us `stats_env` pointing there so
    # the host-side stats walker reads the per-agent session trace (not
    # the host's shared `~/.local/{share,state}/stado`). `System.cmd/3`
    # supports `:env`; it does NOT support `:timeout`, so we bound the
    # whole call with a Task (below) instead.
    cmd_opts = [stderr_to_stdout: true] |> put_env(stats_env)

    with_timeout(timeout_ms, fn ->
      case command_fun.(host_binary, args, cmd_opts) do
        {output, 0} ->
          {:ok, output}

        {output, code} ->
          tail =
            output
            |> String.trim()
            |> String.split("\n")
            |> Enum.take(-8)
            |> Enum.join("\n")

          {:error, {:stado_exit, code, tail}}
      end
    end)
  rescue
    e in [ErlangError, ArgumentError] ->
      {:error, {:stado_invocation_failed, Exception.message(e)}}
  end

  # B-006: bound the host-side stats subprocess so a hung `stado stats`
  # cannot block the dispatch pipeline. `System.cmd/3` has no `:timeout`
  # option, so run it in a Task and shut the Task down if it overruns —
  # the dispatch then proceeds with `usage: nil` rather than wedging.
  defp with_timeout(timeout_ms, fun) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, {:stado_stats_timeout, timeout_ms}}
      {:exit, reason} -> {:error, {:stado_invocation_failed, inspect(reason)}}
    end
  end

  defp put_env(opts, env) when is_list(env) and env != [], do: Keyword.put(opts, :env, env)
  defp put_env(opts, _), do: opts

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, {:invalid_json, "expected an object"}}
      {:error, reason} -> {:error, {:invalid_json, Exception.message(reason)}}
    end
  end

  # Map stado's `stats --json` shape to the canonical usage map.
  # Stado's `total` block carries call/token counts; `by_model` is
  # a map keyed by model id whose values share the same `total`-shape
  # body. We pick the dominant model (highest call count) as the
  # canonical `model:` field.
  defp to_usage(%{} = decoded) do
    total = Map.get(decoded, "total", %{})

    %{
      prompt_tokens: int(Map.get(total, "tokens_in", 0)),
      completion_tokens: int(Map.get(total, "tokens_out", 0)),
      cost_usd: float(Map.get(total, "cost_usd", 0)),
      duration_ms: int(Map.get(decoded, "total_duration_ms", 0)),
      model: dominant_model(Map.get(decoded, "by_model")),
      tool_calls: tool_breakdown(Map.get(decoded, "by_tool"))
    }
  end

  defp dominant_model(%{} = by_model) when map_size(by_model) > 0 do
    by_model
    |> Enum.max_by(
      fn {_id, body} -> body |> Map.get("calls", 0) |> int() end,
      fn -> {nil, %{}} end
    )
    |> elem(0)
  end

  defp dominant_model(_), do: nil

  defp tool_breakdown(%{} = by_tool) do
    Map.new(by_tool, fn {tool, body} ->
      {tool, body |> Map.get("calls", 0) |> int()}
    end)
  end

  defp tool_breakdown(_), do: %{}

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(n) when is_integer(n), do: 0
  defp int(n) when is_float(n) and n >= 0, do: trunc(n)
  defp int(_), do: 0

  defp float(n) when is_float(n) and n >= 0, do: n
  defp float(n) when is_integer(n) and n >= 0, do: n / 1
  defp float(_), do: 0.0
end
