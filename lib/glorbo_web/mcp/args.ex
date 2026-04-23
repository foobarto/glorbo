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

  Matches `Glorbo.Slug.valid?/1` (the same gate LiveView mount
  params use for WR-02 / T-04-08), so the rules stay consistent
  across every surface that touches the filesystem from user input.
  """

  alias Glorbo.Slug

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

  @doc """
  Reject values that would break out of a single YAML scalar when
  interpolated into frontmatter (threatmodel T2). Accepts binaries
  up to `max_len` bytes containing no control chars, no `---`
  frontmatter fence, and no `"` that could close a quoted scalar.
  `nil` passes through unchanged (optional arg).
  """
  @spec require_safe_yaml_scalar(term(), atom(), non_neg_integer()) ::
          :ok | {:error, {:invalid_yaml_scalar, {atom(), term()}}}
  def require_safe_yaml_scalar(nil, _field, _max_len), do: :ok
  def require_safe_yaml_scalar("", _field, _max_len), do: :ok

  def require_safe_yaml_scalar(value, field, max_len)
      when is_binary(value) and is_atom(field) and is_integer(max_len) and max_len > 0 do
    cond do
      byte_size(value) > max_len ->
        {:error, {:invalid_yaml_scalar, {field, value}}}

      Regex.match?(~r/[\x00-\x1f\x7f]/, value) ->
        {:error, {:invalid_yaml_scalar, {field, value}}}

      String.contains?(value, "---") ->
        {:error, {:invalid_yaml_scalar, {field, value}}}

      String.contains?(value, "\"") ->
        {:error, {:invalid_yaml_scalar, {field, value}}}

      true ->
        :ok
    end
  end

  def require_safe_yaml_scalar(value, field, _max_len),
    do: {:error, {:invalid_yaml_scalar, {field, value}}}

  @doc """
  Stricter scalar for identifier-like fields (provider/model/template
  names). Same injection rules as `require_safe_yaml_scalar/3`, plus
  the value must match `[A-Za-z][A-Za-z0-9._-]{0,63}`.
  """
  @spec require_safe_identifier(term(), atom()) ::
          :ok | {:error, {:invalid_identifier, {atom(), term()}}}
  def require_safe_identifier(nil, _field), do: :ok
  def require_safe_identifier("", _field), do: :ok

  def require_safe_identifier(value, field)
      when is_binary(value) and is_atom(field) do
    if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9._-]{0,63}\z/, value) do
      :ok
    else
      {:error, {:invalid_identifier, {field, value}}}
    end
  end

  def require_safe_identifier(value, field),
    do: {:error, {:invalid_identifier, {field, value}}}
end
