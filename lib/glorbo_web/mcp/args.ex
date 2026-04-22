defmodule GlorboWeb.MCP.Args do
  @moduledoc """
  Argument validation helpers for MCP tools (GEP-29 wave b).

  MCP clients run locally but are not implicitly trusted to construct
  filesystem paths. Tool arguments like `company`, `agent`, `project`,
  and `task_id` land in `Path.join/1` or `Path.wildcard/1`; if a
  caller supplies `"acme/../other"` or `"*"`, the tool could read
  outside the intended company tree or unexpectedly glob-expand.

  This module provides one gate — `require_slug/1` — that rejects
  anything that isn't a valid slug. Tools should run every path-
  bearing argument through it before building any path.

  Matches `GlorboWeb.Slug.valid?/1` (the same gate LiveView mount
  params use for WR-02 / T-04-08), so the rules stay consistent
  across every surface that touches the filesystem from user input.
  """

  alias GlorboWeb.Slug

  @doc """
  Returns `:ok` if `value` is a valid slug string, otherwise
  `{:error, {:invalid_slug, {field, value}}}`.
  """
  @spec require_slug(term(), atom()) :: :ok | {:error, {:invalid_slug, {atom(), term()}}}
  def require_slug(value, field) do
    if Slug.valid?(value) do
      :ok
    else
      {:error, {:invalid_slug, {field, value}}}
    end
  end

  @doc """
  Run a list of `{field_atom, value}` pairs through `require_slug/2`.
  Returns `:ok` on the first validation pass, or the first
  `{:error, {:invalid_slug, …}}` encountered.
  """
  @spec require_slugs([{atom(), term()}]) ::
          :ok | {:error, {:invalid_slug, {atom(), term()}}}
  def require_slugs(pairs) do
    Enum.reduce_while(pairs, :ok, fn {field, value}, :ok ->
      case require_slug(value, field) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end
end
