defmodule Glorbo.Integration.AgentCreateDenialTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Glorbo.Company.Router
  alias Glorbo.Test.TmpGlorboHome

  @company "acme"

  setup do
    base = TmpGlorboHome.setup()
    company_dir = Path.join([base, "companies", @company])
    File.mkdir_p!(Path.join(company_dir, "agents/engineer/outbox"))
    File.mkdir_p!(Path.join(company_dir, "agents/engineer/inbox"))
    File.mkdir_p!(Path.join(company_dir, "history"))

    test_pid = self()
    audit_fun = fn _co, entry -> send(test_pid, {:audit, entry}) end

    {:ok, base: base, company_dir: company_dir, audit_fun: audit_fun}
  end

  describe "AC1: Router rejects agent-create routing with proper audit trail" do
    test "outbox msg to non-existent agent target → agents.create_blocked audit + no dir created" do
      ctx = Map.new(base: TmpGlorboHome.setup(), company_dir: nil)

      company_dir = Path.join([ctx.base, "companies", @company])
      File.mkdir_p!(Path.join(company_dir, "agents/engineer/outbox"))
      File.mkdir_p!(Path.join(company_dir, "agents/engineer/inbox"))
      File.mkdir_p!(Path.join(company_dir, "history"))
      ctx = %{ctx | company_dir: company_dir}

      test_pid = self()
      audit_fun = fn _co, entry -> send(test_pid, {:audit, entry}) end

      {:ok, router} =
        Router.start_link(
          name: Glorbo.Test.UniqueName.gen("rt"),
          company: @company,
          base: ctx.base,
          audit_fun: audit_fun
        )

      # Engineer attempts to message a non-existent agent — with permissive permissions.
      # Router should block at the agent-create guard BEFORE permission check.
      outbox_path =
        Path.join([ctx.company_dir, "agents/engineer/outbox", "msg-001.md"])

      File.write!(outbox_path, "Hi new hire")

      msg = %{
        sender: "engineer",
        sender_permissions: [
          {"projects", "write", "*"},
          {"chat", "write", "*"},
          {"agents", "message", "*"},
          # Even hypothetical agents:create should NOT bypass (defence-in-depth)
          {"agents", "create", "*"}
        ],
        to: "agent:new-hire",
        body: "Welcome!",
        raw_path: outbox_path,
        msg_id: "msg-001"
      }

      assert {:error, {:agent_create_blocked, "new-hire"}} = Router.route(router, msg)

      # Audits: agents.create_blocked + message.reject + permission.denied triple
      audits =
        for _ <- 1..3 do
          receive do
            {:audit, a} -> a.action
          after
            500 -> nil
          end
        end

      assert "agents.create_blocked" in audits
      assert "message.reject" in audits or "permission.denied" in audits

      # Disk state: agent dir was NOT created
      refute File.dir?(Path.join([ctx.company_dir, "agents/new-hire"]))
    end
  end
end
