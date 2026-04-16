defmodule Glorbo.CLI.NewCompanyTest do
  @moduledoc "Plan 05-02 Task 2 — `Glorbo.CLI.Scaffold.Company`."
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Scaffold.Company

  describe "new company" do
    test "valid slug scaffolds companies/<slug>/", %{glorbo_home: home} do
      assert {:new_company, 0, out} = Company.run(["acme"])
      assert out =~ "✓ created company"
      assert out =~ "acme"

      assert File.exists?(Path.join([home, "companies/acme/company.md"]))

      for sub <- ~w(agents projects channels audit) do
        assert File.dir?(Path.join([home, "companies/acme", sub])),
               "missing subdir: #{sub}"
      end

      # company.md contains the expected frontmatter.
      content = File.read!(Path.join([home, "companies/acme/company.md"]))
      assert content =~ "name: acme"
      assert content =~ ~s(mission: "")
    end

    test "invalid slug (Acme!) returns exit 1" do
      assert {:new_company, 1, out} = Company.run(["Acme!"])
      assert out =~ "Invalid slug"
      assert out =~ "lowercase"
    end

    test "invalid slug with uppercase letters returns exit 1" do
      assert {:new_company, 1, out} = Company.run(["ACME"])
      assert out =~ "Invalid slug"
    end

    test "re-run is idempotent (⏭ already exists)", %{glorbo_home: home} do
      assert {:new_company, 0, _} = Company.run(["acme"])

      # Capture mtime before re-run.
      path = Path.join([home, "companies/acme/company.md"])
      mtime_before = File.stat!(path).mtime

      # Sleep for 1s — mtime resolution is 1s on some filesystems.
      Process.sleep(1100)

      assert {:new_company, 0, out} = Company.run(["acme"])
      assert out =~ "⏭ already exists"

      # File should not have been touched.
      mtime_after = File.stat!(path).mtime
      assert mtime_before == mtime_after
    end

    test "empty args returns exit 1 with usage" do
      assert {:new_company, 1, out} = Company.run([])
      assert out =~ "Usage: glorbo new company"
    end

    test "--help returns help text" do
      assert {:new_company, 0, out} = Company.run(["--help"])
      assert out =~ "glorbo new company"
      assert out =~ "USAGE"
    end
  end
end
