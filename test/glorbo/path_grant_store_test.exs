defmodule Glorbo.PathGrantStoreTest do
  use ExUnit.Case, async: false

  alias Glorbo.PathGrantStore

  test "the application store, not a company process, owns the ETS table" do
    PathGrantStore.ensure_started()

    assert :ets.info(:glorbo_path_grants, :owner) == Process.whereis(PathGrantStore)
  end

  test "a company owner crash revokes only that company's grants" do
    company = "grant-owner-#{System.unique_integer([:positive])}"
    sibling = "grant-sibling-#{System.unique_integer([:positive])}"
    owner = spawn(fn -> Process.sleep(:infinity) end)
    sibling_owner = spawn(fn -> Process.sleep(:infinity) end)

    :ok = PathGrantStore.register_company(company, owner)
    :ok = PathGrantStore.register_company(sibling, sibling_owner)

    grant(company, "task-1")
    grant(sibling, "task-2")

    Process.exit(owner, :kill)

    assert eventually(fn ->
             PathGrantStore.lookup(company, "engineer", "task-1") == :not_found
           end)

    assert {:ok, [_]} = PathGrantStore.lookup(sibling, "engineer", "task-2")

    Process.exit(sibling_owner, :kill)
  end

  defp grant(company, task_id) do
    PathGrantStore.grant(
      company,
      "engineer",
      task_id,
      [%{host_path: "/tmp/x", sandbox_path: "/external/x", mode: :read}],
      DateTime.utc_now()
    )
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
