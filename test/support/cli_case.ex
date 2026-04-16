defmodule GlorboTest.CLICase do
  @moduledoc """
  Shared ExUnit case for Phase-5 CLI verb tests. Per-test hermetic
  `~/.glorbo/` via `Glorbo.Test.TmpGlorboHome` + `GLORBO_HOME` env-var
  override.

  Usage:

      defmodule Glorbo.CLI.UpTest do
        use GlorboTest.CLICase, async: false   # pidfile ops NOT parallel-safe

        test "up writes pidfile and returns :up tuple", %{glorbo_home: home} do
          # ... use Path.join(home, "run/glorbo.pid") etc.
        end
      end

  Every verb test that mutates `~/.glorbo/` MUST use `async: false` to
  avoid `GLORBO_HOME` env-var races across tests.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Glorbo.Test.TmpGlorboHome
    end
  end

  setup _tags do
    home = Glorbo.Test.TmpGlorboHome.setup()
    prior = System.get_env("GLORBO_HOME")
    System.put_env("GLORBO_HOME", home)

    on_exit(fn ->
      case prior do
        nil -> System.delete_env("GLORBO_HOME")
        v -> System.put_env("GLORBO_HOME", v)
      end
    end)

    {:ok, glorbo_home: home}
  end
end
