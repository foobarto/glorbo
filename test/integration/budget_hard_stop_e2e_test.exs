defmodule Glorbo.Integration.BudgetHardStopE2ETest do
  use Glorbo.DataCase, async: false

  @moduletag :integration

  alias Glorbo.Agent.Dispatch
  alias Glorbo.Agent.Spec
  alias Glorbo.Budget.Ledger
  alias Glorbo.Company.BudgetTracker
  alias Glorbo.Test.TmpGlorboHome

  @company "acme"

  defp make_spec(slug, opts \\ []) do
    %Spec{
      slug: slug,
      company: @company,
      role: "role-#{slug}",
      provider: "claude-code",
      model: "claude-sonnet-4-5",
      permissions: [],
      heartbeat: nil,
      network: :none,
      skills: [],
      budget_usd_cents_month: Keyword.get(opts, :cap, 100),
      timeout_seconds: 60,
      file_path: "/tmp/fake.md"
    }
  end

  setup do
    base = TmpGlorboHome.setup()
    company_dir = Path.join([base, "companies", @company])
    File.mkdir_p!(Path.join(company_dir, "audit"))

    test_pid = self()
    audit_fun = fn _co, entry -> send(test_pid, {:audit, entry}) end

    {:ok, base: base, company_dir: company_dir, audit_fun: audit_fun}
  end

  describe "BE1: hard-stop aborts dispatch + emits budget.hard_stop audit" do
    test "over-cap usage row → {:stopped, :budget_hard_stop} + audit + no adapter call" do
      # Seed: cap = $1 (100 cents), used = $2 (200 cents) → over cap
      :ok =
        Ledger.record!(%{
          company_slug: @company,
          agent_slug: "engineer",
          year_month: Ledger.month_bucket(DateTime.utc_now()),
          prompt_tokens: 0,
          completion_tokens: 0,
          cost_usd_cents: 200
        })
        |> then(fn _ -> :ok end)

      # Start a BudgetTracker reading the in-memory cap from opts via budgets_fun
      test_pid = self()

      {:ok, tracker} =
        BudgetTracker.start_link(
          name: Glorbo.Test.UniqueName.gen("bt"),
          company: @company,
          budgets_fun: fn "engineer" -> 100 end,
          audit_fun: fn _, entry -> send(test_pid, {:audit, entry}) end
        )

      spec = make_spec("engineer")

      # run_fun would open a Port — in the stopped path it must NOT be called.
      run_fun = fn _, _, _ ->
        send(test_pid, :run_fun_called)
        {:ok, %{exit_status: 0}}
      end

      task = %{
        task_id: "t-be1",
        task_path: "projects/foo/tasks/t-be1.md",
        prompt: "hi",
        trigger: :inbox
      }

      result =
        Dispatch.execute(spec, task,
          budget_tracker_fun: fn _spec -> BudgetTracker.check_budget(tracker, "engineer") end,
          run_fun: run_fun
        )

      assert result == {:stopped, :budget_hard_stop}
      # Adapter binary was NEVER invoked
      refute_receive :run_fun_called, 200
      # Hard-stop audit was emitted by BudgetTracker
      assert_receive {:audit, %{action: "budget.hard_stop"}}, 500
    end
  end
end
