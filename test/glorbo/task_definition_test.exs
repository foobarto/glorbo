defmodule Glorbo.TaskDefinitionTest do
  use ExUnit.Case, async: true

  alias Glorbo.TaskDefinition
  alias Glorbo.Test.TmpGlorboHome

  setup do
    base = TmpGlorboHome.setup()
    company_dir = Path.join([base, "companies", "acme"])
    project_tasks_dir = Path.join([company_dir, "projects", "foo", "tasks"])
    File.mkdir_p!(project_tasks_dir)
    {:ok, base: base, company: "acme", tasks_dir: project_tasks_dir}
  end

  defp write_task(ctx, filename, content) do
    path = Path.join(ctx.tasks_dir, filename)
    File.write!(path, content)
    path
  end

  # T1 — fully populated frontmatter parses into complete struct
  test "T1: parses a fully populated task.md into TaskDefinition", ctx do
    content = """
    ---
    title: Delete stale backups
    status: pending-approval
    assigned_to: engineer
    requires_approval: director
    ---
    # Delete backups

    Body text here.
    """

    path = write_task(ctx, "t-01.md", content)

    assert {:ok, %TaskDefinition{} = td} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)

    assert td.task_id == "t-01"
    assert td.task_path == "projects/foo/tasks/t-01.md"
    assert td.title == "Delete stale backups"
    assert td.status == "pending-approval"
    assert td.assigned_to == "engineer"
    assert td.requires_approval == :director
    assert td.denial_reason == nil
    assert td.file_path == path
    assert td.prompt_body =~ "# Delete backups"
    assert td.prompt_body =~ "Body text here."
  end

  # T2 — requires_approval: false → nil
  test "T2: requires_approval false coerces to nil", ctx do
    content = """
    ---
    title: Harmless task
    status: pending
    requires_approval: false
    ---
    body
    """

    path = write_task(ctx, "t-02.md", content)

    assert {:ok, %TaskDefinition{requires_approval: nil}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T3 — requires_approval absent → nil
  test "T3: absent requires_approval coerces to nil", ctx do
    content = """
    ---
    title: Harmless task
    status: pending
    ---
    body
    """

    path = write_task(ctx, "t-03.md", content)

    assert {:ok, %TaskDefinition{requires_approval: nil}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T4 — requires_approval: "director" (string) → :director
  test "T4: string \"director\" coerces to :director", ctx do
    content = """
    ---
    title: Dangerous task
    requires_approval: "director"
    ---
    body
    """

    path = write_task(ctx, "t-04.md", content)

    assert {:ok, %TaskDefinition{requires_approval: :director}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T5 — requires_approval: true → error (ambiguous)
  test "T5: requires_approval true returns error", ctx do
    content = """
    ---
    title: Ambiguous
    requires_approval: true
    ---
    body
    """

    path = write_task(ctx, "t-05.md", content)

    assert {:error, {:invalid_requires_approval, true}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T6 — requires_approval: producer → error (only director in v0.0.1)
  test "T6: requires_approval \"producer\" returns error", ctx do
    content = """
    ---
    title: Not supported
    requires_approval: producer
    ---
    body
    """

    path = write_task(ctx, "t-06.md", content)

    assert {:error, {:invalid_requires_approval, "producer"}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T7 — missing frontmatter → no_frontmatter-equivalent; Frontmatter returns
  # {:ok, %{}, content} when the fence is absent. TaskDefinition treats empty
  # frontmatter as still-valid but with nil fields — so status remains nil,
  # title nil. We DO still expect a TaskDefinition back but with defaults.
  # The plan spec says missing YAML frontmatter returns {:error, :no_frontmatter}.
  # We interpret: "no frontmatter at all" (no --- fence) → :no_frontmatter.
  test "T7: missing frontmatter fence returns :no_frontmatter", ctx do
    content = "# Just a title\n\nNo frontmatter here.\n"
    path = write_task(ctx, "t-07.md", content)

    assert {:error, :no_frontmatter} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T8 — corrupt YAML → :yaml_error
  test "T8: corrupt YAML returns {:error, {:yaml_error, _}}", ctx do
    content = """
    ---
    title: [unclosed bracket
    status: pending
    ---
    body
    """

    path = write_task(ctx, "t-08.md", content)

    assert {:error, {:yaml_error, _}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T9 — file >10MB → :size_limit_exceeded (inherited from Phase 2 Frontmatter)
  test "T9: oversized file returns :size_limit_exceeded", ctx do
    # Write just over the 10MB cap (Phase 2 @max_content_bytes = 10_485_760)
    big_body = String.duplicate("x", 10_500_000)
    content = "---\ntitle: Big\n---\n" <> big_body

    path = write_task(ctx, "t-09.md", content)

    assert {:error, :size_limit_exceeded} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T10 — task_id derived from filename stem
  test "T10: task_id derived from filename stem", ctx do
    contents = """
    ---
    title: dated
    ---
    body
    """

    p1 = write_task(ctx, "t-01.md", contents)
    p2 = write_task(ctx, "my-task.md", contents)
    p3 = write_task(ctx, "2026-04-16-cleanup.md", contents)

    assert {:ok, %TaskDefinition{task_id: "t-01"}} =
             TaskDefinition.parse_file(p1, base: ctx.base, company: ctx.company)

    assert {:ok, %TaskDefinition{task_id: "my-task"}} =
             TaskDefinition.parse_file(p2, base: ctx.base, company: ctx.company)

    assert {:ok, %TaskDefinition{task_id: "2026-04-16-cleanup"}} =
             TaskDefinition.parse_file(p3, base: ctx.base, company: ctx.company)
  end

  # T11 — task_path is relative to company dir
  test "T11: task_path is computed as path relative to company dir", ctx do
    content = """
    ---
    title: relative
    ---
    body
    """

    path = write_task(ctx, "t-11.md", content)

    assert {:ok, %TaskDefinition{task_path: rel}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)

    assert rel == "projects/foo/tasks/t-11.md"
    refute String.starts_with?(rel, "/")
  end

  # T12 — path outside company dir → error
  test "T12: path outside company dir returns :path_outside_company", ctx do
    content = """
    ---
    title: elsewhere
    ---
    body
    """

    # Write to a completely different path (sibling company + sibling base)
    other = Path.join([ctx.base, "companies", "other", "projects", "x", "tasks"])
    File.mkdir_p!(other)
    other_path = Path.join(other, "t-12.md")
    File.write!(other_path, content)

    assert {:error, {:path_outside_company, ^other_path}} =
             TaskDefinition.parse_file(other_path, base: ctx.base, company: ctx.company)
  end

  # T13 — denial_reason round-trips
  test "T13: denial_reason round-trips into the struct", ctx do
    content = """
    ---
    title: Rejected
    status: denied
    requires_approval: director
    denial_reason: too dangerous
    ---
    body
    """

    path = write_task(ctx, "t-13.md", content)

    assert {:ok, %TaskDefinition{denial_reason: "too dangerous", status: "denied"}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T14 — unrecognized status values kept as-is (lenient)
  test "T14: unknown status string kept verbatim", ctx do
    content = """
    ---
    title: weird
    status: weird
    ---
    body
    """

    path = write_task(ctx, "t-14.md", content)

    assert {:ok, %TaskDefinition{status: "weird"}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T15 — requires_approval? true for :director
  test "T15: requires_approval? true for :director struct" do
    td = %TaskDefinition{requires_approval: :director}
    assert TaskDefinition.requires_approval?(td) == true
  end

  # T16 — requires_approval? false for nil
  test "T16: requires_approval? false for nil" do
    td = %TaskDefinition{requires_approval: nil}
    assert TaskDefinition.requires_approval?(td) == false
  end

  # GEP-13 T17 — project-prefixed task IDs parse unchanged (shape-agnostic)
  test "T17: parses `<project>-NN.md` filenames (GEP-13)", ctx do
    content = """
    ---
    title: Prefixed
    status: pending
    ---
    body
    """

    path = write_task(ctx, "foo-42.md", content)

    assert {:ok, %TaskDefinition{task_id: "foo-42", project: "foo"}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # GEP-13 T19 — canonicalize_ref resolves prefixed ids directly
  test "T19: canonicalize_ref resolves `<project>-NN` shape directly", ctx do
    content = """
    ---
    title: direct
    ---
    body
    """

    write_task(ctx, "foo-05.md", content)

    assert {:ok, "projects/foo/tasks/foo-05.md"} =
             TaskDefinition.canonicalize_ref("foo-05",
               base: ctx.base,
               company: ctx.company
             )
  end

  # GEP-13 T20 — canonicalize_ref resolves legacy `t-NN` by scanning projects
  test "T20: canonicalize_ref resolves legacy t-NN across projects", ctx do
    content = """
    ---
    title: legacy
    ---
    body
    """

    write_task(ctx, "t-99.md", content)

    assert {:ok, "projects/foo/tasks/t-99.md"} =
             TaskDefinition.canonicalize_ref("t-99",
               base: ctx.base,
               company: ctx.company
             )
  end

  # GEP-13 T21 — canonicalize_ref returns :ambiguous when two projects share id
  test "T21: canonicalize_ref returns :ambiguous when t-NN exists in two projects",
       ctx do
    content = """
    ---
    title: dup
    ---
    body
    """

    # One under projects/foo, one under projects/bar.
    write_task(ctx, "t-33.md", content)

    bar_dir = Path.join([ctx.base, "companies", ctx.company, "projects", "bar", "tasks"])
    File.mkdir_p!(bar_dir)
    File.write!(Path.join(bar_dir, "t-33.md"), content)

    assert {:error, :ambiguous} =
             TaskDefinition.canonicalize_ref("t-33",
               base: ctx.base,
               company: ctx.company
             )
  end

  # GEP-13 T22 — canonicalize_ref accepts full relative path
  test "T22: canonicalize_ref passes through a full relative task_path", ctx do
    content = """
    ---
    title: already-canonical
    ---
    body
    """

    write_task(ctx, "t-77.md", content)

    assert {:ok, "projects/foo/tasks/t-77.md"} =
             TaskDefinition.canonicalize_ref("projects/foo/tasks/t-77.md",
               base: ctx.base,
               company: ctx.company
             )
  end

  # GEP-13 T18 — hyphenated project slugs split on trailing `-digits`
  test "T18: project slug with hyphens keeps the slug; number is the trailing digits",
       ctx do
    # The tasks_dir fixture lives under `projects/foo/tasks/`. To test a
    # hyphenated slug we need a sibling project directory.
    dir = Path.join([ctx.base, "companies", ctx.company, "projects", "web-redesign", "tasks"])
    File.mkdir_p!(dir)

    content = """
    ---
    title: Hyphen slug
    ---
    body
    """

    path = Path.join(dir, "web-redesign-07.md")
    File.write!(path, content)

    assert {:ok, %TaskDefinition{task_id: "web-redesign-07", project: "web-redesign"}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end
end
