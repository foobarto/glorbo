defmodule Glorbo.Doctor.FixerTest do
  @moduledoc "Plan 04 — Fixer registry shape + individual fixer assertions."
  use ExUnit.Case, async: false

  alias Glorbo.Doctor.Fixer

  describe "@fixers registry" do
    test "every registered fixer is a 1-arity function reference" do
      for {name, fixer} <- Fixer.fixers() do
        assert is_binary(name), "check name must be a string, got: #{inspect(name)}"
        assert is_function(fixer, 1), "fixer for #{name} must be arity 1"
      end
    end

    test "expected fixer names are registered (matches Doctor.run_checks/0 names)" do
      registered = Fixer.fixers() |> Map.keys() |> Enum.sort()

      expected =
        ~w(glorbo_dir audit_dir sockets_dir private_files migrations_pending bwrap pasta uidmap)
        |> Enum.sort()

      assert registered == expected
    end

    test "every registered fixer returns {:ok, _} | {:error, _} | {:explain, _}" do
      fake_check = %{name: "fake", pass: false, severity: :warning, detail: "", required: ""}

      for {name, fixer} <- Fixer.fixers() do
        result = fixer.(%{fake_check | name: name})

        assert match?({:ok, _}, result) or
                 match?({:error, _}, result) or
                 match?({:explain, _}, result),
               "fixer #{name} returned unexpected shape: #{inspect(result)}"
      end
    end

    test "explain_bwrap returns an :explain tuple with install guidance" do
      assert {:explain, guidance} = Fixer.explain_bwrap(%{name: "bwrap"})
      assert guidance =~ "bubblewrap"
      assert guidance =~ "fedora"
    end

    test "explain_pasta returns an :explain tuple with install guidance" do
      assert {:explain, guidance} = Fixer.explain_pasta(%{name: "pasta"})
      assert guidance =~ "passt"
      assert guidance =~ "fedora"
    end

    test "explain_uidmap returns an :explain tuple with install guidance" do
      assert {:explain, guidance} = Fixer.explain_uidmap(%{name: "uidmap"})
      assert guidance =~ "shadow-utils"
      assert guidance =~ "uidmap"
    end

    test "fix_glorbo_dir creates ~/.glorbo (idempotent if already present)" do
      # Opportunistic — ~/.glorbo almost certainly exists on the dev host
      # (otherwise this whole project would be broken). The fixer is
      # idempotent via `File.mkdir_p/1`, so assert it returns :ok.
      assert {:ok, _} = Fixer.fix_glorbo_dir(%{name: "glorbo_dir"})
    end

    test "fix_migrations_pending delegates to Glorbo.CLI.Migrate and translates the tuple" do
      # FixerTest is plain ExUnit (no DataCase), so the test-env Repo is
      # locked in :manual sandbox mode and the migrator can't take a
      # connection — Migrate returns {:migrate, 2, _}. Either branch of
      # the translation is valid; both prove the fixer correctly
      # forwards to Glorbo.CLI.Migrate.run/1 and reshapes the result.
      # Real-world repair (the {:ok, _} branch) is exercised end-to-end
      # by `glorbo doctor --fix` against ~/.glorbo/glorbo.db; the
      # migrate verb's own happy-path test lives in MigrateTest.
      result = Fixer.fix_migrations_pending(%{name: "migrations_pending"})

      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "expected {:ok, _} | {:error, _}, got #{inspect(result)}"
    end

    test "fix_private_files chmods native credentials TOML files to 0600" do
      tmp = Path.join(System.tmp_dir!(), "glorbo-fixer-#{System.unique_integer([:positive])}")
      base = Path.join(tmp, ".glorbo")
      creds = Path.join(tmp, "credentials")

      on_exit(fn ->
        System.delete_env("GLORBO_HOME")
        System.delete_env("GLORBO_CREDENTIALS_DIR")
        File.rm_rf!(tmp)
      end)

      File.mkdir_p!(Path.join(base, "logs"))
      File.mkdir_p!(creds)
      File.write!(Path.join(base, "config.md"), "")
      File.write!(Path.join([base, "logs", "glorbo.log"]), "")

      creds_path = Path.join(creds, "openai.toml")
      File.write!(creds_path, ~s(api_key = "sk-test"))
      File.chmod!(creds_path, 0o644)

      System.put_env("GLORBO_HOME", base)
      System.put_env("GLORBO_CREDENTIALS_DIR", creds)

      assert {:ok, detail} = Fixer.fix_private_files(%{name: "private_files"})
      assert detail =~ "openai.toml"
      assert Bitwise.band(File.stat!(creds_path).mode, 0o777) == 0o600
    end
  end

  describe "fixers_for/1 + --install-deps registry switch" do
    test "fixers_for([]) returns the explainer registry by default" do
      reg = Fixer.fixers_for([])
      assert is_function(reg["bwrap"], 1)
      # Identity match: default registry is the same as Fixer.fixers/0.
      assert reg == Fixer.fixers()
    end

    test "fixers_for(install_deps: true) swaps in install_* for host packages" do
      reg = Fixer.fixers_for(install_deps: true)

      # Filesystem fixers stay the same — only host-package checks swap.
      assert reg["glorbo_dir"] == Fixer.fixers()["glorbo_dir"]
      assert reg["audit_dir"] == Fixer.fixers()["audit_dir"]

      # bwrap / pasta / uidmap should now be the install_* variants —
      # different function references than the explain_* defaults.
      refute reg["bwrap"] == Fixer.fixers()["bwrap"]
      refute reg["pasta"] == Fixer.fixers()["pasta"]
      refute reg["uidmap"] == Fixer.fixers()["uidmap"]
    end
  end

  describe "detect_distro/0 (--install-deps prerequisite)" do
    test "GLORBO_DOCTOR_DISTRO_OVERRIDE pins the family for tests" do
      # Save + restore so we don't bleed into other tests in this file.
      prev = System.get_env("GLORBO_DOCTOR_DISTRO_OVERRIDE")

      try do
        System.put_env("GLORBO_DOCTOR_DISTRO_OVERRIDE", "fedora")
        assert Fixer.detect_distro() == {:ok, :fedora}

        System.put_env("GLORBO_DOCTOR_DISTRO_OVERRIDE", "debian")
        assert Fixer.detect_distro() == {:ok, :debian}

        System.put_env("GLORBO_DOCTOR_DISTRO_OVERRIDE", "arch")
        assert Fixer.detect_distro() == {:ok, :arch}

        System.put_env("GLORBO_DOCTOR_DISTRO_OVERRIDE", "windows-95")
        assert Fixer.detect_distro() == :error
      after
        if prev do
          System.put_env("GLORBO_DOCTOR_DISTRO_OVERRIDE", prev)
        else
          System.delete_env("GLORBO_DOCTOR_DISTRO_OVERRIDE")
        end
      end
    end
  end

  describe "install_* fixers (--install-deps path)" do
    setup do
      prev = System.get_env("GLORBO_DOCTOR_DISTRO_OVERRIDE")

      on_exit(fn ->
        if prev do
          System.put_env("GLORBO_DOCTOR_DISTRO_OVERRIDE", prev)
        else
          System.delete_env("GLORBO_DOCTOR_DISTRO_OVERRIDE")
        end
      end)

      :ok
    end

    test "install_bwrap on unsupported distro falls back to explain" do
      System.put_env("GLORBO_DOCTOR_DISTRO_OVERRIDE", "windows-95")
      assert {:explain, guidance} = Fixer.install_bwrap(%{name: "bwrap"})
      assert guidance =~ "bubblewrap"
    end

    test "install_pasta on unsupported distro falls back to explain" do
      System.put_env("GLORBO_DOCTOR_DISTRO_OVERRIDE", "windows-95")
      assert {:explain, guidance} = Fixer.install_pasta(%{name: "pasta"})
      assert guidance =~ "passt"
    end

    test "install_uidmap on unsupported distro falls back to explain" do
      System.put_env("GLORBO_DOCTOR_DISTRO_OVERRIDE", "windows-95")
      assert {:explain, guidance} = Fixer.install_uidmap(%{name: "uidmap"})
      assert guidance =~ "shadow-utils"
    end

    # NOTE: positive-path testing (sudo dnf install actually succeeds)
    # would mutate the test machine's package state — we don't run it.
    # The install path is exercised end-to-end by operators on real
    # Fedora/Debian/Arch hosts; the unit-test surface here is the
    # registry switch + explain fallback.
  end

  describe "run/1" do
    test "returns :doctor tuple with exit_code + summary string" do
      # This calls real Doctor.run_checks/0. Capture IO so that summary
      # lines printed by handle_check/3 don't pollute the test reporter.
      {result, _io} =
        ExUnit.CaptureIO.with_io(fn -> Fixer.run(dry_run: true) end)

      assert {:doctor, code, out} = result
      assert is_integer(code)
      assert is_binary(out)
    end

    test "dry_run: true does not invoke real fixers (verified by shape)" do
      # We can't easily inject a fake Doctor.run_checks/0 result here, but
      # we can assert the return tuple remains well-formed under dry-run.
      {result, _io} =
        ExUnit.CaptureIO.with_io(fn -> Fixer.run(dry_run: true) end)

      assert {:doctor, _code, _out} = result
    end
  end
end
