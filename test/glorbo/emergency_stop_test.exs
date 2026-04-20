defmodule Glorbo.EmergencyStopTest do
  use ExUnit.Case, async: true

  alias Glorbo.EmergencyStop

  setup do
    base = Path.join(System.tmp_dir!(), "glorbo-estop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([base, "companies", "acme"]))
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, base: base, company: "acme"}
  end

  describe "engage/2" do
    test "writes the sentinel + calls kill_fun + emits audit",
         %{base: base, company: co} do
      test_pid = self()
      kill_fun = fn company -> send(test_pid, {:killed, company}) end
      audit_fun = fn company, entry -> send(test_pid, {:audit, company, entry}) end

      :ok =
        EmergencyStop.engage(co,
          base: base,
          kill_fun: kill_fun,
          audit_fun: audit_fun,
          reason: "agent is looping"
        )

      path = Path.join([base, "companies", co, "state", "emergency-stop.md"])
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "engaged_by: director"
      assert content =~ "reason: agent is looping"

      assert_received {:killed, ^co}
      assert_received {:audit, ^co, %{action: "emergency.engage", reason: "agent is looping"}}
    end

    test "engage is idempotent — reengaging re-runs kill_fun",
         %{base: base, company: co} do
      test_pid = self()
      kill_fun = fn _ -> send(test_pid, :killed) end
      audit_fun = fn _, _ -> :ok end

      :ok = EmergencyStop.engage(co, base: base, kill_fun: kill_fun, audit_fun: audit_fun)
      :ok = EmergencyStop.engage(co, base: base, kill_fun: kill_fun, audit_fun: audit_fun)

      assert_received :killed
      assert_received :killed
    end
  end

  describe "clear/2" do
    test "removes the sentinel + emits audit", %{base: base, company: co} do
      test_pid = self()

      :ok =
        EmergencyStop.engage(co,
          base: base,
          kill_fun: fn _ -> :ok end,
          audit_fun: fn _, _ -> :ok end
        )

      assert EmergencyStop.engaged?(co, base: base)

      :ok =
        EmergencyStop.clear(co,
          base: base,
          audit_fun: fn company, entry -> send(test_pid, {:audit, company, entry}) end
        )

      refute EmergencyStop.engaged?(co, base: base)
      assert_received {:audit, ^co, %{action: "emergency.clear"}}
    end

    test "clear is idempotent — tolerates a missing sentinel",
         %{base: base, company: co} do
      assert :ok =
               EmergencyStop.clear(co,
                 base: base,
                 audit_fun: fn _, _ -> :ok end
               )
    end
  end

  describe "engaged?/2" do
    test "false by default", %{base: base, company: co} do
      refute EmergencyStop.engaged?(co, base: base)
    end

    test "true after engage", %{base: base, company: co} do
      :ok =
        EmergencyStop.engage(co,
          base: base,
          kill_fun: fn _ -> :ok end,
          audit_fun: fn _, _ -> :ok end
        )

      assert EmergencyStop.engaged?(co, base: base)
    end
  end

  describe "read_sentinel/2" do
    test "returns the frontmatter map after engage", %{base: base, company: co} do
      :ok =
        EmergencyStop.engage(co,
          base: base,
          kill_fun: fn _ -> :ok end,
          audit_fun: fn _, _ -> :ok end,
          actor: "ceo",
          reason: "runaway agent"
        )

      meta = EmergencyStop.read_sentinel(co, base: base)
      assert meta["engaged_by"] == "ceo"
      assert meta["reason"] == "runaway agent"
      assert meta["engaged_at"] =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
    end

    test "returns %{} when the sentinel is absent", %{base: base, company: co} do
      assert %{} == EmergencyStop.read_sentinel(co, base: base)
    end
  end

  describe "Dispatch integration" do
    test "check_emergency_stop refuses dispatch with :emergency_stopped",
         %{base: base, company: co} do
      # Engage using an in-memory fun that doesn't touch the registry.
      :ok =
        EmergencyStop.engage(co,
          base: base,
          kill_fun: fn _ -> :ok end,
          audit_fun: fn _, _ -> :ok end
        )

      spec = %Glorbo.Agent.Spec{
        slug: "engineer",
        company: co,
        role: "x",
        provider: "claude-code",
        model: "claude-opus-4-6",
        permissions: [],
        network: :none,
        skills: [],
        timeout_seconds: 300,
        file_path: Path.join([base, "companies/acme/agents/engineer/AGENT.md"])
      }

      task = %{
        task_id: "t-1",
        task_path: "projects/foo/tasks/t-1.md",
        prompt: "x",
        trigger: :inbox
      }

      # Pass `base` so the real engaged?/2 check hits our sentinel.
      assert {:error, :emergency_stopped} =
               Glorbo.Agent.Dispatch.execute(spec, task,
                 base: base,
                 provider_fun: fn _ -> nil end,
                 audit_fun: fn _, _ -> :ok end
               )
    end
  end
end
