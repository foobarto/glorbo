defmodule Glorbo.CLI.Parsers do
  @moduledoc """
  Named-parser registry for CLI usage telemetry (GEP-8 §5, §6, D6).

  Each parser is a module implementing `parse/1` that takes a source
  (`{:jsonl_file, path}` or `{:stdout, binary}`) and returns
  `{:ok, usage()}` or `{:error, reason}`.

  The registry is a closed set known at compile time. Loader validates
  TOML entries against `known?/1`; unknown names hard-fail at boot.
  """

  @known %{
    "none" => Glorbo.CLI.Parsers.None,
    "claude_jsonl" => Glorbo.CLI.Parsers.ClaudeJsonl,
    "gemini_stdout" => Glorbo.CLI.Parsers.GeminiStdout,
    "codex_jsonl" => Glorbo.CLI.Parsers.CodexJsonl
  }

  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          model: String.t() | nil
        }

  @type source ::
          {:jsonl_file, String.t()}
          | {:stdout, binary()}

  @doc "True if `name` is a registered parser."
  @spec known?(String.t()) :: boolean()
  def known?(name) when is_binary(name), do: Map.has_key?(@known, name)
  def known?(_), do: false

  @doc "Return the module for a registered parser name."
  @spec module_for(String.t()) :: module() | nil
  def module_for(name) when is_binary(name), do: Map.get(@known, name)

  @doc "List all known parser names."
  @spec known_names() :: [String.t()]
  def known_names, do: Map.keys(@known)
end
