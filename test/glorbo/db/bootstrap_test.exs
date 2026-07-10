defmodule Glorbo.DB.BootstrapTest do
  use ExUnit.Case, async: true

  alias Glorbo.DB.Bootstrap

  test "reports a missing migration directory as an explicit error" do
    assert {:error, :missing_migrations} =
             Bootstrap.run(migrations_path_fun: fn -> {:error, :missing_migrations} end)
  end

  test "preserves migrator failures instead of treating boot as successful" do
    assert {:error, {:migration_failed, :locked}} =
             Bootstrap.run(
               migrations_path_fun: fn -> {:ok, "/tmp/migrations"} end,
               migrator_fun: fn _path -> {:error, {:migration_failed, :locked}} end
             )
  end

  test "returns the applied versions on success" do
    assert {:ok, [20_260_101_000_000]} =
             Bootstrap.run(
               migrations_path_fun: fn -> {:ok, "/tmp/migrations"} end,
               migrator_fun: fn _path -> {:ok, [20_260_101_000_000]} end
             )
  end
end
