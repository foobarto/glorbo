defmodule Glorbo.CLI.Parsers.CodexJsonl do
  @moduledoc """
  Usage parser for Codex rollout JSONL (GEP-8 §5).

  Extracted from the former `Glorbo.CLI.Adapter.Codex.parse_usage/1`
  (pre-GEP-8). Invariants preserved:

    * Codex `token_count` events carry CUMULATIVE `total_token_usage`
      counters — NOT deltas. Take the LAST `token_count` event, never
      the sum (Pitfall 10 / T-03-17).
    * Reasoning tokens (`reasoning_output_tokens`) count as completion.
    * Codex does not surface model per event — returns `model: nil`;
      Dispatcher fills from `spec.model`.

  Returns `{:ok, usage()}` on success, `{:error, :enoent}` when the
  rollout file is missing, and `{:error, :no_token_count}` when no
  cumulative event was found.
  """

  alias Glorbo.CLI.Parsers

  @spec parse(Parsers.source()) :: {:ok, Parsers.usage()} | {:error, term()}
  def parse({:jsonl_file, path}) when is_binary(path) do
    if File.exists?(path) do
      case extract_last_token_event(path) do
        nil -> {:error, :no_token_count}
        event -> {:ok, build_usage(event)}
      end
    else
      {:error, :enoent}
    end
  end

  def parse({:stdout, _blob}), do: {:error, :stdout_not_supported}

  defp extract_last_token_event(path) do
    path
    |> File.stream!()
    |> Stream.map(&decode_line/1)
    |> Stream.reject(&(&1 == :skip))
    |> Stream.filter(&token_count?/1)
    |> Enum.reduce(nil, fn event, _acc -> event end)
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, entry} -> entry
      {:error, _} -> :skip
    end
  end

  defp token_count?(%{"type" => "event_msg", "payload" => %{"type" => "token_count"}}), do: true
  defp token_count?(_), do: false

  defp build_usage(event) do
    usage = get_in(event, ["payload", "info", "total_token_usage"]) || %{}

    # Threatmodel: usage fields are CLI-controlled and may be
    # strings, lists, or anything else. Coerce to non-negative
    # integers to defeat the ArithmeticError on `+`.
    input = coerce_int(Map.get(usage, "input_tokens"))
    cached = coerce_int(Map.get(usage, "cached_input_tokens"))
    output = coerce_int(Map.get(usage, "output_tokens"))
    reasoning = coerce_int(Map.get(usage, "reasoning_output_tokens"))

    %{
      prompt_tokens: input + cached,
      completion_tokens: output + reasoning,
      model: nil
    }
  end

  defp coerce_int(n) when is_integer(n) and n >= 0, do: n
  defp coerce_int(_other), do: 0
end
