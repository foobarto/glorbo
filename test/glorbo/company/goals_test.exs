defmodule Glorbo.Company.GoalsTest do
  use ExUnit.Case, async: true

  alias Glorbo.Company.Goals

  setup do
    # `dir` is the company directory; goals land under `dir/goals/`.
    dir = System.tmp_dir!() |> Path.join("glorbo-goals-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp goal_path(dir, id), do: Path.join([dir, "goals", "#{id}.md"])

  describe "add_goal/3 (GEP-63 — writes goals/<id>.md)" do
    test "writes a canonical goal/v1 file", %{dir: dir} do
      assert :ok = Goals.add_goal(dir, %{id: "q4-launch", name: "Launch v2"})

      content = File.read!(goal_path(dir, "q4-launch"))
      assert content =~ "kind: goal/v1"
      assert content =~ "id: q4-launch"
      assert content =~ "name: Launch v2"
      assert content =~ "status: active"
      # Canonical order: kind, id, name, [description], status.
      assert content =~ ~r/kind: goal\/v1\nid: q4-launch\nname: Launch v2\nstatus: active/
    end

    test "creates the goals/ dir when absent", %{dir: dir} do
      refute File.dir?(Path.join(dir, "goals"))
      assert :ok = Goals.add_goal(dir, %{id: "first", name: "First"})
      assert File.dir?(Path.join(dir, "goals"))
      assert File.exists?(goal_path(dir, "first"))
    end

    test "stores optional description", %{dir: dir} do
      assert :ok =
               Goals.add_goal(dir, %{id: "a", name: "A", description: "why we care"})

      # The Formatter canonicalises the frontmatter — plain scalars
      # (even with spaces) are emitted bare.
      assert File.read!(goal_path(dir, "a")) =~ "description: why we care"
    end

    test "omits description when blank", %{dir: dir} do
      assert :ok = Goals.add_goal(dir, %{id: "b", name: "B", description: ""})
      refute File.read!(goal_path(dir, "b")) =~ "description:"
    end

    test "rejects empty id", %{dir: dir} do
      assert {:error, :id_required} = Goals.add_goal(dir, %{id: "", name: "A"})
    end

    test "rejects invalid id", %{dir: dir} do
      assert {:error, :invalid_id} = Goals.add_goal(dir, %{id: "Foo Bar", name: "A"})
      assert {:error, :invalid_id} = Goals.add_goal(dir, %{id: "9lead", name: "A"})
    end

    test "rejects empty name", %{dir: dir} do
      assert {:error, :name_required} = Goals.add_goal(dir, %{id: "valid", name: ""})
    end

    test "rejects a duplicate id (File.exists? uniqueness)", %{dir: dir} do
      assert :ok = Goals.add_goal(dir, %{id: "dup", name: "First"})
      assert {:error, :id_taken} = Goals.add_goal(dir, %{id: "dup", name: "Second"})
      # The original file is untouched.
      assert File.read!(goal_path(dir, "dup")) =~ "name: First"
    end

    test "the written file is read back by list/1", %{dir: dir} do
      assert :ok = Goals.add_goal(dir, %{id: "round-trip", name: "Round Trip"})

      assert [%{id: "round-trip", title: "Round Trip", status: "active"}] =
               Goals.list(dir)
    end
  end

  describe "list/1 (GEP-63 — shared hardened loader)" do
    defp write_goal(dir, filename, body) do
      File.mkdir_p!(Path.join(dir, "goals"))
      File.write!(Path.join([dir, "goals", filename]), body)
    end

    test "returns [] when goals/ is absent", %{dir: dir} do
      assert Goals.list(dir) == []
    end

    test "normalises a goal file to the UI map", %{dir: dir} do
      write_goal(dir, "g1.md", """
      ---
      kind: goal/v1
      id: g1
      name: Goal One
      description: the first goal
      status: paused
      progress: 40
      ---
      """)

      assert [goal] = Goals.list(dir)

      assert goal == %{
               id: "g1",
               title: "Goal One",
               description: "the first goal",
               status: "paused",
               progress: 40
             }
    end

    test "title falls back to id when name is absent", %{dir: dir} do
      write_goal(dir, "no-name.md", "---\nkind: goal/v1\nid: no-name\n---\n")
      assert [%{id: "no-name", title: "no-name"}] = Goals.list(dir)
    end

    test "id always comes from the filename, never the id: field", %{dir: dir} do
      # A mismatched `id:` field is normalised away — filename wins, to
      # preserve the task-link invariant.
      write_goal(dir, "real-id.md", "---\nkind: goal/v1\nid: lying-id\nname: X\n---\n")
      assert [%{id: "real-id"}] = Goals.list(dir)
    end

    test "explicit in-range progress wins; out-of-range / non-integer → nil", %{dir: dir} do
      write_goal(dir, "ok.md", "---\nkind: goal/v1\nid: ok\nprogress: 75\n---\n")
      write_goal(dir, "over.md", "---\nkind: goal/v1\nid: over\nprogress: 150\n---\n")
      write_goal(dir, "str.md", ~s(---\nkind: goal/v1\nid: str\nprogress: "60"\n---\n))

      by_id = Map.new(Goals.list(dir), &{&1.id, &1.progress})
      assert by_id["ok"] == 75
      assert by_id["over"] == nil
      assert by_id["str"] == nil
    end

    test "is sorted by id", %{dir: dir} do
      write_goal(dir, "zeta.md", "---\nkind: goal/v1\nid: zeta\n---\n")
      write_goal(dir, "alpha.md", "---\nkind: goal/v1\nid: alpha\n---\n")
      assert ["alpha", "zeta"] = Goals.list(dir) |> Enum.map(& &1.id)
    end

    test "skips a malformed file silently (T9 no-crash)", %{dir: dir} do
      write_goal(dir, "good.md", "---\nkind: goal/v1\nid: good\nname: Good\n---\n")
      # Frontmatter that fails to parse (unclosed flow sequence).
      write_goal(dir, "bad.md", "---\nkind: goal/v1\nid: bad\ntags: [a, b\n---\n")

      assert [%{id: "good"}] = Goals.list(dir)
    end

    test "skips a malformed scalar (map status) without crashing", %{dir: dir} do
      write_goal(dir, "weird.md", """
      ---
      kind: goal/v1
      id: weird
      status:
        nested: map
      ---
      """)

      # status coerces to the default rather than crashing to_string/1.
      assert [%{id: "weird", status: "active"}] = Goals.list(dir)
    end

    test "skips files whose basename is not a strict slug", %{dir: dir} do
      # Uppercase, leading digit, and leading hyphen all fail the strict
      # `@id_regex` the writer enforces — even though the looser
      # `Slug.valid?` would accept the digit/hyphen ones. No phantom card
      # for a name the add-goal form could never create.
      write_goal(dir, "BadCaps.md", "---\nkind: goal/v1\nid: x\n---\n")
      write_goal(dir, "123.md", "---\nkind: goal/v1\nid: x\n---\n")
      write_goal(dir, "-evil.md", "---\nkind: goal/v1\nid: x\n---\n")
      assert Goals.list(dir) == []
    end

    test "skips a file without `kind: goal/v1` (no phantom cards)", %{dir: dir} do
      # The dir is agent-writable: a scratch note (no frontmatter fence)
      # and a misfiled task/v1 must NOT render as goals.
      write_goal(dir, "notes.md", "just some plain text, no frontmatter\n")
      write_goal(dir, "imposter.md", "---\nkind: task/v1\nid: imposter\nname: Not A Goal\n---\n")
      write_goal(dir, "real.md", "---\nkind: goal/v1\nid: real\nname: Real\n---\n")

      assert [%{id: "real"}] = Goals.list(dir)
    end

    test "skips an oversized file (>1 MiB read cap)", %{dir: dir} do
      # A planted file past the 1 MiB cap is refused by read_bounded
      # before it can be slurped into the dashboard heap.
      huge =
        "---\nkind: goal/v1\nid: huge\nname: " <> String.duplicate("x", 1_100_000) <> "\n---\n"

      write_goal(dir, "huge.md", huge)
      write_goal(dir, "small.md", "---\nkind: goal/v1\nid: small\nname: Small\n---\n")

      assert [%{id: "small"}] = Goals.list(dir)
    end

    test "refuses a symlinked goals/ dir", %{dir: dir} do
      real = Path.join(dir, "real-goals")
      File.mkdir_p!(real)
      File.write!(Path.join(real, "g.md"), "---\nkind: goal/v1\nid: g\n---\n")

      case File.ln_s(real, Path.join(dir, "goals")) do
        :ok -> assert Goals.list(dir) == []
        {:error, _} -> :ok
      end
    end
  end
end
