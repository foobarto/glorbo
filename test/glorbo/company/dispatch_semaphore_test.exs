defmodule Glorbo.Company.DispatchSemaphoreTest do
  @moduledoc """
  Unit tests for `Glorbo.Company.DispatchSemaphore` (GEP-46 D1).
  """
  use ExUnit.Case, async: true

  alias Glorbo.Company.DispatchSemaphore

  defp start_sem!(opts \\ []) do
    name = Glorbo.Test.UniqueName.gen("dispatch_sem")

    {:ok, pid} =
      DispatchSemaphore.start_link(Keyword.merge([name: name, company: "test_co"], opts))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    pid
  end

  describe "unbounded mode (cap unset / nil)" do
    test "every acquire returns {:ok, token}" do
      sem = start_sem!()
      assert DispatchSemaphore.cap(sem) == :unbounded

      tokens =
        for _ <- 1..10 do
          assert {:ok, token} = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "i"})
          token
        end

      assert length(Enum.uniq(tokens)) == 10
      # Unbounded mode doesn't track in_flight (otherwise bookkeeping
      # would grow unbounded on a busy company that never opted in).
      assert DispatchSemaphore.in_flight(sem) == 0
    end

    test "release is a no-op (synthetic tokens not tracked)" do
      sem = start_sem!()
      assert {:ok, token} = DispatchSemaphore.acquire(sem, %{agent: "a"})
      assert DispatchSemaphore.release(sem, token) == :ok
      assert DispatchSemaphore.in_flight(sem) == 0
    end
  end

  describe "bounded mode (positive integer cap)" do
    test "acquire fills slots up to the cap" do
      sem = start_sem!(cap: 3)

      assert {:ok, t1} = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "1"})
      assert {:ok, t2} = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "2"})
      assert {:ok, t3} = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "3"})
      assert DispatchSemaphore.in_flight(sem) == 3

      assert :throttled = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "4"})
      assert :throttled = DispatchSemaphore.acquire(sem, %{agent: "b", invocation_id: "5"})

      _ = {t1, t2, t3}
    end

    test "release frees a slot for the next acquire" do
      sem = start_sem!(cap: 2)

      {:ok, t1} = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "1"})
      {:ok, _t2} = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "2"})
      assert :throttled = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "3"})

      :ok = DispatchSemaphore.release(sem, t1)
      # cast — give the semaphore a tick to process.
      :sys.get_state(sem)

      assert {:ok, _t3} = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "3"})
    end

    test "release of an unknown token is a no-op (doesn't underflow)" do
      sem = start_sem!(cap: 1)
      # Some other generation's reference; we don't recognise it.
      stale_token = make_ref()

      :ok = DispatchSemaphore.release(sem, stale_token)
      :sys.get_state(sem)

      # Cap still 1; first acquire still works.
      assert {:ok, _} = DispatchSemaphore.acquire(sem, %{agent: "a"})
    end

    test "crashed holder reclaims its slot via Process.monitor" do
      sem = start_sem!(cap: 1)
      test_pid = self()

      holder =
        spawn(fn ->
          {:ok, token} = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "1"})
          send(test_pid, {:held, token})
          # Block forever; we'll kill the process from the outside.
          Process.sleep(:infinity)
        end)

      assert_receive {:held, _token}, 500
      assert DispatchSemaphore.in_flight(sem) == 1
      assert :throttled = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "2"})

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 500

      :sys.get_state(sem)
      assert DispatchSemaphore.in_flight(sem) == 0
      assert {:ok, _} = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "2"})
    end

    test "a single pid holding multiple slots gets all of them released on crash" do
      sem = start_sem!(cap: 3)
      test_pid = self()

      holder =
        spawn(fn ->
          tokens =
            for i <- 1..3 do
              {:ok, t} = DispatchSemaphore.acquire(sem, %{agent: "a", invocation_id: "#{i}"})
              t
            end

          send(test_pid, {:held, tokens})
          Process.sleep(:infinity)
        end)

      assert_receive {:held, [_t1, _t2, _t3]}, 500
      assert DispatchSemaphore.in_flight(sem) == 3

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 500

      :sys.get_state(sem)
      assert DispatchSemaphore.in_flight(sem) == 0
    end
  end
end
