defmodule Glorbo.Task.SnapshotTest do
  use ExUnit.Case, async: true

  alias Glorbo.Task.Snapshot

  @company "acme"

  defp write_task!(base, project, id, frontmatter) do
    dir = Path.join([base, "companies", @company, "projects", project, "tasks"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{id}.md"), frontmatter)
  end

  setup do
    base = Path.join(System.tmp_dir!(), "glorbo-snap-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  test "build/2 maps task_id -> info across projects", %{base: base} do
    write_task!(base, "blog", "blog-1", """
    ---
    kind: task/v1
    title: a
    status: done
    peer_review_required: true
    peer_review_verdict: approve
    depends_on:
      - blog-0
    ---
    """)

    write_task!(base, "ops", "ops-9", """
    ---
    kind: task/v1
    title: b
    status: todo
    ---
    """)

    snap = Snapshot.build(base, @company)

    assert snap["blog-1"] == %{
             status: "done",
             peer_review_required: true,
             peer_review_verdict: "approve",
             depends_on: ["blog-0"]
           }

    assert snap["ops-9"].status == "todo"
    assert snap["ops-9"].peer_review_required == false
    assert snap["ops-9"].depends_on == []
  end

  test "build/2 returns empty map when the company has no projects", %{base: base} do
    File.mkdir_p!(Path.join([base, "companies", @company]))
    assert Snapshot.build(base, @company) == %{}
  end

  test "build/2 treats a file with no frontmatter as blank status (safe/non-terminal)", %{
    base: base
  } do
    write_task!(base, "blog", "good", "---\nkind: task/v1\ntitle: ok\nstatus: todo\n---\n")
    write_task!(base, "blog", "nofm", "not frontmatter at all")

    snap = Snapshot.build(base, @company)
    assert Map.has_key?(snap, "good")
    # No frontmatter parses as empty fm → status "". The dependency gate
    # classifies a blank status as non-terminal, so such a dep blocks
    # rather than spuriously unblocking — the conservative outcome.
    assert snap["nofm"].status == ""
  end

  describe "coerce_depends_on/1" do
    test "keeps non-empty strings, drops the rest, dedupes" do
      assert Snapshot.coerce_depends_on(["a", "a", "", 7, nil, "b"]) == ["a", "b"]
    end

    test "non-list inputs coerce to []" do
      assert Snapshot.coerce_depends_on(nil) == []
      assert Snapshot.coerce_depends_on("a") == []
    end
  end
end
