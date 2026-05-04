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
      import GlorboTest.CLICase, only: [fake_daemon_binary!: 1]
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

  @doc """
  Write a long-lived, argv-tolerant shell script to `<home>/fake_glorbo.sh`
  and return its path. Used by Up/Down tests as a `GLORBO_BINARY_PATH` stand-in.

  The prior `/bin/sleep` fixture flaked on Fedora coreutils (which rejects
  `sleep serve` with an error and exits instantly, before
  `Port.info(port, :os_pid)` in `Daemon.spawn_detached/2` could read the pid).
  A shell script that ignores its args and sleeps is stable across distros.

  The script also dumps `PHX_SERVER` to `<home>/fake_glorbo.env` so tests
  can assert the parent passed it through; an empty file means the var
  was unset.
  """
  @spec fake_daemon_binary!(Path.t()) :: Path.t()
  def fake_daemon_binary!(home) do
    path = Path.join(home, "fake_glorbo.sh")
    env_path = Path.join(home, "fake_glorbo.env")

    script = """
    #!/bin/sh
    printf 'PHX_SERVER=%s\\n' "${PHX_SERVER}" > "#{env_path}"
    sleep 60
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end
end
