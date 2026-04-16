defmodule Glorbo.Integration.ApprovalGateE2ETest do
  use Glorbo.DataCase, async: false

  @moduletag :integration

  alias Glorbo.Approvals.Gate
  alias Glorbo.TaskDefinition
  alias Glorbo.Test.TmpGlorboHome

  @company "acme"

  setup do
    base = TmpGlorboHome.setup()
    company_dir = Path.join([base, "companies", @company])
    File.mkdir_p!(Path.join(company_dir, "projects/foo/tasks"))
    File.mkdir_p!(Path.join(company_dir, "agents/engineer/state"))
    File.mkdir_p!(Path.join(company_dir, "history/tasks"))
    File.mkdir_p!(Path.join(company_dir, "audit"))

    test_pid = self()

    audit_fun = fn _server, entry ->
      send(test_pid, {:audit, entry})
      :ok
    end

    wake_fun = fn agent, trigger, task ->
      send(test_pid, {:wake, agent, trigger, task})
      :ok
    end

    {:ok,
     base: base,
     company_dir: company_dir,
     audit_fun: audit_fun,
     wake_fun: wake_fun,
     test_pid: test_pid}
  end

  defp write_task(ctx, id, attrs) do
    fm = Enum.map_join(attrs, "\n", fn {k, v} -> "#{k}: #{v}" end)
    path = Path.join([ctx.company_dir, "projects/foo/tasks", "#{id}.md"])
    File.write!(path, "---\n" <> fm <> "\n---\n# #{id}\nBody.\n")
    path
  end

  describe "AE1-AE2: full approval round-trip via Watcher PubSub broadcast" do
    test "Gate resolves approved status after PubSub event + wakes agent" do
      ctx = Map.new()

      ctx =
        Map.merge(ctx, %{
          base: TmpGlorboHome.setup(),
          company_dir: nil,
          audit_fun: fn _, _ -> :ok end,
          wake_fun: fn _, _, _ -> :ok end,
          test_pid: self()
        })

      # Re-scaffold with the ad-hoc base above
      company_dir = Path.join([ctx.base, "companies", @company])
      File.mkdir_p!(Path.join(company_dir, "projects/foo/tasks"))
      File.mkdir_p!(Path.join(company_dir, "agents/engineer/state"))
      File.mkdir_p!(Path.join(company_dir, "history/tasks"))
      ctx = %{ctx | company_dir: company_dir}

      # Configure audit + wake funs to send to self
      test_pid = self()
      audit_fun = fn _, entry -> send(test_pid, {:audit, entry}) end
      wake_fun = fn agent, trigger, task -> send(test_pid, {:wake, agent, trigger, task}) end

      {:ok, gate_pid} =
        Gate.start_link(
          company: @company,
          base: ctx.base,
          audit_fun: audit_fun,
          agent_wake_fun: wake_fun,
          subscribe?: true
        )

      on_exit(fn -> if Process.alive?(gate_pid), do: GenServer.stop(gate_pid) end)

      # Step 1: Agent (us-as-test) requests approval
      task_path =
        write_task(ctx, "t-01",
          title: "Dangerous",
          status: "pending-approval",
          requires_approval: "director"
        )

      {:ok, td} = TaskDefinition.parse_file(task_path, base: ctx.base, company: @company)

      assert :ok ==
               Gate.request_approval(gate_pid, %{
                 agent: "engineer",
                 task_definition: td,
                 requesting_trigger: :inbox
               })

      sentinel_path =
        Path.join([ctx.company_dir, "agents/engineer/state", "awaiting-approval-t-01.md"])

      assert File.exists?(sentinel_path)
      assert_receive {:audit, %{action: "approval.requested"}}, 1_000

      # Step 2: Director flips status to approved. Simulate Watcher broadcast.
      _ =
        write_task(ctx, "t-01",
          title: "Dangerous",
          status: "approved",
          requires_approval: "director"
        )

      # Simulate Watcher broadcast on `company:<co>:projects` (Plan 03-05)
      :ok =
        Phoenix.PubSub.broadcast(
          Glorbo.PubSub,
          "company:#{@company}:projects",
          {:file_event, "projects/foo/tasks/t-01.md", [:modified]}
        )

      # Flush any pending handle_info
      _ = :sys.get_state(gate_pid)

      assert_receive {:audit, %{action: "approval.granted"}}, 1_000
      assert_receive {:wake, "engineer", :director_approval, _}, 1_000
      refute File.exists?(sentinel_path)
    end
  end
end
