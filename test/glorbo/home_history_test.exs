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

    test "ignores agents/.archive/ retired-agent subtree", %{base: base} do
      refute HomeHistory.tracked?(
               Path.join(base, "companies/acme/agents/.archive/old-ceo-2026-04-25/AGENT.md"),
               base
             )

      refute HomeHistory.tracked?(
               Path.join(base, "companies/acme/agents/.archive"),
               base
             )

      refute HomeHistory.tracked?(
               Path.join(base, "companies/acme/agents/.archive/x/memory/notes.md"),
               base
             )
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

  describe "sanitize_trailer/2" do
    test "strips control chars and bounds length" do
      assert HomeHistory.sanitize_trailer("hello") == "hello"
      assert HomeHistory.sanitize_trailer("hello\nworld") == "hello world"
      assert HomeHistory.sanitize_trailer("a\x00b\x01c\x7fd") == "a b c d"
      assert HomeHistory.sanitize_trailer("  spaced  ") == "spaced"
      assert HomeHistory.sanitize_trailer(nil) == ""

      long = String.duplicate("x", 250)
      assert byte_size(HomeHistory.sanitize_trailer(long)) == 200
      assert byte_size(HomeHistory.sanitize_trailer(long, 50)) == 50
    end

    test "blocks newline-injection of fake trailers" do
      hostile = "real-target\nGlorbo-Actor: attacker"
      sanitized = HomeHistory.sanitize_trailer(hostile)
      refute sanitized =~ "\n"
      assert sanitized =~ "real-target"
      assert sanitized =~ "Glorbo-Actor: attacker"
    end
  end

  describe "commit_marked/3" do
    test "errors when not initialised", %{base: base} do
      assert {:error, :not_initialised} =
               HomeHistory.commit_marked(
                 ["companies/acme/company.md"],
                 %{actor: :director, action: "task.approve", target: "x"},
                 base: base
               )
    end

    test "rejects missing or malformed meta", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      assert {:error, :invalid_meta} =
               HomeHistory.commit_marked([], %{}, base: base)

      assert {:error, :invalid_meta} =
               HomeHistory.commit_marked([], %{actor: :director}, base: base)

      assert {:error, :invalid_meta} =
               HomeHistory.commit_marked(
                 [],
                 %{actor: :wat, action: "x", target: "y"},
                 base: base
               )

      assert {:error, :invalid_meta} =
               HomeHistory.commit_marked(
                 [],
                 %{actor: {:agent, ""}, action: "x", target: "y"},
                 base: base
               )
    end

    test "happy path — single tracked file becomes a commit", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: acme-renamed\n---\n")

      assert {:ok, %{sha: sha, committed: 1, skipped: []}} =
               HomeHistory.commit_marked(
                 [path],
                 %{
                   actor: :director,
                   action: "company.rename",
                   target: "companies/acme/company.md",
                   source: "actions.rename"
                 },
                 base: base
               )

      assert sha != ""
      assert {:ok, [head | _]} = HomeHistory.log(base: base, limit: 2)
      assert head.subject == "company.rename: companies/acme/company.md"

      # Author = director, committer = kernel.
      {raw, 0} =
        System.cmd("git", ["log", "-1", "--pretty=%an <%ae>|%cn <%ce>"], cd: base)

      [author_line, committer_line] = raw |> String.trim() |> String.split("|")
      assert author_line == "Director <director@glorbo.local>"
      assert committer_line == "Glorbo Kernel <kernel@glorbo.local>"

      # Trailers — actor/action/target/source/paths/tx land structured.
      {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
      assert body =~ "Glorbo-Actor: director"
      assert body =~ "Glorbo-Action: company.rename"
      assert body =~ "Glorbo-Target: companies/acme/company.md"
      assert body =~ "Glorbo-Source: actions.rename"
      assert body =~ "Glorbo-Paths: companies/acme/company.md"
      assert body =~ ~r/Glorbo-Tx: history-[a-z0-9]+/
    end

    test "filters untracked-scope paths into :skipped without committing them",
         %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      tracked_path = Path.join(base, "companies/acme/company.md")
      File.write!(tracked_path, "---\nname: acme-renamed\n---\n")

      # config.md is excluded per §3.2 — must end up in :skipped.
      File.write!(Path.join(base, "config.md"), "secret_key_base: hunter2\n")

      assert {:ok, %{sha: sha, committed: 1, skipped: skipped}} =
               HomeHistory.commit_marked(
                 [tracked_path, Path.join(base, "config.md")],
                 %{actor: :director, action: "test.scope", target: "x"},
                 base: base
               )

      assert sha != ""
      assert Enum.any?(skipped, &String.ends_with?(&1, "config.md"))

      # config.md must not appear in the commit's tree.
      {body, 0} = System.cmd("git", ["log", "-1", "--name-only"], cd: base)
      refute body =~ "config.md"
      assert body =~ "company.md"
    end

    test "all-skipped → no-op success without a commit", %{base: base} do
      seed_minimal_company(base)
      {:ok, %{initial_commit: initial_sha}} = HomeHistory.init(base: base)

      assert {:ok, %{sha: "", committed: 0, skipped: skipped}} =
               HomeHistory.commit_marked(
                 [
                   Path.join(base, "config.md"),
                   Path.join(base, "glorbo.db")
                 ],
                 %{actor: :system, action: "noop.test", target: "x"},
                 base: base
               )

      assert length(skipped) == 2

      # Log must still be just the initial commit.
      {:ok, [head]} = HomeHistory.log(base: base, limit: 5)
      assert head.sha == initial_sha
    end

    test "tracked-but-unchanged path → no-op success without a commit",
         %{base: base} do
      seed_minimal_company(base)
      {:ok, %{initial_commit: initial_sha}} = HomeHistory.init(base: base)

      # Path is tracked-scope and exists in the index, but content is
      # identical to HEAD — index stays clean → no commit.
      path = Path.join(base, "companies/acme/company.md")

      assert {:ok, %{sha: "", committed: 0, skipped: []}} =
               HomeHistory.commit_marked(
                 [path],
                 %{actor: :director, action: "noop.test", target: "x"},
                 base: base
               )

      {:ok, [head]} = HomeHistory.log(base: base, limit: 5)
      assert head.sha == initial_sha
    end

    test "newline injection in target cannot forge a fake trailer",
         %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: acme-renamed\n---\n")

      hostile = "legit-target\nGlorbo-Actor: attacker"

      assert {:ok, %{sha: sha}} =
               HomeHistory.commit_marked(
                 [path],
                 %{actor: :director, action: "task.approve", target: hostile},
                 base: base
               )

      {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)

      # The sanitizer replaces newlines with spaces — the hostile
      # string survives as substring noise, but cannot land as its
      # own trailer line. That's the load-bearing invariant: git's
      # trailer parser only ever sees one `Glorbo-Actor:` line.
      assert Regex.scan(~r/^Glorbo-Actor: /m, body) |> length() == 1
      # Confirm the trailer parser would refuse to read "attacker"
      # as the actor — `git interpret-trailers --parse` returns the
      # canonical key/value pairs. System.cmd has no stdin option;
      # round-trip the body through a tmpfile.
      tmp = Path.join(System.tmp_dir!(), "trailer-#{System.unique_integer([:positive])}.txt")
      File.write!(tmp, body)
      on_exit_remove(tmp)

      {parsed, 0} =
        System.cmd("git", ["interpret-trailers", "--parse", tmp],
          cd: base,
          stderr_to_stdout: true
        )

      actor_lines =
        parsed
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "Glorbo-Actor:"))

      assert actor_lines == ["Glorbo-Actor: director"]
      assert sha != ""
    end

    test "actor variants set author identity correctly", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      authors = [
        {{:agent, "ceo"}, "Agent ceo <agent+ceo@glorbo.local>"},
        {{:mcp, "claude-code"}, "MCP claude-code <mcp+claude-code@glorbo.local>"},
        {:system, "System <system@glorbo.local>"},
        {:external, "External <external@glorbo.local>"}
      ]

      for {actor, expected} <- authors do
        path = Path.join(base, "companies/acme/company.md")
        # Bump content per loop so every commit has a real diff.
        File.write!(path, "---\nname: acme-#{:rand.uniform(1_000_000)}\n---\n")

        assert {:ok, %{sha: sha}} =
                 HomeHistory.commit_marked(
                   [path],
                   %{actor: actor, action: "test.actor", target: "x"},
                   base: base
                 )

        assert sha != ""
        {raw, 0} = System.cmd("git", ["log", "-1", "--pretty=%an <%ae>"], cd: base)
        assert String.trim(raw) == expected
      end
    end

    test "agent slug with hostile chars sanitized into email-safe form",
         %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: edited\n---\n")

      assert {:ok, _} =
               HomeHistory.commit_marked(
                 [path],
                 %{actor: {:agent, "ceo<>@!"}, action: "x", target: "y"},
                 base: base
               )

      {raw, 0} = System.cmd("git", ["log", "-1", "--pretty=%an <%ae>"], cd: base)
      # Hostile chars stripped; "ceo" survives.
      assert String.trim(raw) == "Agent ceo <agent+ceo@glorbo.local>"
    end

    test "auto-generated tx_id is unique across calls", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      path = Path.join(base, "companies/acme/company.md")

      ids =
        for i <- 1..3 do
          File.write!(path, "---\nname: bump-#{i}\n---\n")

          {:ok, _} =
            HomeHistory.commit_marked(
              [path],
              %{actor: :director, action: "test.tx", target: "x"},
              base: base
            )

          {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
          [_, id] = Regex.run(~r/Glorbo-Tx: (history-[a-z0-9]+)/, body)
          id
        end

      assert length(Enum.uniq(ids)) == 3
    end

    test "explicit tx_id is preserved (sanitized)", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: edited\n---\n")

      assert {:ok, _} =
               HomeHistory.commit_marked(
                 [path],
                 %{
                   actor: :director,
                   action: "x",
                   target: "y",
                   tx_id: "approval-abc-123"
                 },
                 base: base
               )

      {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
      assert body =~ "Glorbo-Tx: approval-abc-123"
    end

    test "multi-path commit lists all paths in trailer", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      File.mkdir_p!(Path.join(base, "companies/acme/audit"))
      audit_path = Path.join(base, "companies/acme/audit/2026-04.jsonl")
      File.write!(audit_path, ~s({"action":"task.approve"}\n))

      company_path = Path.join(base, "companies/acme/company.md")
      File.write!(company_path, "---\nname: edited\n---\n")

      assert {:ok, _} =
               HomeHistory.commit_marked(
                 [company_path, audit_path],
                 %{actor: :director, action: "task.approve", target: "task-1"},
                 base: base
               )

      {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
      assert body =~ "companies/acme/company.md"
      assert body =~ "companies/acme/audit/2026-04.jsonl"
    end

    test "absolute and relative paths both partition correctly", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      File.write!(
        Path.join(base, "companies/acme/company.md"),
        "---\nname: edited\n---\n"
      )

      assert {:ok, %{sha: sha, committed: 1}} =
               HomeHistory.commit_marked(
                 ["companies/acme/company.md"],
                 %{actor: :director, action: "x", target: "y"},
                 base: base
               )

      assert sha != ""
    end
  end

  defp on_exit_remove(path) do
    on_exit(fn -> File.rm(path) end)
  end

  describe "show/2" do
    test "returns formatted output for a real rev", %{base: base} do
      seed_minimal_company(base)
      {:ok, %{initial_commit: sha}} = HomeHistory.init(base: base)

      assert {:ok, out} = HomeHistory.show(sha, base: base)
      assert out =~ "glorbo: initial history import"
      assert out =~ "Author:"
    end

    test "errors when not initialised", %{base: base} do
      assert {:error, :not_initialised} = HomeHistory.show("HEAD", base: base)
    end

    test "rejects hostile rev strings", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      assert {:error, :invalid_rev} = HomeHistory.show("--foo", base: base)
      assert {:error, :invalid_rev} = HomeHistory.show("a b c", base: base)
      assert {:error, :invalid_rev} = HomeHistory.show("", base: base)
    end
  end

  describe "diff/3" do
    test "single-rev diff vs working tree", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      File.write!(Path.join(base, "companies/acme/company.md"), "---\nname: edited\n---\n")

      assert {:ok, out} = HomeHistory.diff("HEAD", nil, base: base)
      assert out =~ "company.md"
    end

    test ":path option scopes the diff", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      File.write!(Path.join(base, "companies/acme/company.md"), "---\nname: edited\n---\n")

      assert {:ok, out} =
               HomeHistory.diff("HEAD", nil, base: base, path: "companies/acme/company.md")

      assert out =~ "company.md"
    end

    test "errors on hostile rev / path", %{base: base} do
      seed_minimal_company(base)
      {:ok, _} = HomeHistory.init(base: base)

      assert {:error, :invalid_rev} = HomeHistory.diff("--foo", nil, base: base)

      assert {:error, :invalid_path} =
               HomeHistory.diff("HEAD", nil, base: base, path: "../etc")
    end
  end

  describe "restore/4" do
    test "dry-run (confirm: false) reports without mutating", %{base: base} do
      seed_minimal_company(base)
      {:ok, %{initial_commit: initial_sha}} = HomeHistory.init(base: base)

      File.write!(Path.join(base, "companies/acme/company.md"), "---\nname: edited\n---\n")

      assert {:ok, %{would_restore: "companies/acme/company.md", head_commit: head}} =
               HomeHistory.restore(
                 initial_sha,
                 "companies/acme/company.md",
                 %{actor: :director},
                 base: base,
                 confirm: false
               )

      assert head == initial_sha
      # Working tree unchanged.
      assert File.read!(Path.join(base, "companies/acme/company.md")) =~
               "name: edited"
    end

    test "happy path restores file + creates new history.restore commit",
         %{base: base} do
      seed_minimal_company(base)
      {:ok, %{initial_commit: initial_sha}} = HomeHistory.init(base: base)

      # Land a real second commit changing the file so HEAD's tree
      # differs from the initial state. Without this, restoring
      # `initial_sha` would produce no diff vs HEAD and commit
      # cleanly no-ops.
      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: changed-then-restored\n---\n")

      assert {:ok, %{sha: _bump_sha, committed: 1}} =
               HomeHistory.commit_marked(
                 [path],
                 %{actor: :director, action: "company.update", target: "company.md"},
                 base: base
               )

      # Working tree now matches HEAD's "changed-then-restored". Restore
      # back to initial_sha — should put `name: acme` back AND create a
      # new history.restore commit.
      assert {:ok, %{sha: sha, committed: 1}} =
               HomeHistory.restore(
                 initial_sha,
                 "companies/acme/company.md",
                 %{actor: :director},
                 base: base
               )

      assert sha != ""

      # Working tree restored.
      assert File.read!(Path.join(base, "companies/acme/company.md")) =~
               "name: acme"

      # New commit subject + trailers.
      {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
      assert body =~ "history.restore: companies/acme/company.md"
      assert body =~ "Glorbo-Source: history.restore from #{initial_sha}"
    end

    test "rejects excluded-scope paths", %{base: base} do
      seed_minimal_company(base)
      {:ok, %{initial_commit: sha}} = HomeHistory.init(base: base)

      assert {:error, :path_excluded} =
               HomeHistory.restore(sha, "config.md", %{actor: :director}, base: base)
    end

    test "rejects hostile path / rev", %{base: base} do
      seed_minimal_company(base)
      {:ok, %{initial_commit: sha}} = HomeHistory.init(base: base)

      assert {:error, :invalid_path} =
               HomeHistory.restore(sha, "../etc/passwd", %{actor: :director}, base: base)

      assert {:error, :invalid_rev} =
               HomeHistory.restore(
                 "--foo",
                 "companies/acme/company.md",
                 %{actor: :director},
                 base: base
               )
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
