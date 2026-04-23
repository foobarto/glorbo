defmodule Glorbo.Filesystem.FrontmatterWriterTest do
  @moduledoc """
  `Glorbo.Filesystem.FrontmatterWriter.update_keys/3` — shared helper
  used by AgentLive Configuration (§5) and TaskDefinition.write_frontmatter.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Filesystem.FrontmatterWriter

  setup do
    path = Path.join(System.tmp_dir!(), "fmw-test-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "rewrites only the requested keys, leaves unknowns alone", %{path: path} do
    File.write!(path, """
    ---
    kind: agent/v1
    name: alice
    role: engineer
    notes: keep me
    ---

    body
    """)

    :ok = FrontmatterWriter.update_keys(path, %{"role" => "ceo"})

    content = File.read!(path)
    assert content =~ "role: ceo"
    assert content =~ "name: alice"
    assert content =~ "notes: keep me"
    assert content =~ "\n\nbody\n"
  end

  test "quotes YAML-special values", %{path: path} do
    File.write!(path, """
    ---
    heartbeat: "* * * * *"
    ---
    """)

    :ok = FrontmatterWriter.update_keys(path, %{"heartbeat" => "*/5 * * * *"})
    assert File.read!(path) =~ ~s(heartbeat: "*/5 * * * *")
  end

  test "missing frontmatter → {:error, :no_frontmatter}", %{path: path} do
    File.write!(path, "just a body, no fences")
    assert {:error, :no_frontmatter} = FrontmatterWriter.update_keys(path, %{"x" => "y"})
  end

  test "atomic_write survives mid-write via rename, no .tmp left", %{path: path} do
    :ok = FrontmatterWriter.atomic_write(path, "hello")
    assert File.read!(path) == "hello"
    refute File.exists?(path <> ".tmp")
  end

  test "yaml_scalar quotes booleans and null", _ do
    assert FrontmatterWriter.yaml_scalar("true") == ~s("true")
    assert FrontmatterWriter.yaml_scalar("null") == ~s("null")
    assert FrontmatterWriter.yaml_scalar("plain") == "plain"
    assert FrontmatterWriter.yaml_scalar(42) == "42"
    assert FrontmatterWriter.yaml_scalar(nil) == "null"
  end
end
