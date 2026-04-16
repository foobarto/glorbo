defmodule Glorbo.BudgetSchemaTest do
  use Glorbo.DataCase, async: true

  alias Glorbo.Budget

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        agent_slug: "engineer",
        year_month: "2026-04",
        prompt_tokens: 100,
        completion_tokens: 50,
        cost_usd_cents: 5
      }

      changeset = Budget.changeset(%Budget{}, attrs)
      assert changeset.valid?
    end

    test "rejects missing agent_slug" do
      attrs = %{year_month: "2026-04"}
      changeset = Budget.changeset(%Budget{}, attrs)
      refute changeset.valid?
      assert %{agent_slug: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing year_month" do
      attrs = %{agent_slug: "engineer"}
      changeset = Budget.changeset(%Budget{}, attrs)
      refute changeset.valid?
      assert %{year_month: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects negative cost_usd_cents" do
      attrs = %{agent_slug: "eng", year_month: "2026-04", cost_usd_cents: -1}
      changeset = Budget.changeset(%Budget{}, attrs)
      refute changeset.valid?
      assert %{cost_usd_cents: _} = errors_on(changeset)
    end

    test "rejects negative prompt_tokens" do
      attrs = %{agent_slug: "eng", year_month: "2026-04", prompt_tokens: -1}
      changeset = Budget.changeset(%Budget{}, attrs)
      refute changeset.valid?
      assert %{prompt_tokens: _} = errors_on(changeset)
    end

    test "rejects negative completion_tokens" do
      attrs = %{agent_slug: "eng", year_month: "2026-04", completion_tokens: -1}
      changeset = Budget.changeset(%Budget{}, attrs)
      refute changeset.valid?
      assert %{completion_tokens: _} = errors_on(changeset)
    end
  end

  describe "unique constraint" do
    test "rejects duplicate {agent_slug, year_month}" do
      attrs = %{
        agent_slug: "engineer",
        year_month: "2026-04",
        prompt_tokens: 100,
        completion_tokens: 50,
        cost_usd_cents: 5
      }

      {:ok, _} = Repo.insert(Budget.changeset(%Budget{}, attrs))

      # With unique_constraint in changeset, the DB error is converted to a
      # changeset error. Verify the constraint fires.
      assert {:error, changeset} = Repo.insert(Budget.changeset(%Budget{}, attrs))
      assert %{agent_slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "raises ConstraintError without changeset unique_constraint" do
      attrs = %{
        agent_slug: "engineer2",
        year_month: "2026-04",
        prompt_tokens: 0,
        completion_tokens: 0,
        cost_usd_cents: 0
      }

      {:ok, _} = Repo.insert(Budget.changeset(%Budget{}, attrs))

      # Without the changeset safety net, the raw DB constraint raises
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Budget{agent_slug: "engineer2", year_month: "2026-04"})
      end
    end
  end
end
