defmodule Glorbo.CLI.Parsers.None do
  @moduledoc """
  No-op usage parser (GEP-8 §5).

  Returns an explicit `{:error, :untracked}` — callers should treat this
  as "no budget tracking" rather than a fault. Providers declaring
  `usage_parser = "none"` in TOML bind to this module.
  """

  @spec parse(Glorbo.CLI.Parsers.source()) :: {:error, :untracked}
  def parse(_source), do: {:error, :untracked}
end
