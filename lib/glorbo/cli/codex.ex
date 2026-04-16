defmodule Glorbo.CLI.Adapter.Codex do
  @moduledoc """
  `codex` CLI adapter (D-41, D-42; verified against `codex exec --help` on
  2026-04-16).

  ## Invocation shape

      codex exec --json --model <model> --skip-git-repo-check -

  Trailing `-` instructs codex to read the prompt from stdin (per
  `codex exec --help`). `--skip-git-repo-check` disables the refuse-to-run
  behaviour when cwd is not a git repo (agents' workspaces are plain
  directories). `--json` emits machine-parseable output lines.

  ## Per-agent session isolation

  `CODEX_HOME=<workspace>/.glorbo-codex` overrides the default `~/.codex/`
  path (documented in ccusage guide). Rollouts under
  `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-*.jsonl` accumulate cumulative
  `token_count` events; Dispatch picks the latest rollout file after the
  process exits.

  ## Usage parsing (Pitfall 10 / T-03-17)

  `token_count` events carry CUMULATIVE `total_token_usage` counters — NOT
  deltas. The adapter takes the LAST `token_count` event's
  `total_token_usage`, NEVER the sum. Codex does not surface model name per
  event (RESEARCH Assumption A3), so `model: nil` is returned; Dispatch
  falls back to `spec.model` when recording.
  """
  @behaviour Glorbo.CLI.Adapter

  alias Glorbo.Agent.Spec

  @impl true
  def binary, do: System.find_executable("codex")

  @impl true
  def args(%Spec{model: model}, _prompt_path, _opts \\ []) do
    [
      "exec",
      "--json",
      "--model",
      model,
      "--skip-git-repo-check",
      "-"
    ]
  end

  @impl true
  def env(%Spec{}, workspace) when is_binary(workspace) do
    %{"CODEX_HOME" => Path.join(workspace, ".glorbo-codex")}
  end

  @impl true
  def usage_path(%Spec{}, workspace) when is_binary(workspace) do
    {:jsonl_dir, Path.join([workspace, ".glorbo-codex", "sessions"])}
  end

  @impl true
  def parse_usage({:jsonl_file, path}) when is_binary(path) do
    if File.exists?(path) do
      case extract_last_token_event(path) do
        nil -> {:error, :no_token_count}
        event -> {:ok, build_usage(event)}
      end
    else
      {:error, :enoent}
    end
  end

  def parse_usage({:stdout, _blob}), do: {:error, :stdout_not_supported}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Pitfall 10: take the LAST matching event, never the sum.
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

    input = Map.get(usage, "input_tokens") || 0
    cached = Map.get(usage, "cached_input_tokens") || 0
    output = Map.get(usage, "output_tokens") || 0
    reasoning = Map.get(usage, "reasoning_output_tokens") || 0

    %{
      prompt_tokens: input + cached,
      completion_tokens: output + reasoning,
      model: nil
    }
  end
end
