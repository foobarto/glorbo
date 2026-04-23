defmodule Glorbo.CLI.Parsers.NativeV1 do
  @moduledoc """
  Usage parser for the native harness `usage.json` contract (GEP-32).

  Expected shape:

      {
        "tracked": true,
        "prompt_tokens": 12,
        "completion_tokens": 34,
        "model": "gpt-4.1",
        "duration_ms": 456
      }

  `duration_ms` is currently ignored here; Dispatch computes wall-clock
  duration separately and remains the authority for audit/UI timing.
  """

  alias Glorbo.CLI.Parsers

  @spec parse(Parsers.source()) :: {:ok, Parsers.usage()} | {:error, term()}
  def parse({:json_file, path}) when is_binary(path) do
    with true <- File.exists?(path) or {:error, :enoent},
         {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw),
         {:ok, usage} <- build_usage(decoded) do
      {:ok, usage}
    else
      false -> {:error, :enoent}
      {:error, _} = err -> err
    end
  end

  def parse({:jsonl_file, _path}), do: {:error, :jsonl_not_supported}
  def parse({:stdout, _blob}), do: {:error, :stdout_not_supported}

  defp build_usage(
         %{
           "tracked" => tracked,
           "prompt_tokens" => prompt,
           "completion_tokens" => completion
         } = map
       )
       when is_boolean(tracked) and is_integer(prompt) and prompt >= 0 and is_integer(completion) and
              completion >= 0 do
    {:ok,
     %{
       tracked: tracked,
       prompt_tokens: prompt,
       completion_tokens: completion,
       model: parse_model(Map.get(map, "model")),
       tool_calls: parse_tool_calls(Map.get(map, "tool_calls", %{}))
     }}
  end

  defp build_usage(_), do: {:error, :invalid_usage_json}

  defp parse_model(nil), do: nil
  defp parse_model(model) when is_binary(model), do: model
  defp parse_model(_), do: nil

  defp parse_tool_calls(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn
      {name, count}, acc when is_binary(name) and is_integer(count) and count >= 0 ->
        Map.put(acc, name, count)

      _, acc ->
        acc
    end)
  end

  defp parse_tool_calls(_), do: %{}
end
