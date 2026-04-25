defmodule Glorbo.HomeHistoryTest do
  @moduledoc """
  GEP-33 Phase 1 — `Glorbo.HomeHistory` covers the bootstrap +
  read-only commands (`init`, `status`, `log`) plus the
  tracked-path matcher.

  These tests don't touch `~/.glorbo/`. Each spins up a tmp dir
  shaped like a home root, runs the operation, then cleans up.
  """
  use ExUnit.Case, async: true

  alias Glorbo.HomeHistory

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-history-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  describe "tracked?/2" do
    test "tracks the canonical durable subset", %{base: base} do
      assert HomeHistory.tracked?(Path.join(base, "companies/acme/company.md"), base)

      assert HomeHistory.tracked?(
               Path.join(base, "companies/acme/projects/foo/tasks/foo-1.md"),
               base
             )

      assert HomeHistory.tracked?(
               Path.join(base, "companies/acme/agents/ceo/AGENT.md"),
               base
             )

      assert HomeHistory.tracked?(
               Path.join(base, "companies/acme/audit/2026-04.jsonl"),
               base
             )

      assert HomeHistory.tracked?(
               Path.join(base, "companies/acme/agents/ceo/memory/notes.md"),
               base
             )
    end

    test "ignores secrets, derived state, logs, runtime, cache", %{base: base} do
      refute HomeHistory.tracked?(Path.join(base, "config.md"), base)
      refute HomeHistory.tracked?(Path.join(base, "glorbo.db"), base)
      refute HomeHistory.tracked?(Path.join(base, "glorbo.db-shm"), base)
      refute HomeHistory.tracked?(Path.join(base, "glorbo.db-wal"), base)
      refute HomeHistory.tracked?(Path.join(base, "logs/app.log"), base)
      refute HomeHistory.tracked?(Path.join(base, "runtime/socket"), base)
      refute HomeHistory.tracked?(Path.join(base, "run/glorbo.pid"), base)
      refute HomeHistory.tracked?(Path.join(base, "cache/providers/openai.json"), base)
    end

    test "ignores per-agent transport / state / scratch dirs", %{base: base} do
      refute HomeHistory.tracked?(
               Path.join(base, "companies/acme/agents/ceo/inbox/wake-1.md"),
               base
             )

      refute HomeHistory.tracked?(
               Path.join(base, "companies/acme/agents/ceo/outbox/2026-04.md"),
               base
             )

      refute HomeHistory.tracked?(
               Path.join(base, "companies/acme/agents/ceo/state/awaiting-approval-x.md"),
               base
             )

      refute HomeHistory.tracked?(
               Path.join(base, "companies/acme/agents/ceo/workspace/scratch.txt"),
               base
             )

      refute HomeHistory.tracked?(
               Path.join(base, "companies/acme/agents/ceo/stdout.log"),
               base
             )
    end

    test "ignores .git/ itself", %{base: base} do
      refute HomeHistory.tracked?(Path.join(base, ".git/HEAD"), base)
      refute HomeHistory.tracked?(Path.join(base, ".git"), base)
    end

    test "rejects paths outside the base", %{base: base} do
      refute HomeHistory.tracked?("/tmp/somewhere-else/file.md", base)
    end
  end

  describe "gitignore_content/0" do
    test "encodes the GEP-33 §3.2 exclusion list" do
      content = HomeHistory.gitignore_content()

      assert content =~ "/.git/"
      assert content =~ "/config.md"
      assert content =~ "/glorbo.db"
      assert content =~ "/logs/"
      assert content =~ "/cache/"
      assert content =~ "/companies/*/agents/*/inbox/"
      assert content =~ "/companies/*/agents/*/outbox/"
      assert content =~ "/companies/*/agents/*/state/"
      assert content =~ "/companies/*/agents/*/workspace/"
      assert content =~ "/companies/*/agents/*/stdout.log"
    end
  end

  describe "init/1" do
    test "bootstraps a fresh repo with .gitignore + initial commit", %{base: base} do
      seed_minimal_company(base)

      assert {:ok, %{repo: repo, initial_commit: sha, tracked: count}} =
               HomeHistory.init(base: base)

      assert File.dir?(repo)
      assert repo == Path.join(base, ".git")
      assert is_binary(sha)
      # short SHA is 7+ chars
      assert String.length(sha) >= 7
      # Tracked count > 0 — at minimum .gitignore + the seeded files.
      assert count > 0

      # .gitignore made it onto disk + matches the constant.
      assert File.read!(Path.join(base, ".gitignore")) == HomeHistory.gitignore_content()
    end

    test "refuses to re-init when .git/ already exists", %{base: base} do
      seed_minimal_company(base)
      assert {:ok, _} = HomeHistory.init(base: base)
      assert {:error, :already_initialised} = HomeHistory.init(base: base)
    end

    test "fails cleanly when base does not exist" do
      ghost = Path.join(System.tmp_dir!(), "glorbo-ghost-#{System.unique_integer([:positive])}")
      assert {:error, {:base_missing, ^ghost}} = HomeHistory.init(base: ghost)
    end

    test "ignored paths do not enter the initial commit", %{base: base} do
      seed_minimal_company(base)

      # Drop a config.md (secret-bearing — must stay out) and a
      # workspace scratch file (transport — must stay out).
      File.write!(Path.join(base, "config.md"), "secret_key_base: hunter2\n")
      File.mkdir_p!(Path.join(base, "companies/acme/agents/ceo/workspace"))
      File.write!(Path.join(base, "companies/acme/agents/ceo/workspace/scratch.txt"), "x")

      assert {:ok, _} = HomeHistory.init(base: base)

      {out, 0} = System.cmd("git", ["ls-files"], cd: base)
      tracked_files = out |> String.split("\n", trim: true)

      refute "config.md" in tracked_files

      refute Enum.any?(
               tracked_files,
               &String.starts_with?(&1, "companies/acme/agents/ceo/workspace/")
             )

      assert ".gitignore" in tracked_files
    end
  end

  describe "status/1" do
    test "reports disabled when no .git/ exists", %{base: base} do
      assert {:ok, %{enabled: false, repo: nil, dirty: []}} =
               HomeHistory.status(base: base)
    end

    test "reports enabled + clean directly after init", %{base: base} do
      seed_minimal_company(base)
      assert {:ok, _} = HomeHistory.init(base: base)
      assert {:ok, %{enabled: true, dirty: []}} = HomeHistory.status(base: base)
    end

    test "reports dirty paths after a tracked-file edit", %{base: base} do
      seed_minimal_company(base)
      assert {:ok, _} = HomeHistory.init(base: base)

      File.write!(Path.join(base, "companies/acme/company.md"), "---\nname: edited\n---\n")

      {:ok, %{enabled: true, dirty: dirty}} = HomeHistory.status(base: base)
      # Status code prefix preserved — `M` (modified, not staged) +
      # leading space + path. Keeping the porcelain code makes the
      # status output parseable downstream.
      assert Enum.any?(dirty, &(&1 =~ ~r/^.M /))
      assert Enum.any?(dirty, &String.contains?(&1, "company.md"))
    end

    test "preserves porcelain status code for untracked files", %{base: base} do
      seed_minimal_company(base)
      assert {:ok, _} = HomeHistory.init(base: base)

      projects = Path.join(base, "companies/acme/projects")
      File.mkdir_p!(projects)
      File.write!(Path.join(projects, "foo.md"), "---\nname: foo\n---\n")

      {:ok, %{dirty: dirty}} = HomeHistory.status(base: base)
      # `??` = untracked file in a tracked subtree.
      assert Enum.any?(dirty, &String.starts_with?(&1, "?? "))
    end
  end

  describe "log/1" do
    test "errors when not initialised", %{base: base} do
      assert {:error, :not_initialised} = HomeHistory.log(base: base)
    end

    test "returns the initial commit row after init", %{base: base} do
      seed_minimal_company(base)
      assert {:ok, _} = HomeHistory.init(base: base)
      assert {:ok, [first | _]} = HomeHistory.log(base: base, limit: 5)

      assert is_binary(first.sha)
      assert first.subject == "glorbo: initial history import"
      assert first.author_name == "Glorbo Kernel"
      assert is_binary(first.relative_time)
    end
  end

  # Tiny seed — just enough that `git add -A` finds tracked files
  # and the initial commit isn't built solely on .gitignore.
  defp seed_minimal_company(base) do
    File.mkdir_p!(Path.join(base, "companies/acme/agents/ceo"))
    File.write!(Path.join(base, "companies/acme/company.md"), "---\nname: acme\n---\n")
    File.write!(Path.join(base, "companies/acme/agents/ceo/AGENT.md"), "---\nname: CEO\n---\n")
    :ok
  end
end
