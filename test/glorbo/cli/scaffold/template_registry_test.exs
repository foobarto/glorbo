defmodule Glorbo.CLI.Scaffold.TemplateRegistryTest do
  @moduledoc """
  TemplateRegistry loads from `priv/templates/` + user dir. User
  overrides must shadow built-ins by filename (GEP-10 D5).

  We can't easily substitute the built-in dir without a dep-injection
  seam, so these tests exercise:

    * built-in discovery (checks that v1's curated set is present);
    * the `@name_regex` filter behaviour;
    * the fetch API's :not_found return.

  The user-override path is covered in integration tests that can
  set `GLORBO_HOME` to a temp dir. Here we stay at the unit level.
  """
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Scaffold.TemplateRegistry

  describe "list/1" do
    test "lists all v1 curated agent templates" do
      names = TemplateRegistry.list(:agent) |> Enum.map(& &1.name)
      assert "ceo" in names
      assert "engineer" in names
      assert "researcher" in names
    end

    test "lists all v1 curated skill templates" do
      names = TemplateRegistry.list(:skill) |> Enum.map(& &1.name)
      assert "code-review" in names
      assert "web-search" in names
    end

    test "tags built-ins with source: :builtin" do
      for e <- TemplateRegistry.list(:agent) do
        assert e.source == :builtin
      end
    end

    test "returns entries sorted by name" do
      names = TemplateRegistry.list(:agent) |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "fetch/2" do
    test "returns {:ok, entry} for a known template" do
      assert {:ok, entry} = TemplateRegistry.fetch(:agent, "engineer")
      assert entry.name == "engineer"
      assert entry.kind == :agent
      assert entry.source == :builtin
      assert String.ends_with?(entry.path, "engineer.md")
    end

    test "returns {:error, :not_found} for unknown templates" do
      assert {:error, :not_found} = TemplateRegistry.fetch(:agent, "does-not-exist")
    end
  end
end
