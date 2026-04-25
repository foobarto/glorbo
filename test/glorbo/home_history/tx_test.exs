defmodule Glorbo.HomeHistory.TxTest do
  @moduledoc """
  GEP-33 Phase 2b — `Glorbo.HomeHistory.Tx` GenServer.

  Each test spins up its own server pinned to a tmp home root so
  the global `Glorbo.HomeHistory.Tx` (started by the application
  supervisor) doesn't leak state in. Debounce / hard-cap windows
  are shrunk via `start_link/1` opts so the suite runs fast.
  """

  use ExUnit.Case, async: true

  alias Glorbo.HomeHistory
  alias Glorbo.HomeHistory.Tx

  @debounce_ms 50
  @hard_cap_ms 200

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-history-tx-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    File.mkdir_p!(Path.join(base, "companies/acme/agents/ceo"))
    File.write!(Path.join(base, "companies/acme/company.md"), "---\nname: acme\n---\n")
    File.write!(Path.join(base, "companies/acme/agents/ceo/AGENT.md"), "---\nname: CEO\n---\n")

    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  defp start_server(base, extra \\ []) do
    {:ok, pid} =
      Tx.start_link(
        Keyword.merge(
          [
            name: nil,
            base: base,
            debounce_ms: @debounce_ms,
            hard_cap_ms: @hard_cap_ms
          ],
          extra
        )
      )

    pid
  end

  defp init_repo(base), do: HomeHistory.init(base: base)

  describe "begin/mark/flush — explicit happy path" do
    test "single-path tx flushes synchronously into one commit", %{base: base} do
      {:ok, _} = init_repo(base)
      tx = start_server(base)

      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: edited\n---\n")

      {:ok, tx_id} =
        Tx.begin(
          %{actor: :director, action: "task.approve", target: "task-1"},
          server: tx
        )

      assert is_binary(tx_id)
      assert tx_id =~ ~r/^history-/

      :ok = Tx.mark_path(tx_id, path, server: tx)

      assert {:ok, %{sha: sha, committed: 1, skipped: []}} = Tx.flush(tx_id, server: tx)
      assert sha != ""

      {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
      assert body =~ "task.approve: task-1"
      assert body =~ "Glorbo-Tx: " <> tx_id
    end

    test "multi-mark same tx → one commit with all paths", %{base: base} do
      {:ok, _} = init_repo(base)
      tx = start_server(base)

      File.mkdir_p!(Path.join(base, "companies/acme/audit"))
      audit = Path.join(base, "companies/acme/audit/2026-04.jsonl")
      File.write!(audit, ~s({"action":"task.approve"}\n))

      company = Path.join(base, "companies/acme/company.md")
      File.write!(company, "---\nname: edited\n---\n")

      {:ok, tx_id} =
        Tx.begin(
          %{actor: :director, action: "task.approve", target: "task-1"},
          server: tx
        )

      :ok = Tx.mark_path(tx_id, company, server: tx)
      :ok = Tx.mark_path(tx_id, audit, server: tx)

      assert {:ok, %{committed: 2}} = Tx.flush(tx_id, server: tx)

      {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
      assert body =~ "company.md"
      assert body =~ "audit/2026-04.jsonl"
    end
  end

  describe "auto-flush" do
    test "debounce window fires after inactivity, commits one tx", %{base: base} do
      {:ok, _} = init_repo(base)
      tx = start_server(base)

      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: edited\n---\n")

      {:ok, tx_id} =
        Tx.begin(%{actor: :director, action: "auto.flush", target: "x"}, server: tx)

      :ok = Tx.mark_path(tx_id, path, server: tx)

      # Wait past the debounce window — server should have flushed.
      Process.sleep(@debounce_ms * 4)

      # Subsequent flush call returns :unknown_tx because the auto-
      # flush already cleared the tx out of state.
      assert {:error, :unknown_tx} = Tx.flush(tx_id, server: tx)

      # And the commit landed.
      {:ok, [head | _]} = HomeHistory.log(base: base, limit: 5)
      assert head.subject == "auto.flush: x"
    end

    test "hard cap fires even under continuous mark activity", %{base: base} do
      {:ok, _} = init_repo(base)

      # Hard cap must be > N * (loop sleep) so the loop can keep the
      # debounce timer fresh until the cap snaps.
      tx = start_server(base, debounce_ms: 30, hard_cap_ms: 120)

      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: edited\n---\n")

      {:ok, tx_id} =
        Tx.begin(%{actor: :director, action: "hard.cap", target: "x"}, server: tx)

      # Every 20 ms < debounce 30 ms, so debounce never fires; hard
      # cap at 120 ms must catch it.
      task =
        Task.async(fn ->
          Enum.each(1..20, fn _ ->
            Tx.mark_path(tx_id, path, server: tx)
            Process.sleep(20)
          end)
        end)

      Task.await(task, 1_000)

      # Give the hard-cap timer a moment to fire after the loop ends.
      Process.sleep(150)

      assert {:error, :unknown_tx} = Tx.flush(tx_id, server: tx)
      {:ok, [head | _]} = HomeHistory.log(base: base, limit: 5)
      assert head.subject == "hard.cap: x"
    end
  end

  describe "cancel/1" do
    test "drops a tx without committing", %{base: base} do
      {:ok, %{initial_commit: initial_sha}} = init_repo(base)
      tx = start_server(base)

      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: edited\n---\n")

      {:ok, tx_id} =
        Tx.begin(%{actor: :director, action: "x", target: "y"}, server: tx)

      :ok = Tx.mark_path(tx_id, path, server: tx)
      :ok = Tx.cancel(tx_id, server: tx)

      Process.sleep(@debounce_ms * 3)

      # No commit beyond the initial.
      {:ok, [head]} = HomeHistory.log(base: base, limit: 5)
      assert head.sha == initial_sha
    end

    test "cancel on unknown tx_id is idempotent :ok", %{base: base} do
      tx = start_server(base)
      assert :ok = Tx.cancel("history-nonexistent", server: tx)
    end
  end

  describe "concurrent transactions" do
    test "two open txs don't collide", %{base: base} do
      {:ok, _} = init_repo(base)
      tx = start_server(base)

      a = Path.join(base, "companies/acme/company.md")
      b = Path.join(base, "companies/acme/agents/ceo/AGENT.md")
      File.write!(a, "---\nname: edited-a\n---\n")
      File.write!(b, "---\nname: edited-b\n---\n")

      {:ok, tx_a} =
        Tx.begin(%{actor: :director, action: "tx.a", target: "a"}, server: tx)

      {:ok, tx_b} =
        Tx.begin(%{actor: {:agent, "ceo"}, action: "tx.b", target: "b"}, server: tx)

      assert tx_a != tx_b

      :ok = Tx.mark_path(tx_a, a, server: tx)
      :ok = Tx.mark_path(tx_b, b, server: tx)

      assert {:ok, %{committed: 1}} = Tx.flush(tx_a, server: tx)
      assert {:ok, %{committed: 1}} = Tx.flush(tx_b, server: tx)

      {:ok, log} = HomeHistory.log(base: base, limit: 5)
      subjects = Enum.map(log, & &1.subject)
      assert "tx.a: a" in subjects
      assert "tx.b: b" in subjects
    end
  end

  describe "history disabled (no .git/)" do
    test "flush translates :not_initialised into a no-op success",
         %{base: base} do
      tx = start_server(base)

      path = Path.join(base, "companies/acme/company.md")

      {:ok, tx_id} =
        Tx.begin(%{actor: :director, action: "x", target: "y"}, server: tx)

      :ok = Tx.mark_path(tx_id, path, server: tx)

      assert {:ok, %{sha: "", committed: 0, skipped: skipped}} =
               Tx.flush(tx_id, server: tx)

      # All marked paths surface in :skipped so the caller sees the
      # full audit trail of "what would have committed."
      assert path in skipped
    end

    test "auto-flush is silent under history-disabled", %{base: base} do
      tx = start_server(base)

      path = Path.join(base, "companies/acme/company.md")

      {:ok, tx_id} =
        Tx.begin(%{actor: :director, action: "x", target: "y"}, server: tx)

      :ok = Tx.mark_path(tx_id, path, server: tx)

      Process.sleep(@debounce_ms * 4)

      # Tx already auto-cleared even though no commit happened.
      assert {:error, :unknown_tx} = Tx.flush(tx_id, server: tx)
    end
  end

  describe "explicit tx_id" do
    test "begin honors a caller-supplied tx_id", %{base: base} do
      tx = start_server(base)

      assert {:ok, "history-explicit-1"} =
               Tx.begin(
                 %{
                   actor: :director,
                   action: "x",
                   target: "y",
                   tx_id: "history-explicit-1"
                 },
                 server: tx
               )

      :ok = Tx.cancel("history-explicit-1", server: tx)
    end
  end

  describe "unknown tx_id" do
    test "flush returns :unknown_tx for never-begun ids", %{base: base} do
      tx = start_server(base)
      assert {:error, :unknown_tx} = Tx.flush("history-ghost", server: tx)
    end

    test "mark_path on unknown tx silently drops", %{base: base} do
      tx = start_server(base)

      path = Path.join(base, "companies/acme/company.md")
      assert :ok = Tx.mark_path("history-ghost", path, server: tx)

      # And the server is still alive + responsive.
      {:ok, _} = Tx.begin(%{actor: :director, action: "x", target: "y"}, server: tx)
    end
  end
end
