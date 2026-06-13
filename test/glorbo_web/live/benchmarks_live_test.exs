defmodule GlorboWeb.BenchmarksLiveTest do
  @moduledoc """
  GET `/benchmarks` + `/benchmarks/:run_id` (GEP-26 Phase B).
  """
  use GlorboWeb.LiveCase, async: false

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
    title: Fix login
    status: todo
    ---
    Users can't log in.
    """)

    Enum.each(providers, fn provider ->
      File.mkdir_p!(Path.join([dir, "providers", provider]))
      File.write!(Path.join([dir, "providers", provider, "output.md"]), "reply from #{provider}")
    end)

    :ok
  end

  test "/benchmarks empty state lists zero runs", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/benchmarks")
    assert html =~ "No benchmark runs on disk yet"
  end

  test "/benchmarks lists one run with providers", %{conn: conn, base: base} do
    seed_run!(base, "2026-04-23T1800Z-bench-a", ["claude-code", "codex"])

    {:ok, _view, html} = live(conn, ~p"/benchmarks")

    assert html =~ "2026-04-23T1800Z-bench-a"
    assert html =~ "bench-softdev"
    assert html =~ "claude-code"
    assert html =~ "codex"
    assert html =~ "completed"
  end

  test "/benchmarks/:run_id renders blind panels (labels hidden) + task body",
       %{conn: conn, base: base} do
    seed_run!(base, "run-xyz", ["claude-code", "codex", "gemini-cli"])

    {:ok, _view, html} = live(conn, ~p"/benchmarks/run-xyz")

    assert html =~ "Panel A"
    assert html =~ "Panel B"
    assert html =~ "Panel C"
    assert html =~ "Users can&#39;t log in" or html =~ "Users can't log in"
    # Provider names must NOT appear before scoring.
    refute html =~ ">claude-code<"
    refute html =~ ">codex<"
  end

  test "submit ranking unmasks panels + appends scores.md",
       %{conn: conn, base: base} do
    seed_run!(base, "run-zzz", ["claude-code", "codex"])

    {:ok, view, _html} = live(conn, ~p"/benchmarks/run-zzz")

    # Pick two panels in order.
    render_click(view, "select_rank", %{"panel" => "A"})
    render_click(view, "select_rank", %{"panel" => "B"})

    html = render_submit(view, "submit_ranking", %{"rationale" => "Because."})

    assert html =~ "Panels unmasked"
    # After unmask, provider names should appear as panel labels.
    assert html =~ "claude-code"
    assert html =~ "codex"

    scores =
      File.read!(Path.join([base, "benchmarks/runs/run-zzz/scores.md"]))

    assert scores =~ "Because."
    assert scores =~ "**Ranking:**"
  end

  test "submit with a partial ranking is rejected: error flash, no scores.md, panels stay masked",
       %{conn: conn, base: base} do
    seed_run!(base, "run-partial", ["claude-code", "codex"])

    {:ok, view, _html} = live(conn, ~p"/benchmarks/run-partial")

    # Only one of two panels picked — the submit handler maps it through
    # the blind order and hands a single-provider ranking to
    # `Benchmarks.score/3`, which fails `validate_ranking` because the
    # ranked set doesn't equal the provider set.
    render_click(view, "select_rank", %{"panel" => "A"})

    html = render_submit(view, "submit_ranking", %{"rationale" => "Partial."})

    assert html =~ "Score failed"
    assert html =~ "ranking_mismatch"

    # Nothing was written, and the run is still masked (the scoring form
    # is still on the page because `unmasked?` stayed false).
    refute File.exists?(Path.join([base, "benchmarks/runs/run-partial/scores.md"]))
    assert html =~ "submit ranking"
    refute html =~ "Panels unmasked"
  end

  test "re-scoring an already-scored run appends a second section to scores.md",
       %{conn: conn, base: base} do
    seed_run!(base, "run-rescore", ["claude-code", "codex"])

    # Establish a prior score on disk (the "already scored" state). This
    # also flips the manifest status to "scored".
    :ok =
      Glorbo.Benchmarks.score("run-rescore", ["claude-code", "codex"],
        base: base,
        rationale: "First pass."
      )

    # Fresh mount sees the run still masked (scoring history is rendered,
    # the form is present) — re-rank and submit a second time.
    {:ok, view, html} = live(conn, ~p"/benchmarks/run-rescore")
    assert html =~ "scoring history"
    assert html =~ "First pass."

    render_click(view, "select_rank", %{"panel" => "A"})
    render_click(view, "select_rank", %{"panel" => "B"})
    render_submit(view, "submit_ranking", %{"rationale" => "Second pass."})

    scores = File.read!(Path.join([base, "benchmarks/runs/run-rescore/scores.md"]))

    # Both events are preserved — the second appends, it does not overwrite.
    assert scores =~ "First pass."
    assert scores =~ "Second pass."

    ranking_sections =
      scores |> String.split("**Ranking:**") |> length() |> Kernel.-(1)

    assert ranking_sections == 2
  end

  test "select_rank with an invalid panel letter ranks no real panel",
       %{conn: conn, base: base} do
    seed_run!(base, "run-badpanel", ["claude-code", "codex"])

    {:ok, view, _html} = live(conn, ~p"/benchmarks/run-badpanel")

    # "Z" isn't a panel token for a two-provider run (only A and B exist).
    # The handler tracks it but no real panel matches it, so neither A nor
    # B is assigned a rank and the view renders unchanged.
    html = render_click(view, "select_rank", %{"panel" => "Z"})

    assert html =~ "Panel A"
    assert html =~ "Panel B"
    refute html =~ "rank 1"
    # No accidental scoring / unmasking happened.
    refute html =~ "Panels unmasked"
    refute html =~ "Score failed"
    assert html =~ "submit ranking"
  end
end
