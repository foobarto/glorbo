defmodule Glorbo.BenchmarksTest do
  use ExUnit.Case, async: true

  alias Glorbo.Benchmarks

  defp tmp_base(ctx) do
    root =
      Path.join(
        System.tmp_dir!(),
        "glorbo-bench-#{ctx.test |> inspect() |> String.replace(~r/\W/, "")}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join([root, "benchmarks", "runs"]))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp seed_run!(base, run_id, providers) do
    dir = Path.join([base, "benchmarks", "runs", run_id])
    File.mkdir_p!(dir)

    providers_line = Enum.map_join(providers, ", ", &"\"#{&1}\"")

    File.write!(Path.join(dir, "manifest.md"), """
    ---
    kind: benchmark-run/v1
    run_id: #{run_id}
    template: bench-softdev
    task: bug-1
    providers: [#{providers_line}]
    started_at: "2026-04-23T18:00:00Z"
    status: completed
    ---
    """)

    File.write!(Path.join(dir, "task.md"), """
    ---
    kind: task/v1
    id: bug-1
    title: Fix login timeout
    status: todo
    ---
    Users are getting logged out after 30 seconds.
    """)

    Enum.each(providers, fn provider ->
      provider_dir = Path.join([dir, "providers", provider])
      File.mkdir_p!(provider_dir)
      File.write!(Path.join(provider_dir, "output.md"), "Output from #{provider}.\n")
    end)

    dir
  end

  describe "list/1" do
    test "enumerates runs with parseable manifest.md, newest first", ctx do
      base = tmp_base(ctx)

      seed_run!(base, "2026-04-21T1200Z-bench-a", ["claude-code", "codex"])
      |> File.touch()

      seed_run!(base, "2026-04-23T1800Z-bench-b", ["codex", "gemini-cli"])

      # Overwrite started_at on the 2nd so sort-by-desc wins predictably.
      File.write!(
        Path.join([base, "benchmarks", "runs", "2026-04-23T1800Z-bench-b", "manifest.md"]),
        """
        ---
        kind: benchmark-run/v1
        run_id: 2026-04-23T1800Z-bench-b
        template: bench-softdev
        task: bug-1
        providers: ["codex", "gemini-cli"]
        started_at: "2026-04-23T18:00:00Z"
        status: scored
        ---
        """
      )

      File.write!(
        Path.join([base, "benchmarks", "runs", "2026-04-21T1200Z-bench-a", "manifest.md"]),
        """
        ---
        kind: benchmark-run/v1
        run_id: 2026-04-21T1200Z-bench-a
        template: bench-softdev
        task: bug-1
        providers: ["claude-code", "codex"]
        started_at: "2026-04-21T12:00:00Z"
        status: completed
        ---
        """
      )

      [newest, oldest] = Benchmarks.list(base: base)
      assert newest.run_id == "2026-04-23T1800Z-bench-b"
      assert oldest.run_id == "2026-04-21T1200Z-bench-a"
      assert newest.providers == ["codex", "gemini-cli"]
    end

    test "returns empty list on missing runs dir", ctx do
      base = tmp_base(ctx)
      File.rm_rf!(Path.join([base, "benchmarks", "runs"]))
      assert [] = Benchmarks.list(base: base)
    end
  end

  describe "fetch/2" do
    test "returns task body, per-provider outputs, and a stable blind order", ctx do
      base = tmp_base(ctx)
      seed_run!(base, "run-1", ["claude-code", "codex", "gemini-cli"])

      {:ok, run} = Benchmarks.fetch("run-1", base: base)

      assert run.summary.run_id == "run-1"
      assert run.summary.providers == ["claude-code", "codex", "gemini-cli"]
      assert String.contains?(run.task_body, "logged out after 30 seconds")
      assert length(run.outputs) == 3
      assert Enum.find(run.outputs, &(&1.provider == "codex")).body =~ "Output from codex"

      # blind_order is a stable shuffle over the same providers.
      assert Enum.sort(run.blind_order) == Enum.sort(run.summary.providers)

      # Same run_id always returns the same order.
      {:ok, run_again} = Benchmarks.fetch("run-1", base: base)
      assert run_again.blind_order == run.blind_order
    end

    test "returns :not_found when the run dir is missing", ctx do
      base = tmp_base(ctx)
      assert {:error, :not_found} = Benchmarks.fetch("ghost", base: base)
    end

    # B-010 / C-037: run_id is a URL param joined into a path.
    test "rejects traversal run_ids", ctx do
      base = tmp_base(ctx)
      assert {:error, :invalid_run_id} = Benchmarks.fetch("../../../etc", base: base)
      assert {:error, :invalid_run_id} = Benchmarks.fetch("..", base: base)
      assert {:error, :invalid_run_id} = Benchmarks.fetch("a/b", base: base)
      assert {:error, :invalid_run_id} = Benchmarks.fetch(".hidden", base: base)
    end

    test "accepts the real %Y-%m-%dTHMZ-bench-<hex> run_id shape", ctx do
      base = tmp_base(ctx)
      run_id = "2026-04-23T1800Z-bench-ab12cd"
      seed_run!(base, run_id, ["codex"])
      assert {:ok, run} = Benchmarks.fetch(run_id, base: base)
      assert run.summary.run_id == run_id
    end

    # B-010 / C-037: a hand-assembled / external run dir is untrusted;
    # a symlinked artifact must NOT be followed and rendered.
    test "does not follow a symlinked task.md into a host file", ctx do
      base = tmp_base(ctx)
      seed_run!(base, "run-sym", ["codex"])

      # Plant a host "secret" and redirect task.md at it.
      secret = Path.join(base, "host-secret.txt")
      File.write!(secret, "TOP SECRET HOST CONTENT")

      task_md = Path.join([base, "benchmarks", "runs", "run-sym", "task.md"])
      File.rm!(task_md)
      File.ln_s!(secret, task_md)

      {:ok, run} = Benchmarks.fetch("run-sym", base: base)
      refute run.task_body =~ "TOP SECRET"
    end
  end

  describe "score/3" do
    test "appends a section to scores.md and flips manifest status to `scored`", ctx do
      base = tmp_base(ctx)
      seed_run!(base, "run-2", ["claude-code", "codex"])

      assert :ok =
               Benchmarks.score("run-2", ["codex", "claude-code"],
                 base: base,
                 rationale: "Codex's patch was cleaner."
               )

      scores_path = Path.join([base, "benchmarks", "runs", "run-2", "scores.md"])
      scores = File.read!(scores_path)
      assert scores =~ "kind: benchmark-scores/v1"
      assert scores =~ "## 2026-"
      assert scores =~ "| director"
      assert scores =~ "**Ranking:** 1. codex · 2. claude-code"
      assert scores =~ "Codex's patch was cleaner."

      manifest =
        File.read!(Path.join([base, "benchmarks", "runs", "run-2", "manifest.md"]))

      assert manifest =~ "status: scored"
    end

    test "rejects rankings that don't cover every provider", ctx do
      base = tmp_base(ctx)
      seed_run!(base, "run-3", ["claude-code", "codex", "gemini-cli"])

      assert {:error, {:ranking_mismatch, _, _}} =
               Benchmarks.score("run-3", ["codex", "claude-code"], base: base)
    end

    test "rejects traversal run_ids before any path join", ctx do
      base = tmp_base(ctx)
      assert {:error, :invalid_run_id} =
               Benchmarks.score("../../evil", ["codex"], base: base)
    end

    test "second scoring append preserves prior sections", ctx do
      base = tmp_base(ctx)
      seed_run!(base, "run-4", ["claude-code", "codex"])

      :ok = Benchmarks.score("run-4", ["claude-code", "codex"], base: base, rationale: "first")
      :ok = Benchmarks.score("run-4", ["codex", "claude-code"], base: base, rationale: "second")

      scores = File.read!(Path.join([base, "benchmarks", "runs", "run-4", "scores.md"]))

      assert scores =~ "first"
      assert scores =~ "second"
    end
  end
end
