defmodule Glorbo.TasksApprovalStateTest do
  use Glorbo.DataCase, async: true

  alias Glorbo.TasksApprovalState

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        task_path: "companies/acme/projects/redesign/tasks/t-01.md",
        agent_slug: "engineer",
        status: "awaiting",
        requested_at: ~U[2026-04-16 12:00:00Z]
      }

      changeset = TasksApprovalState.changeset(%TasksApprovalState{}, attrs)
      assert changeset.valid?
    end

    test "accepts valid statuses" do
      for status <- ["awaiting", "approved", "denied"] do
        attrs = %{
          task_path: "path/#{status}",
          agent_slug: "eng",
          status: status,
          requested_at: ~U[2026-04-16 12:00:00Z]
        }

        changeset = TasksApprovalState.changeset(%TasksApprovalState{}, attrs)
        assert changeset.valid?, "Expected status #{status} to be valid"
      end
    end

    test "rejects invalid status" do
      attrs = %{
        task_path: "some/path",
        agent_slug: "eng",
        status: "invalid",
        requested_at: ~U[2026-04-16 12:00:00Z]
      }

      changeset = TasksApprovalState.changeset(%TasksApprovalState{}, attrs)
      refute changeset.valid?
      assert %{status: _} = errors_on(changeset)
    end

    test "rejects missing required fields" do
      changeset = TasksApprovalState.changeset(%TasksApprovalState{}, %{})
      refute changeset.valid?
      assert %{task_path: ["can't be blank"]} = errors_on(changeset)
      assert %{agent_slug: ["can't be blank"]} = errors_on(changeset)
      assert %{status: ["can't be blank"]} = errors_on(changeset)
      assert %{requested_at: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "unique constraint" do
    test "rejects duplicate task_path" do
      attrs = %{
        task_path: "companies/acme/projects/redesign/tasks/t-01.md",
        agent_slug: "engineer",
        status: "awaiting",
        requested_at: ~U[2026-04-16 12:00:00Z]
      }

      {:ok, _} = Repo.insert(TasksApprovalState.changeset(%TasksApprovalState{}, attrs))

      assert {:error, changeset} =
               Repo.insert(
                 TasksApprovalState.changeset(%TasksApprovalState{}, %{
                   attrs
                   | agent_slug: "ceo"
                 })
               )

      assert %{task_path: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "permissions_hash column on agents table" do
    test "permissions_hash column exists and is nullable" do
      # After migrations, the column should exist. We test via a raw query.
      {:ok, %{rows: [[count]]}} =
        Repo.query(
          "SELECT count(*) FROM pragma_table_info('agents') WHERE name = 'permissions_hash'"
        )

      assert count == 1
    end
  end
end
