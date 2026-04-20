defmodule Glorbo.SearchTest do
  use ExUnit.Case, async: true

  alias Glorbo.Search

  setup do
    base = Path.join(System.tmp_dir!(), "glorbo-search-#{System.unique_integer([:positive])}")
    company = "acme"
    tasks_dir = Path.join([base, "companies", company, "projects", "foo", "tasks"])
    File.mkdir_p!(tasks_dir)
    on_exit(fn -> File.rm_rf!(base) end)

    File.write!(Path.join(tasks_dir, "foo-1.md"), """
    ---
    title: Refactor dispatch pipeline
    status: todo
    ---
    body
    """)

    File.write!(Path.join(tasks_dir, "foo-2.md"), """
    ---
    title: Ship release candidate
    status: done
    ---
    body
    """)

    File.write!(Path.join(tasks_dir, "foo-3.md"), """
    ---
    title: Investigate weird audit gap
    status: in-progress
    ---
    body
    """)

    {:ok, base: base, company: company}
  end

  test "empty query returns []", %{base: base, company: co} do
    assert [] = Search.search(base, co, "")
    assert [] = Search.search(base, co, nil)
    assert [] = Search.search(base, co, "   ")
  end

  test "matches task title by substring", %{base: base, company: co} do
    results = Search.search(base, co, "refactor")
    assert length(results) == 1
    assert hd(results).label =~ "Refactor"
    assert hd(results).href == "/companies/acme/tasks/foo-1"
    assert hd(results).kind == "task"
  end

  test "prefix match outranks substring match", %{base: base, company: co} do
    [first | _] = Search.search(base, co, "ship")
    assert first.label =~ "Ship release"
    assert first.score == 100
  end

  test "id match works as fallback", %{base: base, company: co} do
    results = Search.search(base, co, "foo-2")
    assert [res] = results
    assert res.href == "/companies/acme/tasks/foo-2"
  end

  test "case-insensitive", %{base: base, company: co} do
    assert [_] = Search.search(base, co, "DISPATCH")
    assert [_] = Search.search(base, co, "Dispatch")
  end

  test "respects limit", %{base: base, company: co} do
    results = Search.search(base, co, "foo", limit: 1)
    assert length(results) == 1
  end

  test "no-match returns []", %{base: base, company: co} do
    assert [] = Search.search(base, co, "xylophone")
  end

  test "missing company returns []", %{base: base} do
    assert [] = Search.search(base, "ghost", "anything")
  end

  # #240 — title cache skips reparse when mtime unchanged.
  test "caches titles by (path, mtime) so repeated searches skip File.read",
       %{base: base, company: co} do
    # Prime the cache with a first search.
    assert [_] = Search.search(base, co, "refactor")

    # Rewrite the file's title WITHOUT changing mtime (Unix allows
    # touch-m to pin it). The cache should still return the old
    # title — proves the cache path is live and not bypassed.
    tasks_dir = Path.join([base, "companies", co, "projects/foo/tasks"])
    path = Path.join(tasks_dir, "foo-1.md")
    {:ok, %File.Stat{mtime: original_mtime}} = File.stat(path)

    File.write!(path, """
    ---
    title: Totally new title
    status: todo
    ---
    body
    """)

    # Restore the old mtime so the cache key still matches.
    File.touch!(path, original_mtime)

    assert [hit] = Search.search(base, co, "refactor")
    assert hit.label =~ "Refactor dispatch pipeline"
    # The file on disk has the new title, but cache returns old one.
    refute hit.label =~ "Totally new title"

    # Bumping mtime to a distinct future time invalidates the cache.
    # (Plain File.touch! would not — its resolution is 1s and the test
    # runs faster than that.)
    future_mtime =
      original_mtime
      |> :calendar.datetime_to_gregorian_seconds()
      |> Kernel.+(10)
      |> :calendar.gregorian_seconds_to_datetime()

    File.touch!(path, future_mtime)
    assert [] = Search.search(base, co, "refactor")
    assert [_] = Search.search(base, co, "totally new")
  end
end
