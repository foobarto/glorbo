defmodule Glorbo.Integration.AgentCrashIsolationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Glorbo.Agent.Registry, as: AgentRegistry
  alias Glorbo.Agent.Spec
  alias Glorbo.Company.AgentSupervisor
  alias Glorbo.Test.TmpGlorboHome

  defp capture_dispatch_fun(test_pid) do
    fn _spec, _task, _opts ->
      send(test_pid, {:dispatched, self()})

      receive do
        {:finish, result} -> result
      after
        30_000 -> {:ok, %{exit_status: 0, usage: %{}, duration_ms: 0}}
      end
    end
  end

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
      file_path: "/tmp/fake-agent-#{slug}.md"
    }
  end

  defp start_agent_sup(company) do
    # Registry is global across the test — start if not present.
    _ = Registry.start_link(keys: :unique, name: AgentRegistry)

    sup_name = :"agent_sup_#{company}_#{System.unique_integer([:positive])}"

    {:ok, sup_pid} =
      AgentSupervisor.start_link(name: sup_name, company: company)

    on_exit(fn ->
      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {sup_pid, sup_name}
  end

  defp agent_server_pid(company, slug) do
    case Registry.lookup(AgentRegistry, {:agent_server, company, slug}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "CI1 + CI2: single-agent crash — siblings unaffected" do
    test "killing one agent restarts only that agent; others are stable" do
      _base = TmpGlorboHome.setup()
      company = "co-#{System.unique_integer([:positive])}"
      {sup_pid, _} = start_agent_sup(company)

      dispatch_fun = capture_dispatch_fun(self())

      for slug <- ~w(ceo engineer marketer) do
        spec = make_spec(company, slug)

        {:ok, _child_sup} =
          AgentSupervisor.start_agent(sup_pid, spec, dispatch_fun: dispatch_fun)
      end

      ceo_pid = agent_server_pid(company, "ceo")
      eng_pid = agent_server_pid(company, "engineer")
      mar_pid = agent_server_pid(company, "marketer")

      for p <- [ceo_pid, eng_pid, mar_pid], do: assert(is_pid(p) and Process.alive?(p))

      ref = Process.monitor(eng_pid)
      Process.exit(eng_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^eng_pid, _}, 2_000

      # Sibling pids unchanged
      assert Process.alive?(ceo_pid)
      assert Process.alive?(mar_pid)

      # Wait briefly for restart
      Process.sleep(150)
      new_eng = agent_server_pid(company, "engineer")
      assert is_pid(new_eng)
      assert new_eng != eng_pid
    end
  end

  describe "CI5: cross-company isolation" do
    test "killing one company's agent doesn't affect another company's agents" do
      _base = TmpGlorboHome.setup()
      co_a = "coa-#{System.unique_integer([:positive])}"
      co_b = "cob-#{System.unique_integer([:positive])}"

      {sup_a, _} = start_agent_sup(co_a)
      {sup_b, _} = start_agent_sup(co_b)

      dispatch_fun = capture_dispatch_fun(self())

      {:ok, _} =
        AgentSupervisor.start_agent(sup_a, make_spec(co_a, "engineer"),
          dispatch_fun: dispatch_fun
        )

      {:ok, _} =
        AgentSupervisor.start_agent(sup_b, make_spec(co_b, "engineer"),
          dispatch_fun: dispatch_fun
        )

      a_pid = agent_server_pid(co_a, "engineer")
      b_pid = agent_server_pid(co_b, "engineer")

      ref = Process.monitor(a_pid)
      Process.exit(a_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^a_pid, _}, 2_000

      # Company B unaffected
      assert Process.alive?(b_pid)
    end
  end
end
