defmodule Glorbo.CLI.NewProjectTest do
  @moduledoc "Plan 05-02 Task 2 — `Glorbo.CLI.Scaffold.Project`."
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Scaffold.{Company, Project}

  setup %{glorbo_home: home} do
    assert {:new_company, 0, _} = Company.run(["acme"])
    {:ok, home: home}
  end

  describe "new project" do
    test "valid <co>/<slug> scaffolds projects/<slug>/ with README + project.md",
         %{home: home} do
      assert {:new_project, 0, out} = Project.run(["acme/website"])
      assert out =~ "✓ created project"

      proj_path = Path.join([home, "companies/acme/projects/website"])
      assert File.dir?(proj_path)
      assert File.exists?(Path.join(proj_path, "README.md"))
      assert File.exists?(Path.join(proj_path, "project.md"))

      pm = File.read!(Path.join(proj_path, "project.md"))
      assert pm =~ "name: website"
      assert pm =~ "status: active"
    end

    test "missing company returns exit 1 with remediation" do
      assert {:new_project, 1, out} = Project.run(["bogus/website"])
      assert out =~ "Company 'bogus' not found"
      assert out =~ "glorbo new company bogus"
    end

    test "re-run is idempotent", %{home: _home} do
      assert {:new_project, 0, _} = Project.run(["acme/website"])
      assert {:new_project, 0, out} = Project.run(["acme/website"])
      assert out =~ "⏭ already exists"
    end

    test "invalid slug returns exit 1" do
      assert {:new_project, 1, out} = Project.run(["acme/Foo!"])
      assert out =~ "Invalid slug"
    end

    test "malformed argv returns usage" do
      assert {:new_project, 1, out} = Project.run(["acme"])
      assert out =~ "Usage: glorbo new project"
    end

    test "empty args returns usage" do
      assert {:new_project, 1, out} = Project.run([])
      assert out =~ "Usage: glorbo new project"
    end

    test "--help returns help text" do
      assert {:new_project, 0, out} = Project.run(["--help"])
      assert out =~ "glorbo new project"
    end
  end
end
