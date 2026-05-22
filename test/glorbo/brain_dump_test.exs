defmodule Glorbo.BrainDumpTest do
  use ExUnit.Case, async: true

  alias Glorbo.BrainDump

  setup do
    base = Path.join(System.tmp_dir!(), "glorbo-bd-#{System.unique_integer([:positive])}")
    company = "acme"
    File.mkdir_p!(Path.join([base, "companies", company]))
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, company: company}
  end

  describe "capture/3" do
    test "appends a section to today's file and returns the entry", %{base: base, company: co} do
      now = ~U[2026-04-21 10:15:30Z]
      {:ok, entry} = BrainDump.capture(base, co, "buy oat milk", now: now)

      assert entry.title == "buy oat milk"
      assert entry.body == "buy oat milk"
      assert entry.day == "2026-04-21"
      assert entry.ts == "2026-04-21T10:15:30Z"

      path = Path.join([base, "companies", co, "braindump", "2026-04-21.md"])
      content = File.read!(path)
      assert content =~ "# Brain dump · 2026-04-21"
      assert content =~ "## 10:15:30 — buy oat milk"
      assert content =~ "buy oat milk"
    end

    test "appends successive captures as separate sections", %{base: base, company: co} do
      {:ok, _} = BrainDump.capture(base, co, "first", now: ~U[2026-04-21 10:00:00Z])
      {:ok, _} = BrainDump.capture(base, co, "second", now: ~U[2026-04-21 10:01:00Z])

      content = File.read!(Path.join([base, "companies", co, "braindump", "2026-04-21.md"]))
      assert content =~ "## 10:00:00 — first"
      assert content =~ "## 10:01:00 — second"
      # File header only once.
      assert length(String.split(content, "# Brain dump")) == 2
    end

    test "derives the title from the first line, slicing at 80 chars", %{base: base, company: co} do
      long = String.duplicate("x", 200)
      {:ok, entry} = BrainDump.capture(base, co, "#{long}\nmore body here")
      assert String.length(entry.title) == 80
      assert entry.body =~ "more body here"
    end

    test "rejects empty body", %{base: base, company: co} do
      assert {:error, :empty} = BrainDump.capture(base, co, "")
      assert {:error, :empty} = BrainDump.capture(base, co, "   \n  \t")
    end

    test "rejects body over 64KB", %{base: base, company: co} do
      huge = String.duplicate("a", 65 * 1024)
      assert {:error, :too_large} = BrainDump.capture(base, co, huge)
    end
  end

  describe "list/3" do
    test "returns entries newest first across days", %{base: base, company: co} do
      {:ok, _} = BrainDump.capture(base, co, "older", now: ~U[2026-04-20 09:00:00Z])
      {:ok, _} = BrainDump.capture(base, co, "today early", now: ~U[2026-04-21 08:00:00Z])
      {:ok, _} = BrainDump.capture(base, co, "today late", now: ~U[2026-04-21 14:00:00Z])

      entries = BrainDump.list(base, co)
      titles = Enum.map(entries, & &1.title)
      # Day ordering: 2026-04-21 files come first. Within a file,
      # newest appended is last, so reversed list puts it first.
      assert titles == ["today late", "today early", "older"]
    end

    test "respects limit_days", %{base: base, company: co} do
      {:ok, _} = BrainDump.capture(base, co, "old", now: ~U[2026-01-01 00:00:00Z])
      {:ok, _} = BrainDump.capture(base, co, "new", now: ~U[2026-04-21 00:00:00Z])

      entries = BrainDump.list(base, co, limit_days: 1)
      assert Enum.map(entries, & &1.title) == ["new"]
    end

    test "returns [] for empty / missing directory", %{base: base, company: co} do
      assert BrainDump.list(base, co) == []
    end
  end

  describe "convert_to_task/3" do
    test "scaffolds a task file with source: braindump frontmatter",
         %{base: base, company: co} do
      {:ok, entry} =
        BrainDump.capture(base, co, "refactor dispatch", now: ~U[2026-04-21 09:00:00Z])

      {:ok, rel} = BrainDump.convert_to_task(base, co, entry)
      assert rel =~ ~r/\Aprojects\/inbox\/tasks\/inbox-\d+\.md\z/

      abs = Path.join([base, "companies", co, rel])
      content = File.read!(abs)
      assert content =~ "title: refactor dispatch"
      assert content =~ "status: todo"
      assert content =~ "source: braindump"
      assert content =~ "braindump_ts: 2026-04-21T09:00:00Z"
      assert content =~ "refactor dispatch"
    end

    test "de-duplicates filenames when converting the same title twice",
         %{base: base, company: co} do
      {:ok, e1} =
        BrainDump.capture(base, co, "same idea", now: ~U[2026-04-21 09:00:00Z])

      {:ok, e2} =
        BrainDump.capture(base, co, "same idea", now: ~U[2026-04-21 09:01:00Z])

      {:ok, rel1} = BrainDump.convert_to_task(base, co, e1)
      {:ok, rel2} = BrainDump.convert_to_task(base, co, e2)
      refute rel1 == rel2
    end

    test "removes the source brain-dump section after a successful convert",
         %{base: base, company: co} do
      {:ok, keep} =
        BrainDump.capture(base, co, "keep me", now: ~U[2026-04-21 09:00:00Z])

      {:ok, drop} =
        BrainDump.capture(base, co, "drop me", now: ~U[2026-04-21 09:05:00Z])

      {:ok, _rel} = BrainDump.convert_to_task(base, co, drop)

      day_path = Path.join([base, "companies", co, "braindump", "2026-04-21.md"])
      content = File.read!(day_path)
      assert content =~ "keep me"
      refute content =~ "drop me"
      assert List.first(BrainDump.list(base, co)).title == keep.title
    end

    test "leaves no visible entries after converting the only one",
         %{base: base, company: co} do
      {:ok, only} =
        BrainDump.capture(base, co, "only one", now: ~U[2026-04-21 09:00:00Z])

      {:ok, _rel} = BrainDump.convert_to_task(base, co, only)

      assert BrainDump.list(base, co) == []
    end

    # B-016: a projects:write:* agent can replace the `inbox` project
    # *parent* with a symlink (`projects/inbox -> ../../<other>/evil`).
    # The leaf-only lstat followed it; the full ancestor-chain guard
    # must refuse it before mkdir_p / write.
    test "refuses when projects/inbox is a symlinked parent",
         %{base: base, company: co} do
      {:ok, entry} =
        BrainDump.capture(base, co, "escape me", now: ~U[2026-04-21 09:00:00Z])

      # Attacker-controlled target outside the inbox project.
      evil = Path.join([base, "companies", co, "projects", "evil-target"])
      File.mkdir_p!(evil)

      projects_dir = Path.join([base, "companies", co, "projects"])
      File.mkdir_p!(projects_dir)
      File.ln_s!(evil, Path.join(projects_dir, "inbox"))

      assert {:error, :symlink_in_path} = BrainDump.convert_to_task(base, co, entry)
      # Nothing was written into the symlink target.
      assert File.ls!(evil) |> Enum.reject(&String.ends_with?(&1, ".md")) == File.ls!(evil)
      refute Enum.any?(File.ls!(evil), &String.match?(&1, ~r/\.md\z/))
    end

    test "refuses when projects/inbox/tasks itself is a symlink",
         %{base: base, company: co} do
      {:ok, entry} =
        BrainDump.capture(base, co, "leaf symlink", now: ~U[2026-04-21 09:00:00Z])

      evil = Path.join([base, "companies", co, "projects", "evil-tasks"])
      File.mkdir_p!(evil)

      inbox = Path.join([base, "companies", co, "projects", "inbox"])
      File.mkdir_p!(inbox)
      File.ln_s!(evil, Path.join(inbox, "tasks"))

      assert {:error, :symlink_in_path} = BrainDump.convert_to_task(base, co, entry)
      refute Enum.any?(File.ls!(evil), &String.match?(&1, ~r/\.md\z/))
    end
  end
end
