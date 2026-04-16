defmodule Glorbo.CLI.Adapter.GeminiCli do
  @moduledoc """
  `gemini` CLI adapter (D-41, D-42; verified against Gemini CLI with
  `--output-format json` on 2026-04-16).

  ## Invocation shape

      gemini -m <model> --output-format json --approval-mode yolo

  Prompt delivered via stdin (`-p` + stdin append semantics — see
  `gemini --help`). `--approval-mode yolo` auto-approves all tool actions
  since bwrap sandbox is the real containment layer. `--output-format json`
  emits a single JSON blob to stdout on exit, which Dispatch captures and
  passes to `parse_usage/1` (Pitfall 6 — full-capture, not streaming).

  ## Per-agent session isolation

  Gemini CLI uses `~/.gemini/` unconditionally for OAuth and session state;
  there is no documented env var equivalent to `CLAUDE_CONFIG_DIR` in the
  CLI version installed on the dev host. For v0.0.1 we rely on Plan 03-05
  binding `~/.gemini/` read-only + the sandbox cwd redirecting relative
  writes. `env/2` returns an empty map until a dedicated env override ships.

  ## Usage parsing (RESEARCH Open Question 3)

  `stats.models.<model>.tokens` is a dict keyed by model name. Typically a
  single key; if multiple we SUM across them defensively (matches D-30
  undercount-tradeoff for unknown model rates). Per RESEARCH:

    * `prompt_tokens = tokens.prompt + tokens.cached`
    * `completion_tokens = tokens.candidates + tokens.thoughts + tokens.tool`
  """
  @behaviour Glorbo.CLI.Adapter

  alias Glorbo.Agent.Spec

  @impl true
  def binary, do: System.find_executable("gemini")

  @impl true
  def args(%Spec{model: model}, _prompt_path, _opts \\ []) do
    [
      "-m",
      model,
      "--output-format",
      "json",
      "--approval-mode",
      "yolo"
    ]
  end

  @impl true
  def env(%Spec{}, _workspace), do: %{}

  @impl true
  def usage_path(%Spec{}, _workspace), do: :stdout

  @impl true
  def parse_usage({:stdout, blob}) when is_binary(blob) do
    case Jason.decode(blob) do
      {:ok, %{"stats" => %{"models" => models}}} when is_map(models) and map_size(models) > 0 ->
        {:ok, reduce_models(models)}

      {:ok, _other} ->
        {:error, :no_stats}

      {:error, _} ->
        {:error, :json_decode_error}
    end
  end

  def parse_usage({:jsonl_file, _path}), do: {:error, :jsonl_not_supported}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

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
