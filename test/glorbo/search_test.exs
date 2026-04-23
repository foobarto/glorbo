defmodule Glorbo.SearchTest do
  use ExUnit.Case, async: false

  alias Glorbo.Search

  @cache_table :glorbo_search_title_cache

  setup do
    clear_cache()

    base = Path.join(System.tmp_dir!(), "glorbo-search-#{System.unique_integer([:positive])}")
    company = "acme"
    tasks_dir = Path.join([base, "companies", company, "projects", "foo", "tasks"])
    File.mkdir_p!(tasks_dir)

    on_exit(fn ->
      File.rm_rf!(base)
      clear_cache()
    end)

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

  defp clear_cache do
    case :ets.whereis(@cache_table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@cache_table)
    end
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

  describe "audit row search (#249)" do
    setup %{base: base, company: co} do
      audit_dir = Path.join([base, "companies", co, "audit"])
      File.mkdir_p!(audit_dir)

      month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
      path = Path.join(audit_dir, "#{month}.jsonl")

      lines = [
        %{
          "ts" => "2026-04-21T10:00:00Z",
          "actor" => "ceo",
          "action" => "agent.dispatch",
          "target" => "projects/foo/tasks/t-01.md"
        },
        %{
          "ts" => "2026-04-21T10:01:00Z",
          "actor" => "director",
          "action" => "approval.approved",
          "target" => "projects/foo/tasks/t-42.md"
        },
        %{
          "ts" => "2026-04-21T10:02:00Z",
          "actor" => "system",
          "action" => "channel.rotate",
          "target" => "channels/general.md"
        }
      ]

      content = Enum.map_join(lines, "\n", &Jason.encode!/1)
      File.write!(path, content <> "\n")
      :ok
    end

    test "matches on actor", %{base: base, company: co} do
      results = Search.search(base, co, "ceo")
      assert Enum.any?(results, &(&1.kind == "audit" and &1.label =~ "ceo"))
    end

    test "matches on action", %{base: base, company: co} do
      results = Search.search(base, co, "approval")
      assert Enum.any?(results, &(&1.kind == "audit" and &1.label =~ "approval.approved"))
    end

    test "matches on target", %{base: base, company: co} do
      results = Search.search(base, co, "general.md")
      assert Enum.any?(results, &(&1.kind == "audit" and &1.label =~ "channel.rotate"))
    end

    test "audit results href points to the audit page", %{base: base, company: co} do
      [hit | _] = Search.search(base, co, "rotate")
      assert hit.kind == "audit"
      assert hit.href == "/companies/acme/audit"
    end

    test "task + audit results coexist in a single search", %{base: base, company: co} do
      results = Search.search(base, co, "refactor")
      assert Enum.any?(results, &(&1.kind == "task"))
      # "refactor" won't be in audit seeds, but the search shouldn't
      # crash on the audit-scan path.
      assert is_list(results)
    end
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

  test "truncates oversized task titles before labeling and caching", %{base: base, company: co} do
    path = Path.join([base, "companies", co, "projects", "foo", "tasks", "foo-4.md"])
    long_title = String.duplicate("A", 2_000)

    File.write!(path, """
    ---
    title: #{long_title}
    status: todo
    ---
    body
    """)

    [hit] = Search.search(base, co, "aaaa")
    assert hit.label =~ "... [truncated]"
    assert byte_size(hit.label) <= 512 + byte_size("foo-4 · ")
  end

  test "title cache stops growing after the hard cap", %{base: base, company: co} do
    tasks_dir = Path.join([base, "companies", co, "projects", "foo", "tasks"])

    for idx <- 4..1_150 do
      File.write!(Path.join(tasks_dir, "foo-#{idx}.md"), """
      ---
      title: Search cache task #{idx}
      status: todo
      ---
      body
      """)
    end

    _ = Search.search(base, co, "search cache task")

    assert :ets.info(@cache_table, :size) <= 1_000
  end
end
