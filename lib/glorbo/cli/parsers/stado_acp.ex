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
        command_fun: &System.cmd/3   # injectable for tests
      }}

  `command_fun` defaults to `&System.cmd/3` and can be overridden so
  tests don't need to spawn a real stado.

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
    * `{:error, {:invalid_json, reason}}` — stado emitted something
      we couldn't decode.
  """

  alias Glorbo.CLI.Parsers

  @spec parse(Parsers.source()) :: {:ok, Parsers.usage()} | {:error, term()}
  def parse({:stado_session, %{} = ctx}) do
    with {:ok, session_id} <- fetch(ctx, :session_id, :missing_session_id),
         {:ok, host_binary} <- fetch(ctx, :host_binary, :missing_host_binary),
         command_fun = Map.get(ctx, :command_fun, &System.cmd/3),
         {:ok, json} <- run_stado_stats(host_binary, session_id, command_fun),
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

  defp run_stado_stats(host_binary, session_id, command_fun) do
    args = ["stats", "--session", session_id, "--json"]

    case command_fun.(host_binary, args, stderr_to_stdout: true) do
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
  rescue
    e in [ErlangError, ArgumentError] ->
      {:error, {:stado_invocation_failed, Exception.message(e)}}
  end

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
