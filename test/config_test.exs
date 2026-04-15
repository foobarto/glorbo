defmodule ConfigTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Static grep-level assertion that SQLite WAL mode is configured in every
  environment. This is the cheapest check we can make — it runs in < 1ms and
  catches accidental config drift long before the Repo-integration test in
  `test/glorbo/repo_wal_test.exs` boots.
  """

  @env_configs ~w(config/dev.exs config/test.exs config/runtime.exs)

  for path <- @env_configs do
    test "#{path} contains journal_mode: :wal" do
      body = File.read!(unquote(path))

      assert body =~ "journal_mode: :wal",
             "Expected #{unquote(path)} to contain `journal_mode: :wal` (per D-04)"
    end
  end
end
