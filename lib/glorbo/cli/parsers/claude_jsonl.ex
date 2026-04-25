defmodule Glorbo.CLI.Parsers.ClaudeJsonl do
  @moduledoc """
  Usage parser for Claude Code session JSONL (GEP-8 §5).

  Extracted from the former `Glorbo.CLI.Adapter.ClaudeCode.parse_usage/1`
  (pre-GEP-8). Invariants preserved:

    * Session JSONL is streamed line-by-line via `File.stream!/1` —
      bounded memory, malformed lines skipped silently.
    * Only `type: "assistant"` entries contribute to the totals.
    * Prompt tokens include all three cache categories
      (`input_tokens + cache_creation_input_tokens + cache_read_input_tokens`)
      — matches Claude Code 2.1.110 schema (verified 2026-04-16).

  Returns `{:ok, usage()}` on successful parse, `{:error, :enoent}` when
  the session file is missing, and `{:error, :stdout_not_supported}` for
  the stdout source (the Claude adapter only uses JSONL).
  """

  alias Glorbo.CLI.Parsers

  @spec parse(Parsers.source()) :: {:ok, Parsers.usage()} | {:error, term()}
  def parse({:jsonl_file, path}) when is_binary(path) do
    if File.exists?(path) do
      {:ok, do_parse_stream(path)}
    else
      {:error, :enoent}
    end
  end

  def parse({:stdout, _blob}), do: {:error, :stdout_not_supported}

  defp do_parse_stream(path) do
    path
    |> File.stream!()
    |> Stream.map(&decode_line/1)
    |> Stream.reject(&(&1 == :skip))
    |> Stream.filter(&(Map.get(&1, "type") == "assistant"))
    |> Enum.reduce(
      %{prompt_tokens: 0, completion_tokens: 0, model: nil, tool_calls: %{}},
      &accumulate/2
    )
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, entry} -> entry
      {:error, _} -> :skip
    end
  end

  defp accumulate(entry, acc) do
    usage = get_in(entry, ["message", "usage"]) || %{}
    content = get_in(entry, ["message", "content"]) || []

    # Threatmodel: usage fields are agent/CLI-controlled. A
    # malicious or buggy CLI could emit `input_tokens: "many"` or
    # `output_tokens: [1, 2]`, which would crash the accumulator
    # with ArithmeticError when we add it to acc. Coerce to int.
    %{
      prompt_tokens:
        acc.prompt_tokens +
          coerce_int(Map.get(usage, "input_tokens")) +
          coerce_int(Map.get(usage, "cache_creation_input_tokens")) +
          coerce_int(Map.get(usage, "cache_read_input_tokens")),
      completion_tokens:
        acc.completion_tokens + coerce_int(Map.get(usage, "output_tokens")),
      model: get_in(entry, ["message", "model"]) || acc.model,
      tool_calls: count_tool_calls(content, acc.tool_calls)
    }
  end

  # `message.content` is a list of blocks for Claude-Code assistant
  # messages. Tool-use blocks have `type: "tool_use"` and carry a
  # `name` field (`Bash`, `Read`, `WebFetch`, etc). Accumulate counts
  # per tool name; non-tool-use blocks are ignored.
  defp count_tool_calls(content, acc) when is_list(content) do
    Enum.reduce(content, acc, fn
      %{"type" => "tool_use", "name" => name}, a when is_binary(name) ->
        Map.update(a, name, 1, &(&1 + 1))

      _, a ->
        a
    end)
  end

  defp count_tool_calls(_, acc), do: acc

  # Coerce attacker-controlled token counts to a non-negative
  # integer; anything else degrades to 0 to avoid the
  # ArithmeticError on `+`.
  defp coerce_int(n) when is_integer(n) and n >= 0, do: n
  defp coerce_int(_other), do: 0
end
