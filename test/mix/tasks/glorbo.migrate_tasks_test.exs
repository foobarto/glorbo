defmodule Mix.Tasks.Glorbo.MigrateTasksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Glorbo.MigrateTasks, as: MigrateTask

  setup do
    base = Path.join(System.tmp_dir!(), "glorbo_migrate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  defp seed_task(base, company, project, filename, content \\ "---\ntitle: x\n---\n") do
    dir = Path.join([base, "companies", company, "projects", project, "tasks"])
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  test "renames t-NN.md to <project>-NN.md", %{base: base} do
    old = seed_task(base, "acme", "website", "t-01.md")

    _ = capture_io(fn -> MigrateTask.run(["--base", base]) end)

    refute File.exists?(old)

    new =
      Path.join([base, "companies", "acme", "projects", "website", "tasks", "website-01.md"])

    assert File.exists?(new)
  end

  test "emits task.migrate audit event with from/to paths", %{base: base} do
    seed_task(base, "acme", "website", "t-01.md")

    _ = capture_io(fn -> MigrateTask.run(["--base", base]) end)

    audit_dir = Path.join([base, "companies", "acme", "audit"])
    [file] = File.ls!(audit_dir) |> Enum.filter(&String.ends_with?(&1, ".jsonl"))

    entry =
      audit_dir
      |> Path.join(file)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> List.last()
      |> Jason.decode!()

    assert entry["action"] == "task.migrate"
    assert entry["target"] == "projects/website/tasks/website-01.md"
    assert entry["detail"]["from"] == "projects/website/tasks/t-01.md"
    assert entry["detail"]["to"] == "projects/website/tasks/website-01.md"
    assert entry["detail"]["gep"] == "GEP-13"
  end

  test "dry-run does not rename or emit audit", %{base: base} do
    old = seed_task(base, "acme", "website", "t-01.md")

    _ = capture_io(fn -> MigrateTask.run(["--base", base, "--dry-run"]) end)

    assert File.exists?(old)
    assert File.ls!(Path.join([base, "companies", "acme"])) |> Enum.member?("projects")
    # No audit dir at all.
    refute File.dir?(Path.join([base, "companies", "acme", "audit"]))
  end

  test "skips rename when target already exists (collision safety)", %{base: base} do
    old = seed_task(base, "acme", "website", "t-01.md")
    _ = seed_task(base, "acme", "website", "website-01.md", "---\ntitle: existing\n---\n")

    output = capture_io(fn -> MigrateTask.run(["--base", base]) end)

    # Old file remains since we couldn't rename over the existing one.
    assert File.exists?(old)
    assert output =~ "skip"
  end

  test "handles multiple companies and projects", %{base: base} do
    seed_task(base, "acme", "website", "t-01.md")
    seed_task(base, "acme", "api", "t-07.md")
    seed_task(base, "beta", "platform", "t-03.md")

    _ = capture_io(fn -> MigrateTask.run(["--base", base]) end)

    assert File.exists?(
             Path.join([
               base,
               "companies",
               "acme",
               "projects",
               "website",
               "tasks",
               "website-01.md"
             ])
           )

    assert File.exists?(
             Path.join([base, "companies", "acme", "projects", "api", "tasks", "api-07.md"])
           )

    assert File.exists?(
             Path.join([
               base,
               "companies",
               "beta",
               "projects",
               "platform",
               "tasks",
               "platform-03.md"
             ])
           )
  end

  test "non-matching files are left alone", %{base: base} do
    readme = seed_task(base, "acme", "website", "README.md", "nothing\n")
    already = seed_task(base, "acme", "website", "website-02.md", "---\ntitle: x\n---\n")

    _ = capture_io(fn -> MigrateTask.run(["--base", base]) end)

    assert File.exists?(readme)
    assert File.exists?(already)
  end
end
