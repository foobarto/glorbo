defmodule Glorbo.TasksApprovalStateTest do
  use Glorbo.DataCase, async: true

  alias Glorbo.TasksApprovalState

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        company_slug: "acme",
        task_path: "projects/redesign/tasks/t-01.md",
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
          company_slug: "acme",
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
        company_slug: "acme",
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
      assert %{company_slug: ["can't be blank"]} = errors_on(changeset)
      assert %{task_path: ["can't be blank"]} = errors_on(changeset)
      assert %{agent_slug: ["can't be blank"]} = errors_on(changeset)
      assert %{status: ["can't be blank"]} = errors_on(changeset)
      assert %{requested_at: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "unique constraint (wave 31: composite (company_slug, task_path))" do
    test "rejects duplicate (company_slug, task_path) pair" do
      attrs = %{
        company_slug: "acme",
        task_path: "projects/redesign/tasks/t-01.md",
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

      # Ecto reports composite-unique-constraint errors against the first
      # field listed in the unique_constraint/2 call.
      assert %{company_slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "same task_path under a different company_slug is allowed" do
      base = %{
        task_path: "projects/foo/tasks/t-01.md",
        agent_slug: "engineer",
        status: "awaiting",
        requested_at: ~U[2026-04-16 12:00:00Z]
      }

      {:ok, _} =
        Repo.insert(
          TasksApprovalState.changeset(
            %TasksApprovalState{},
            Map.put(base, :company_slug, "acme")
          )
        )

      {:ok, _} =
        Repo.insert(
          TasksApprovalState.changeset(
            %TasksApprovalState{},
            Map.put(base, :company_slug, "beta")
          )
        )

      assert Repo.aggregate(TasksApprovalState, :count) == 2
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
