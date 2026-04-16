defmodule Glorbo.Integration.AgentWakeInboxTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Glorbo.Agent.Registry, as: AgentRegistry
  alias Glorbo.Agent.Server, as: AgentServer
  alias Glorbo.Agent.Spec

  defp make_spec(company, slug) do
    %Spec{
      slug: slug,
      company: company,
      role: "role-#{slug}",
      provider: "claude-code",
      model: "claude-sonnet-4-5",
      permissions: [],
      heartbeat: nil,
      network: :none,
      skills: [],
      budget_usd_cents_month: nil,
      timeout_seconds: 60,
      file_path: "/tmp/fake.md"
    }
  end

  setup do
    _ = Registry.start_link(keys: :unique, name: AgentRegistry)
    :ok
  end

  describe "WI1: inbox-trigger wake (Router-equivalent direct call)" do
    test "Agent.Server accepts :inbox trigger and dispatch_fun is called with the task" do
      test_pid = self()

      dispatch_fun = fn _spec, task, _opts ->
        send(test_pid, {:dispatched, task})
        {:ok, %{exit_status: 0, usage: %{prompt_tokens: 0, completion_tokens: 0}, duration_ms: 0}}
      end

      company = "co-#{System.unique_integer([:positive])}"
      slug = "engineer"
      spec = make_spec(company, slug)

      task_sup_name = {:via, Registry, {AgentRegistry, {:agent_task_sup, company, slug}}}
      {:ok, _} = Task.Supervisor.start_link(name: task_sup_name)

      server_name = {:via, Registry, {AgentRegistry, {:agent_server, company, slug}}}

      {:ok, pid} =
        AgentServer.start_link(
          spec: spec,
          company: company,
          task_supervisor: task_sup_name,
          name: server_name,
          dispatch_fun: dispatch_fun
        )

      # Subscribe-style wake with an explicit task map
      task = %{
        task_id: "t-01",
        task_path: "projects/foo/tasks/t-01.md",
        prompt: "hi",
        trigger: :inbox
      }

      assert :ok == AgentServer.wake(pid, :inbox, task)

      assert_receive {:dispatched, ^task}, 2_000
    end
  end

  describe "WI4: director-approval wake dispatch" do
    test "Agent.Server accepts :director_approval trigger" do
      test_pid = self()

      dispatch_fun = fn _spec, task, _opts ->
        send(test_pid, {:dispatched, task})
        {:ok, %{exit_status: 0, usage: %{prompt_tokens: 0, completion_tokens: 0}, duration_ms: 0}}
      end

      company = "co-#{System.unique_integer([:positive])}"
      slug = "engineer"

      task_sup_name = {:via, Registry, {AgentRegistry, {:agent_task_sup, company, slug}}}
      {:ok, _} = Task.Supervisor.start_link(name: task_sup_name)

      {:ok, pid} =
        AgentServer.start_link(
          spec: make_spec(company, slug),
          company: company,
          task_supervisor: task_sup_name,
          dispatch_fun: dispatch_fun
        )

      task = %{
        task_id: "t-approved",
        task_path: "projects/foo/tasks/t-approved.md",
        prompt: "approved task",
        trigger: :director_approval
      }

      assert :ok == AgentServer.wake(pid, :director_approval, task)
      assert_receive {:dispatched, ^task}, 2_000
    end
  end
end
