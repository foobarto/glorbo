defmodule Glorbo.Company.GoalsHistoryTest do
  @moduledoc """
  GEP-63 + GEP-33 — `Glorbo.Company.Goals.add_goal/3` records its write
  in the home-history log as a `goal.create` commit targeting the new
  `goals/<id>.md` file. Separate from `goals_test.exs` (async: true,
  history-disabled sentinel path) because the global `HomeHistory.Tx`
  name forces `async: false`.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Company.Goals
  alias Glorbo.HomeHistory
  alias Glorbo.HomeHistory.Tx

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-goals-history-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([base, "companies", "acme"]))
    File.write!(Path.join(base, "config.md"), "secret_key_base: x\n")
    {:ok, _} = HomeHistory.init(base: base)

    {:ok, _tx_pid} =
      Tx.start_link(name: Glorbo.HomeHistory.Tx, base: base, debounce_ms: 30, hard_cap_ms: 200)

    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  # Poll-based wait for the commit to land (fsync can lag on loaded CI).
  defp wait_for_history_head(base, prefix, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(base, prefix, deadline)
  end

  defp do_wait(base, prefix, deadline) do
    case HomeHistory.log(base: base, limit: 5) do
      {:ok, [head | _]} ->
        cond do
          String.starts_with?(head.subject, prefix) ->
            head

          System.monotonic_time(:millisecond) < deadline ->
            Process.sleep(50)
            do_wait(base, prefix, deadline)

          true ->
            flunk("history HEAD never matched #{inspect(prefix)}; got #{inspect(head.subject)}")
        end

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          do_wait(base, prefix, deadline)
        else
          flunk("history log empty/unreadable awaiting #{inspect(prefix)}")
        end
    end
  end

  test "add_goal records a goal.create commit targeting the goal file", %{base: base} do
    co_dir = Path.join([base, "companies", "acme"])

    assert :ok =
             Goals.add_goal(co_dir, %{id: "q4-goal", name: "Q4 Goal"},
               actor: "director",
               base: base
             )

    head = wait_for_history_head(base, "goal.create: ")
    assert head.subject == "goal.create: companies/acme/goals/q4-goal.md"

    {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
    assert body =~ "Glorbo-Action: goal.create"
    assert body =~ "Glorbo-Paths: companies/acme/goals/q4-goal.md"
  end
end
