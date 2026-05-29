defmodule Glorbo.CLI.Lifecycle.ResetPasswordTest do
  @moduledoc "GEP-0053 — `glorbo reset-password` recovery path."
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Lifecycle.{Pidfile, ResetPassword}

  setup %{glorbo_home: home} do
    # Configured instance: a real config.md (token etc.) + a passphrase hash.
    {:ok, _} = Glorbo.Config.load(home)
    :ok = Glorbo.Config.put_password_hash(home, Pbkdf2.hash_pwd_salt("the-passphrase"))
    :ok
  end

  test "clears the passphrase → back to bootstrap (exit 0)", %{glorbo_home: home} do
    assert {:ok, %{director_password_hash: hash}} = Glorbo.Config.load(home)
    assert is_binary(hash)

    assert {:reset_password, 0, out} = ResetPassword.run([])
    assert out =~ "first-run setup"

    assert {:ok, %{director_password_hash: nil}} = Glorbo.Config.load(home)
  end

  test "refuses while the daemon is running, leaving the hash intact (exit 1)", %{
    glorbo_home: home
  } do
    Pidfile.write!(System.pid() |> String.to_integer(), home)

    assert {:reset_password, 1, out} = ResetPassword.run([])
    assert out =~ "glorbo down"

    # The passphrase was NOT cleared.
    assert {:ok, %{director_password_hash: hash}} = Glorbo.Config.load(home)
    assert is_binary(hash)
  end

  test "--help prints usage (exit 0)" do
    assert {:reset_password, 0, out} = ResetPassword.run(["--help"])
    assert out =~ "glorbo reset-password"
  end
end
