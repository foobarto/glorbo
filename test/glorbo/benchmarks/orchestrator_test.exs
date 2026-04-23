defmodule Glorbo.Benchmarks.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Glorbo.Benchmarks
  alias Glorbo.Benchmarks.Orchestrator

  defp tmp_base(ctx) do
    root =
      Path.join(
        System.tmp_dir!(),
        "glorbo-bench-orch-#{ctx.test |> inspect() |> String.replace(~r/\W/, "")}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join([root, "companies"]))
    File.mkdir_p!(Path.join([root, "benchmarks", "runs"]))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # Most GEP-26 templates ship with bench-softdev — pin it as the
  # canonical test fixture. If it ever gets renamed, update the
  # constant here.
  @template "bench-softdev"
  @task_id "bugs-1"

  defp stub_dispatch(marker) do
    fn _spec, task, _opts ->
      {:ok,
       %{
         reply: "stub output for #{marker} — task=#{task.task_id}",
         exit_status: 0,
         usage: %{tracked: false}
       }}
    end
  end

  defp failing_dispatch(reason) do
    fn _spec, _task, _opts -> {:error, reason} end
  end

  describe "run/4" do
    test "writes manifest, task.md, and per-provider output.md for each provider",
         ctx do
      base = tmp_base(ctx)
      providers = ["claude-code", "codex"]

      assert {:ok, result} =
               Orchestrator.run(@template, @task_id, providers,
                 base: base,
                 dispatch_fun: stub_dispatch("test-1")
               )

      run_dir = Path.join([base, "benchmarks", "runs", result.run_id])
      assert File.exists?(Path.join(run_dir, "manifest.md"))
      assert File.exists?(Path.join(run_dir, "task.md"))

      Enum.each(providers, fn p ->
        out = Path.join([run_dir, "providers", p, "output.md"])
        assert File.exists?(out), "missing output for #{p}"
        assert File.read!(out) =~ "stub output for test-1"
        assert File.read!(out) =~ "provider: #{p}"
      end)

      # Manifest lists providers + status flipped to completed.
      manifest = File.read!(Path.join(run_dir, "manifest.md"))
      assert manifest =~ "kind: benchmark-run/v1"
      assert manifest =~ "template: #{@template}"
      assert manifest =~ "task: #{@task_id}"

      for p <- providers do
        assert manifest =~ "\"#{p}\""
      end

      assert manifest =~ "status: completed"
      assert manifest =~ "completed_at:"

      # Benchmarks.fetch now picks the run up.
      {:ok, run} = Benchmarks.fetch(result.run_id, base: base)
      assert run.summary.status == "completed"
      assert length(run.outputs) == 2
    end

    test "cleans up shadow companies on success", ctx do
      base = tmp_base(ctx)

      {:ok, result} =
        Orchestrator.run(@template, @task_id, ["claude-code"],
          base: base,
          dispatch_fun: stub_dispatch("test-2")
        )

      shadow_path = Path.join([base, "companies", "_bench-#{result.run_id}-claude-code"])
      refute File.exists?(shadow_path)
    end

    test "keeps shadow companies when `keep_shadow?: true`", ctx do
      base = tmp_base(ctx)

      {:ok, result} =
        Orchestrator.run(@template, @task_id, ["codex"],
          base: base,
          dispatch_fun: stub_dispatch("test-3"),
          keep_shadow?: true
        )

      shadow_path = Path.join([base, "companies", "_bench-#{result.run_id}-codex"])
      assert File.dir?(shadow_path)
      # Agent.md got its provider pinned to codex.
      agent_md =
        Path.wildcard(Path.join([shadow_path, "agents", "*", "AGENT.md"])) |> List.first()

      assert File.read!(agent_md) =~ "provider: codex"
    end

    test "per-provider dispatch failure flips manifest to failed and records the error",
         ctx do
      base = tmp_base(ctx)

      {:ok, result} =
        Orchestrator.run(@template, @task_id, ["claude-code", "codex"],
          base: base,
          dispatch_fun: failing_dispatch(:sandbox_unreachable),
          keep_shadow?: true
        )

      # Every result is failure.
      assert Enum.all?(result.results, &(!&1.ok?))
      assert Enum.all?(result.results, &(&1.error == :sandbox_unreachable))

      run_dir = Path.join([base, "benchmarks", "runs", result.run_id])
      manifest = File.read!(Path.join(run_dir, "manifest.md"))
      assert manifest =~ "status: failed"

      # Dispatch-error file dropped per provider.
      for p <- ["claude-code", "codex"] do
        err_file = Path.join([run_dir, "providers", p, "dispatch-error.txt"])
        assert File.exists?(err_file)
        assert File.read!(err_file) =~ "sandbox_unreachable"
      end
    end

    test "rejects empty providers list" do
      assert {:error, :providers_list_empty} =
               Orchestrator.run(@template, @task_id, [])
    end

    test "rejects provider strings that break the slug contract" do
      # YAML injection shapes + path traversal + leading digit + empty
      # trimmed. Each of these would contaminate shadow-company slugs
      # or the manifest frontmatter.
      bad = [
        # leading digit (fails @provider_slug_re)
        "9codex",
        # YAML newline injection
        "foo\nrole: pwned",
        # path traversal
        "../../../etc",
        # shell metachars
        "foo;rm",
        # colon breaks YAML inline value
        "foo:bar"
      ]

      for b <- bad do
        assert {:error, {:providers_invalid_slug, [^b]}} =
                 Orchestrator.run(@template, @task_id, [b])
      end
    end

    test "rejects duplicate providers" do
      assert {:error, {:providers_duplicate, ["claude-code"]}} =
               Orchestrator.run(@template, @task_id, ["claude-code", "claude-code"])
    end

    test "rejects fan-out above the 32-provider cap" do
      # Each provider is a full shadow-company fork; a director
      # accidentally pasting a 100-item list should bounce at argv
      # parse, not fill the disk.
      many = for i <- 1..33, do: "provider-#{i}"

      assert {:error, {:providers_too_many, 33, 32}} =
               Orchestrator.run(@template, @task_id, many)
    end

    test "rejects unknown template", ctx do
      base = tmp_base(ctx)

      assert {:error, {:template_not_found, _}} =
               Orchestrator.run("definitely-not-a-template", @task_id, ["claude-code"],
                 base: base
               )
    end

    test "rejects task id that isn't in the template", ctx do
      base = tmp_base(ctx)

      assert {:error, {:task_not_in_template, "ghost-task-999"}} =
               Orchestrator.run(@template, "ghost-task-999", ["claude-code"], base: base)
    end
  end
end
