defmodule Glorbo.FileSpec.BenchmarkRunMd do
  @moduledoc """
  Spec for `benchmarks/runs/<run-id>/manifest.md` — the metadata
  header for a GEP-26 Phase B benchmark run.

  The surrounding directory (outputs per provider, scores.md) isn't
  covered by a FileSpec — those are freely-formed markdown that the
  Director scores against. Only the manifest has a canonical shape.
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r{/benchmarks/runs/[^/]+/manifest\.md\z}

  @impl true
  def kind, do: "benchmark-run/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :run_id, :template, :task, :providers, :started_at],
      optional: [:completed_at, :status],
      enums: %{
        status: ["queued", "in-progress", "completed", "scored", "failed"]
      },
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [
      :kind,
      :run_id,
      :template,
      :task,
      :providers,
      :started_at,
      :completed_at,
      :status
    ]
  end

  @impl true
  def docs do
    %{
      title: "benchmarks/runs/<id>/manifest.md — benchmark-run metadata",
      summary: """
      Header manifest for a GEP-26 Phase B benchmark run. The
      enclosing directory holds per-provider outputs (`providers/
      <provider>/output.md`) plus the Director's ranking history
      (`scores.md`). The manifest pins the template + task + the
      provider list in a stable order; `BenchmarksLive` +
      `BenchLive` use it as the index into the run.
      """,
      examples: [
        """
        ---
        kind: benchmark-run/v1
        run_id: 2026-04-23T1800Z-bench-001
        template: bench-softdev
        task: bugs-1-fix-login-timeout
        providers: [claude-code, codex, gemini-cli]
        started_at: 2026-04-23T18:00:00Z
        completed_at: 2026-04-23T18:07:12Z
        status: completed
        ---
        """
      ]
    }
  end
end
