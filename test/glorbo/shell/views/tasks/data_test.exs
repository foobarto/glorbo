defmodule Glorbo.Shell.Views.Tasks.DataTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Tasks.Data
  alias Glorbo.Test.TmpGlorboHome

  defp write!(base, rel, body) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
    full
  end

  defp seed_company(base, slug) do
    write!(base, "companies/#{slug}/company.md", "---\nkind: company/v1\nname: #{slug}\n---\n")
  end

  defp seed_task(base, co, project, task_id, fm \\ []) do
    body =
      ["---", "kind: task/v1"] ++
        Enum.map(fm, fn {k, v} -> "#{k}: #{v}" end) ++ ["---", "# #{task_id}"]

    write!(
      base,
      "companies/#{co}/projects/#{project}/tasks/#{task_id}.md",
      Enum.join(body, "\n") <> "\n"
    )
  end

  describe "load_tasks/2" do
    test "no projects/ dir → empty list" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      assert Data.load_tasks(base, "acme") == []
    end

    test "single task with full frontmatter populates every column" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")

      seed_task(base, "acme", "demo", "demo-01",
        title: "Wire it",
        status: "in-progress",
        assigned_to: "engineer"
      )

      [row] = Data.load_tasks(base, "acme")
      assert row.task_id == "demo-01"
      assert row.project == "demo"
      assert row.title == "Wire it"
      assert row.status == "in-progress"
      assert row.assignee == "engineer"
      assert row.lane == :in_progress
    end

    test "minimal task without status defaults to :todo lane" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      seed_task(base, "acme", "demo", "demo-02", title: "Bare")

      [row] = Data.load_tasks(base, "acme")
      assert row.lane == :todo
      assert row.status == "todo"
    end

    test "title falls back to task_id when frontmatter has no title" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      seed_task(base, "acme", "demo", "no-title")

      [row] = Data.load_tasks(base, "acme")
      assert row.title == "no-title"
    end

    test "lane mapping: pending-approval / approved / denied → :review" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")

      seed_task(base, "acme", "demo", "p1",
        status: "pending-approval",
        requires_approval: "director"
      )

      seed_task(base, "acme", "demo", "p2", status: "approved")
      seed_task(base, "acme", "demo", "p3", status: "denied")

      lanes = Data.load_tasks(base, "acme") |> Enum.map(& &1.lane)
      assert lanes == [:review, :review, :review]
    end

    test "lane mapping: done → :done; unknown status → :other" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      seed_task(base, "acme", "demo", "d1", status: "done")
      seed_task(base, "acme", "demo", "x1", status: "wonky")

      rows = Data.load_tasks(base, "acme") |> Enum.into(%{}, &{&1.task_id, &1.lane})
      assert rows["d1"] == :done
      assert rows["x1"] == :other
    end

    test "tasks across multiple projects are all collected" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      seed_task(base, "acme", "alpha", "a-01", status: "todo")
      seed_task(base, "acme", "beta", "b-01", status: "in-progress")

      rows = Data.load_tasks(base, "acme")
      project_ids = rows |> Enum.map(&{&1.project, &1.task_id}) |> Enum.sort()
      assert project_ids == [{"alpha", "a-01"}, {"beta", "b-01"}]
    end

    test "non-md files in tasks/ are skipped" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      seed_task(base, "acme", "demo", "real")

      File.write!(
        Path.join([base, "companies/acme/projects/demo/tasks/notes.txt"]),
        "stray\n"
      )

      [row] = Data.load_tasks(base, "acme")
      assert row.task_id == "real"
    end
  end

  describe "group_by_lane/1" do
    test "returns the canonical 5-lane order with empty lanes preserved" do
      grouped = Data.group_by_lane([])

      assert Enum.map(grouped, &elem(&1, 0)) == [:todo, :in_progress, :review, :done, :other]
      assert Enum.all?(grouped, fn {_lane, items} -> items == [] end)
    end

    test "groups rows by lane preserving canonical order across lanes" do
      rows = [
        %{task_id: "a", lane: :done, project: "p", title: "A", status: "done", assignee: nil},
        %{task_id: "b", lane: :todo, project: "p", title: "B", status: "todo", assignee: nil},
        %{
          task_id: "c",
          lane: :in_progress,
          project: "p",
          title: "C",
          status: "in-progress",
          assignee: nil
        }
      ]

      grouped = Data.group_by_lane(rows)

      summary =
        Enum.map(grouped, fn {lane, items} -> {lane, Enum.map(items, & &1.task_id)} end)

      assert summary ==
               [
                 {:todo, ["b"]},
                 {:in_progress, ["c"]},
                 {:review, []},
                 {:done, ["a"]},
                 {:other, []}
               ]
    end
  end

  describe "lane helpers" do
    test "lanes/0 returns canonical order" do
      assert Data.lanes() == [:todo, :in_progress, :review, :done, :other]
    end

    test "lane_label/1 produces uppercase strings for each lane" do
      assert Data.lane_label(:todo) == "TODO"
      assert Data.lane_label(:in_progress) == "IN PROGRESS"
      assert Data.lane_label(:review) == "REVIEW"
      assert Data.lane_label(:done) == "DONE"
      assert Data.lane_label(:other) == "OTHER"
    end
  end
end
