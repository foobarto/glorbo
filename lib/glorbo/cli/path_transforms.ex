defmodule Glorbo.CLI.PathTransforms do
  @moduledoc """
  Named path-transform registry (GEP-8 §5, §6).

  Invocation templates reference transforms by name; the Loader validates
  names against `known?/1` at boot. Transforms are pure string→string.
  """

  @known %{
    "slash_to_dash" => &__MODULE__.slash_to_dash/1
  }

  @doc "True if `name` names a registered transform."
  @spec known?(String.t()) :: boolean()
  def known?(name) when is_binary(name), do: Map.has_key?(@known, name)
  def known?(_), do: false

  @doc "Apply a named transform to a string. Raises if unknown."
  @spec apply!(String.t(), String.t()) :: String.t()
  def apply!(name, value) when is_binary(name) and is_binary(value) do
    case Map.fetch(@known, name) do
      {:ok, fun} -> fun.(value)
      :error -> raise ArgumentError, "unknown path_transform: #{inspect(name)}"
    end
  end

  @doc """
  `/` → `-` — Claude Code encodes a workspace path into a single flat
  directory name under `<CLAUDE_CONFIG_DIR>/projects/`. See
  `lib/glorbo/cli/claude_code.ex` for the upstream behaviour.
  """
  @spec slash_to_dash(String.t()) :: String.t()
  def slash_to_dash(value) when is_binary(value), do: String.replace(value, "/", "-")
end
