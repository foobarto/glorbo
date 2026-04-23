defmodule Glorbo.Company.GoalsTest do
  use ExUnit.Case, async: true

  alias Glorbo.Company.Goals

  setup do
    dir = System.tmp_dir!() |> Path.join("glorbo-goals-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, body) do
    path = Path.join(dir, "company.md")
    File.write!(path, body)
    path
  end

  describe "add_goal/2" do
    test "appends to an existing goals list", %{dir: dir} do
      path =
        write(dir, """
        ---
        kind: company/v1
        slug: acme
        name: Acme
        goals:
          - slug: foo
            title: Foo
        ---

        body content
        """)

      assert :ok = Goals.add_goal(path, %{slug: "bar", title: "Bar"})

      content = File.read!(path)
      assert content =~ ~r/- slug: foo\s+title: Foo/
      assert content =~ ~r/- slug: bar\s+title: Bar/
      assert String.contains?(content, "body content")
    end

    test "creates the goals block when absent", %{dir: dir} do
      path =
        write(dir, """
        ---
        kind: company/v1
        slug: acme
        name: Acme
        ---

        body
        """)

      assert :ok = Goals.add_goal(path, %{slug: "first", title: "First"})

      content = File.read!(path)
      assert content =~ "goals:"
      assert content =~ "- slug: first"
      assert content =~ "title: First"
      assert String.contains?(content, "kind: company/v1")
    end

    test "stores optional description", %{dir: dir} do
      path = write(dir, "---\nkind: company/v1\nslug: acme\nname: Acme\n---\n")

      assert :ok =
               Goals.add_goal(path, %{slug: "a", title: "A", description: "why we care"})

      # After yaml_scalar was unified on `FrontmatterWriter.yaml_scalar/1`
      # (round-4 sweep), bare strings containing whitespace are quoted —
      # the canonical escaper is strict-by-default. Either the quoted or
      # the original bare form is a valid YAML emission; assert on
      # what the canonical escaper produces today.
      assert File.read!(path) =~ ~s(description: "why we care")
    end

    test "rejects empty slug", %{dir: dir} do
      path = write(dir, "---\nkind: company/v1\nslug: acme\nname: Acme\n---\n")
      assert {:error, :slug_required} = Goals.add_goal(path, %{slug: "", title: "A"})
    end

    test "rejects invalid slug", %{dir: dir} do
      path = write(dir, "---\nkind: company/v1\nslug: acme\nname: Acme\n---\n")
      assert {:error, :invalid_slug} = Goals.add_goal(path, %{slug: "Foo Bar", title: "A"})
    end

    test "rejects duplicate slug", %{dir: dir} do
      path =
        write(dir, """
        ---
        kind: company/v1
        slug: acme
        name: Acme
        goals:
          - slug: foo
            title: Foo
        ---
        """)

      assert {:error, :slug_taken} = Goals.add_goal(path, %{slug: "foo", title: "x"})
    end

    test "rejects empty title", %{dir: dir} do
      path = write(dir, "---\nkind: company/v1\nslug: acme\nname: Acme\n---\n")
      assert {:error, :title_required} = Goals.add_goal(path, %{slug: "valid", title: ""})
    end
  end
end
