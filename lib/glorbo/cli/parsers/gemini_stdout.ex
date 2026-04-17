defmodule Glorbo.CLI.Parsers.GeminiStdout do
  @moduledoc """
  Usage parser for Gemini CLI `--output-format json` stdout (GEP-8 §5).

  Extracted from the former `Glorbo.CLI.Adapter.GeminiCli.parse_usage/1`
  (pre-GEP-8). Invariants preserved:

    * `stats.models.<model>.tokens` is a map keyed by model name.
      Typically a single key; if multiple we SUM across them.
    * Prompt tokens = `tokens.prompt + tokens.cached`.
    * Completion tokens = `tokens.candidates + tokens.thoughts + tokens.tool`.
    * `model` = first encountered key (Gemini surfaces it in the dict).

  Returns `{:ok, usage()}` on success, `{:error, :no_stats}` when the
  JSON lacks a stats.models entry, and `{:error, :json_decode_error}`
  when the blob isn't valid JSON.
  """

  alias Glorbo.CLI.Parsers

  @spec parse(Parsers.source()) :: {:ok, Parsers.usage()} | {:error, term()}
  def parse({:stdout, blob}) when is_binary(blob) do
    case Jason.decode(blob) do
      {:ok, %{"stats" => %{"models" => models}}} when is_map(models) and map_size(models) > 0 ->
        {:ok, reduce_models(models)}

      {:ok, _other} ->
        {:error, :no_stats}

      {:error, _} ->
        {:error, :json_decode_error}
    end
  end

  def parse({:jsonl_file, _path}), do: {:error, :jsonl_not_supported}

  defp reduce_models(models) do
    Enum.reduce(models, %{prompt_tokens: 0, completion_tokens: 0, model: nil}, fn
      {name, %{"tokens" => t}}, acc when is_map(t) ->
        %{
          prompt_tokens:
            acc.prompt_tokens +
              (Map.get(t, "prompt") || 0) +
              (Map.get(t, "cached") || 0),
          completion_tokens:
            acc.completion_tokens +
              (Map.get(t, "candidates") || 0) +
              (Map.get(t, "thoughts") || 0) +
              (Map.get(t, "tool") || 0),
          model: acc.model || name
        }

      _, acc ->
        acc
    end)
  end
end
