defmodule Glorbo.RepoWalTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Verifies SQLite WAL journaling is active on the test Repo — the
  grep-level check in `test/config_test.exs` only proves the string is
  present in configs; this proves it was actually applied to the driver.
  """

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Glorbo.Repo)
    :ok
  end

  test "SQLite journal_mode on test repo is WAL" do
    result = SQL.query!(Glorbo.Repo, "PRAGMA journal_mode;", [])

    assert result.rows == [["wal"]],
           "Expected PRAGMA journal_mode to return [[\"wal\"]], got #{inspect(result.rows)}"
  end
end
