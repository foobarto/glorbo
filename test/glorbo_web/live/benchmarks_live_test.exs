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
end
