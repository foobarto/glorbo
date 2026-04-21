defmodule BenchFixture.Auth do
  @moduledoc """
  Session / token authentication helpers.

  NOTE: this is a bench fixture. The bug in `session_timeout/0` is
  intentional — the benchmark task bugs-1 asks the engineer to fix
  it.
  """

  @doc """
  Returns the session-token lifetime in seconds.

  Intended: 60 minutes (3,600 seconds).
  Bug: the current constant is `60 * 60 * 60` = 60 hours.
  """
  def session_timeout do
    60 * 60 * 60
  end

  @doc """
  Validates a bearer token shape. Returns `:ok` or
  `{:error, :bad_token}`. Not the subject of any open task;
  included for realism.
  """
  def validate_token(token) when is_binary(token) do
    case String.match?(token, ~r/\A[A-Za-z0-9\-_]{40,}\z/) do
      true -> :ok
      false -> {:error, :bad_token}
    end
  end

  def validate_token(_), do: {:error, :bad_token}
end
