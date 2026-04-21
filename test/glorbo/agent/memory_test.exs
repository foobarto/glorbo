defmodule Glorbo.Agent.MemoryTest do
  @moduledoc """
  Unit tests for `Glorbo.Agent.Memory.compose/3` (GEP-21, #281).

  Covers the reading discipline only (MVP slice). Writing path
  ships in a follow-up GEP-21 iteration.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Memory

  setup do
    base = Path.join(System.tmp_dir!(), "glorbo-memory-#{System.unique_integer([:positive])}")
    company = "acme"
    agent = "ceo"
    memory_dir = Path.join([base, "companies", company, "agents", agent, "memory"])

    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, company: company, agent: agent, memory_dir: memory_dir}
  end

  test "returns empty when the memory dir doesn't exist",
       %{base: base, company: company, agent: agent} do
    assert {:ok, ""} = Memory.compose(base, company, agent)
  end

  test "returns empty when the memory dir exists but is empty",
       %{base: base, company: company, agent: agent, memory_dir: memory_dir} do
    File.mkdir_p!(memory_dir)
    assert {:ok, ""} = Memory.compose(base, company, agent)
  end

  test "includes MEMORY.md verbatim",
       %{base: base, company: company, agent: agent, memory_dir: memory_dir} do
    File.mkdir_p!(memory_dir)
    File.write!(Path.join(memory_dir, "MEMORY.md"), "- first index line\n- second index line\n")

    {:ok, content} = Memory.compose(base, company, agent)
    assert content =~ "## Index"
    assert content =~ "first index line"
    assert content =~ "second index line"
  end

  test "includes memory body files with valid names, ordered newest-first",
       %{base: base, company: company, agent: agent, memory_dir: memory_dir} do
    File.mkdir_p!(memory_dir)

    # Write older body, bump mtime, then newer so we test sort.
    old_path = Path.join(memory_dir, "feedback_commit_style.md")
    new_path = Path.join(memory_dir, "project_glorbo.md")

    File.write!(old_path, "OLD MEMORY BODY")
    # mtime resolution is 1s on most filesystems; make sure the
    # ordering is unambiguous by back-dating the old file.
    past = System.os_time(:second) - 3600
    File.touch!(old_path, past)

    File.write!(new_path, "NEW MEMORY BODY")

    {:ok, content} = Memory.compose(base, company, agent)
    # Both present.
    assert content =~ "OLD MEMORY BODY"
    assert content =~ "NEW MEMORY BODY"
    # Newer appears first.
    old_pos = :binary.match(content, "OLD MEMORY") |> elem(0)
    new_pos = :binary.match(content, "NEW MEMORY") |> elem(0)
    assert new_pos < old_pos
  end

  test "filters out filenames that don't match <type>_<topic>.md",
       %{base: base, company: company, agent: agent, memory_dir: memory_dir} do
    File.mkdir_p!(memory_dir)

    File.write!(Path.join(memory_dir, "feedback_ok.md"), "KEEP ME")
    # Invalid type prefix.
    File.write!(Path.join(memory_dir, "random_nope.md"), "DROP ME 1")
    # Invalid topic characters.
    File.write!(Path.join(memory_dir, "feedback_NOT_SLUG.md"), "DROP ME 2")
    # Not a .md file.
    File.write!(Path.join(memory_dir, "feedback_also.txt"), "DROP ME 3")

    {:ok, content} = Memory.compose(base, company, agent)
    assert content =~ "KEEP ME"
    refute content =~ "DROP ME 1"
    refute content =~ "DROP ME 2"
    refute content =~ "DROP ME 3"
  end

  test "accepts all four type prefixes",
       %{base: base, company: company, agent: agent, memory_dir: memory_dir} do
    File.mkdir_p!(memory_dir)

    for type <- ["user", "feedback", "project", "reference"] do
      File.write!(Path.join(memory_dir, "#{type}_topic.md"), "BODY_#{type}")
    end

    {:ok, content} = Memory.compose(base, company, agent)

    for type <- ["user", "feedback", "project", "reference"] do
      assert content =~ "BODY_#{type}"
    end
  end

  test "caps total output at 20 KB and emits 'older memories' notice",
       %{base: base, company: company, agent: agent, memory_dir: memory_dir} do
    File.mkdir_p!(memory_dir)

    # Write 10 memories @ ~3 KB each = ~30 KB total. With a 20 KB
    # cap only the first 6-ish should fit.
    big_body = String.duplicate("x", 3000)

    for i <- 1..10 do
      File.write!(Path.join(memory_dir, "feedback_topic#{i}.md"), big_body)
      # Stagger mtimes so ordering is deterministic.
      File.touch!(
        Path.join(memory_dir, "feedback_topic#{i}.md"),
        System.os_time(:second) + i
      )
    end

    {:ok, content} = Memory.compose(base, company, agent)
    assert byte_size(content) <= 20 * 1024 + 200
    assert content =~ "older memories not shown"
  end

  test "handles malformed index gracefully (no crash on binary junk)",
       %{base: base, company: company, agent: agent, memory_dir: memory_dir} do
    File.mkdir_p!(memory_dir)
    File.write!(Path.join(memory_dir, "MEMORY.md"), <<0, 1, 2, 3, "binary trash">>)
    File.write!(Path.join(memory_dir, "feedback_ok.md"), "still readable")

    assert {:ok, content} = Memory.compose(base, company, agent)
    assert content =~ "still readable"
  end

  test "ignores MEMORY.md when present but empty",
       %{base: base, company: company, agent: agent, memory_dir: memory_dir} do
    File.mkdir_p!(memory_dir)
    File.write!(Path.join(memory_dir, "MEMORY.md"), "")
    File.write!(Path.join(memory_dir, "feedback_x.md"), "BODY ONLY")

    {:ok, content} = Memory.compose(base, company, agent)
    assert content =~ "BODY ONLY"
    refute content =~ "## Index"
  end
end
