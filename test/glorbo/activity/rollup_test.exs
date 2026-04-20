defmodule Glorbo.Activity.RollupTest do
  @moduledoc """
  Smoke-test `Glorbo.Activity.Rollup` — the CompanyLive §4 rollups.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Activity.Rollup

  setup do
    base = Path.join(System.tmp_dir!(), "rollup-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    co_path = Path.join([base, "companies", "acme"])
    File.mkdir_p!(Path.join(co_path, "audit"))
    File.mkdir_p!(Path.join([co_path, "projects", "blog", "tasks"]))

    {:ok, base: base, co_path: co_path}
  end

  test "runs_per_day counts agent.dispatch events", %{base: base, co_path: co_path} do
    now = DateTime.utc_now()
    ym = Calendar.strftime(now, "%Y-%m")
    ts = DateTime.to_iso8601(now)

    lines =
      Enum.map_join(1..3, "\n", fn _ ->
        Jason.encode!(%{ts: ts, actor: "ceo", action: "agent.dispatch", target: "x"})
      end)

    File.write!(Path.join([co_path, "audit", "#{ym}.jsonl"]), lines <> "\n")

    result = Rollup.runs_per_day(base, "acme")
    assert length(result) == 14
    # Today bucket (last element) carries the 3 dispatches
    {_date, count} = List.last(result)
    assert count == 3
  end

  test "success_rate_per_day yields nil on no-data days", %{base: base, co_path: co_path} do
    now = DateTime.utc_now()
    ym = Calendar.strftime(now, "%Y-%m")
    ts = DateTime.to_iso8601(now)

    lines =
      [
        %{
          ts: ts,
          actor: "x",
          action: "agent.complete",
          target: "t1",
          detail: %{exit_status: "0"}
        },
        %{ts: ts, actor: "x", action: "agent.complete", target: "t2", detail: %{exit_status: "1"}}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    File.write!(Path.join([co_path, "audit", "#{ym}.jsonl"]), lines <> "\n")

    result = Rollup.success_rate_per_day(base, "acme")
    assert length(result) == 14
    # Today → 50%, earlier days → nil
    {_date, last_pct} = List.last(result)
    assert last_pct == 50

    {_date, first_pct} = List.first(result)
    assert is_nil(first_pct)
  end

  test "tasks_by_status groups by frontmatter status", %{co_path: co_path} do
    tasks_dir = Path.join([co_path, "projects", "blog", "tasks"])

    File.write!(Path.join(tasks_dir, "blog-1.md"), """
    ---
    title: a
    status: todo
    ---
    """)

    File.write!(Path.join(tasks_dir, "blog-2.md"), """
    ---
    title: b
    status: done
    ---
    """)

    File.write!(Path.join(tasks_dir, "blog-3.md"), """
    ---
    title: c
    status: todo
    ---
    """)

    result = Rollup.tasks_by_status(co_path)
    assert {"todo", 2} in result
    assert {"done", 1} in result
    assert {"pending", 0} in result
  end

  test "tasks_by_priority treats nil/empty as `none`", %{co_path: co_path} do
    tasks_dir = Path.join([co_path, "projects", "blog", "tasks"])

    File.write!(Path.join(tasks_dir, "p-1.md"), """
    ---
    title: n
    ---
    """)

    File.write!(Path.join(tasks_dir, "p-2.md"), """
    ---
    title: hi
    priority: high
    ---
    """)

    result = Rollup.tasks_by_priority(co_path)
    assert {"high", 1} in result
    assert {"none", 1} in result
  end

  test "missing company dir → empty-ish results", %{base: base} do
    runs = Rollup.runs_per_day(base, "ghost")
    assert length(runs) == 14
    assert Enum.all?(runs, fn {_d, c} -> c == 0 end)

    status = Rollup.tasks_by_status(Path.join([base, "companies", "ghost"]))
    assert Enum.all?(status, fn {_k, c} -> c == 0 end)
  end
end
