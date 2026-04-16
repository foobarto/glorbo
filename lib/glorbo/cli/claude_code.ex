defmodule Glorbo.CLI.Adapter.ClaudeCode do
  @moduledoc """
  `claude` CLI adapter (D-41, D-42; verified against Claude Code 2.1.110 on
  2026-04-16).

  ## Invocation shape

      claude --print --model <model> --output-format text

  Prompt delivered via stdin (D-03). `--print` triggers non-interactive
  mode; `--output-format text` keeps stdout as plain text (usage telemetry
  comes from the session JSONL, not stdout).

  ## Per-agent session isolation

  `CLAUDE_CONFIG_DIR=<workspace>/.glorbo-claude` reroutes session JSONL
  writes into the agent workspace so sessions don't leak into the
  Director's `~/.claude/projects/`. Auth still lives in `~/.claude/`
  (read-only bind-mounted by Plan 03-05's sandbox).

  ## Usage parsing (Pitfall 5 + T-03-16)

  Session JSONL is streamed line-by-line via `File.stream!/1` (bounded
  memory, no billion-laughs risk beyond `Jason.decode/1`'s default depth).
  Malformed lines are skipped silently. Assistant turns contribute
  `(input_tokens + cache_creation_input_tokens + cache_read_input_tokens)`
  to the prompt total and `output_tokens` to the completion total —
  matching live-probed 2026-04-16 schema (RESEARCH §Code Examples).
  """
  @behaviour Glorbo.CLI.Adapter

  alias Glorbo.Agent.Spec

  @impl true
  def binary, do: System.find_executable("claude")

  @impl true
  def args(%Spec{model: model}, _prompt_path, _opts \\ []) do
    [
      "--print",
      "--model",
      model,
      "--output-format",
      "text"
    ]
  end

  @impl true
  def env(%Spec{}, workspace) when is_binary(workspace) do
    %{"CLAUDE_CONFIG_DIR" => Path.join(workspace, ".glorbo-claude")}
  end

  @impl true
  def usage_path(%Spec{}, workspace) when is_binary(workspace) do
    # Claude encodes the workspace path into a single dir name by replacing
    # every "/" with "-". The resulting encoded dir sits under
    # `<CLAUDE_CONFIG_DIR>/projects/`. Dispatch finds the latest
    # `*.jsonl` in there after the invocation exits.
    encoded = String.replace(workspace, "/", "-")

    {:jsonl_dir, Path.join([workspace, ".glorbo-claude", "projects", encoded])}
  end

  @impl true
  def parse_usage({:jsonl_file, path}) when is_binary(path) do
    if File.exists?(path) do
      {:ok, do_parse_stream(path)}
    else
      {:error, :enoent}
    end
  end

  def parse_usage({:stdout, _blob}), do: {:error, :stdout_not_supported}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp do_parse_stream(path) do
    path
    |> File.stream!()
    |> Stream.map(&decode_line/1)
    |> Stream.reject(&(&1 == :skip))
    |> Stream.filter(&(Map.get(&1, "type") == "assistant"))
    |> Enum.reduce(%{prompt_tokens: 0, completion_tokens: 0, model: nil}, &accumulate/2)
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, entry} -> entry
      {:error, _} -> :skip
    end
  end

  defp accumulate(entry, acc) do
    usage = get_in(entry, ["message", "usage"]) || %{}

    %{
      prompt_tokens:
        acc.prompt_tokens +
          (Map.get(usage, "input_tokens") || 0) +
          (Map.get(usage, "cache_creation_input_tokens") || 0) +
          (Map.get(usage, "cache_read_input_tokens") || 0),
      completion_tokens: acc.completion_tokens + (Map.get(usage, "output_tokens") || 0),
      model: get_in(entry, ["message", "model"]) || acc.model
    }
  end
end
