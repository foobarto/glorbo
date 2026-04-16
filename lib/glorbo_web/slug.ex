defmodule GlorboWeb.Slug do
  @moduledoc """
  Shared slug regex validator for LiveView mount params (WR-02).

  Every LiveView that accepts `:company`, `:agent`, or `:channel` from
  the URL must gate the value through `valid?/1` before using it to
  construct filesystem paths. `GlorboWeb.Actions` already enforces the
  same regex at the write path; this module provides the complementary
  read-path defense so a malicious URL cannot probe sibling directories
  under `~/.glorbo/` (e.g. `/companies/..` → `base/agents/`).

  See T-04-08 in the Phase 4 threat register. The regex matches the
  one in `GlorboWeb.Actions` (`@slug_re`) — keep them in sync.
  """

  @slug_re ~r/\A[a-z0-9-]+\z/

  @doc """
  Returns `true` iff the value is a binary that matches
  `~r/\\A[a-z0-9-]+\\z/`. Everything else (nil, non-binary, empty
  string, any string with uppercase / whitespace / `..` / `/`) is
  rejected.
  """
  @spec valid?(term()) :: boolean()
  def valid?(s) when is_binary(s), do: Regex.match?(@slug_re, s)
  def valid?(_), do: false
end
