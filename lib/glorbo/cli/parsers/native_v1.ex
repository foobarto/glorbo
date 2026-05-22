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

  alias Glorbo.CLI.Harness.Tools
  alias Glorbo.CLI.Parsers
  alias Glorbo.Filesystem.AgentWritableFile

  # `usage.json` is written by the CLI inside the sandbox and is
  # attacker-controlled (GEP-32 threat model). A bare `File.read/1`
  # would slurp a multi-GB planted file into the dispatcher's BEAM
  # heap, OOMing the node. 1 MiB is far above any legitimate usage
  # report (a few hundred bytes in practice).
  @max_usage_bytes 1_048_576

  @spec parse(Parsers.source()) :: {:ok, Parsers.usage()} | {:error, term()}
  def parse({:json_file, path}) when is_binary(path) do
    with {:ok, raw} <- AgentWritableFile.read_bounded(path, @max_usage_bytes),
         {:ok, decoded} <- Jason.decode(raw),
         {:ok, usage} <- build_usage(decoded) do
      {:ok, usage}
    else
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
       tool_calls: parse_tool_calls(Map.get(map, "tool_calls", %{})),
       audit_events: parse_audit_events(Map.get(map, "audit_events", []))
     }}
  end

  defp build_usage(_), do: {:error, :invalid_usage_json}

  defp parse_model(nil), do: nil
  defp parse_model(model) when is_binary(model), do: model
  defp parse_model(_), do: nil

  defp parse_tool_calls(map) when is_map(map) do
    allowed = MapSet.new(Tools.known_tool_names())

    map
    |> Enum.reduce(%{}, fn
      {name, count}, acc when is_binary(name) and is_integer(count) and count >= 0 ->
        if MapSet.member?(allowed, name) do
          Map.put(acc, name, count)
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  defp parse_tool_calls(_), do: %{}

  defp parse_audit_events(events) when is_list(events) do
    allowed = MapSet.new(Tools.known_audit_actions())

    events
    |> Enum.reduce([], fn
      %{"action" => action} = event, acc when is_binary(action) ->
        if MapSet.member?(allowed, action) do
          detail =
            case Map.get(event, "detail") do
              map when is_map(map) -> sanitize_detail(map)
              _ -> %{}
            end

          parsed =
            %{action: action}
            |> maybe_put_target(Map.get(event, "target"))
            |> Map.put(:detail, detail)

          acc ++ [parsed]
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  defp parse_audit_events(_), do: []

  defp maybe_put_target(event, target) when is_binary(target), do: Map.put(event, :target, target)
  defp maybe_put_target(event, _target), do: event

  defp sanitize_detail(detail) do
    detail
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_binary(key) and is_binary(value) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) and is_boolean(value) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) and is_integer(value) ->
        Map.put(acc, key, value)

      {key, nil}, acc when is_binary(key) ->
        Map.put(acc, key, nil)

      _, acc ->
        acc
    end)
  end
end
