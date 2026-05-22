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
    kind: task/v1
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

  test "T1b: optional `goal:` frontmatter parses into td.goal", ctx do
    content = """
    ---
    kind: task/v1
    title: Weekly research
    goal: weekly-digest
    status: todo
    ---
    body
    """

    path = write_task(ctx, "t-gf.md", content)
    assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
    assert td.goal == "weekly-digest"
  end

  test "T1c: missing goal: frontmatter leaves td.goal as nil", ctx do
    content = "---\nkind: task/v1\ntitle: no-goal\n---\nbody\n"
    path = write_task(ctx, "t-ng.md", content)
    assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
    assert td.goal == nil
  end

  # T2 — requires_approval: false → nil
  test "T2: requires_approval false coerces to nil", ctx do
    content = """
    ---
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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

  # codex D-186/E-201/C-119: a path with `..` segments that lexically
  # starts with the company prefix but resolves into a SIBLING company
  # must be rejected. The old lexical starts_with? check let this through.
  test "T12b: ../ traversal escaping the company tree is rejected", ctx do
    content = """
    ---
    kind: task/v1
    title: traversal
    ---
    body
    """

    # Plant the real file in a sibling company.
    other = Path.join([ctx.base, "companies", "other", "projects", "x", "tasks"])
    File.mkdir_p!(other)
    File.write!(Path.join(other, "evil.md"), content)

    # Address it via a path that lexically begins with acme's prefix but
    # uses ../ to climb into the sibling company.
    traversal =
      Path.join([ctx.base, "companies", ctx.company, "..", "other", "projects", "x", "tasks", "evil.md"])

    assert {:error, {:path_outside_company, ^traversal}} =
             TaskDefinition.parse_file(traversal, base: ctx.base, company: ctx.company)
  end

  # T13 — denial_reason round-trips
  test "T13: denial_reason round-trips into the struct", ctx do
    content = """
    ---
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
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
    kind: task/v1
    title: Hyphen slug
    ---
    body
    """

    path = Path.join(dir, "web-redesign-07.md")
    File.write!(path, content)

    assert {:ok, %TaskDefinition{task_id: "web-redesign-07", project: "web-redesign"}} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
  end

  # T23 — #235: optional per-task `model:` + `provider:` overrides
  test "T23: parses optional model/provider override frontmatter", ctx do
    content = """
    ---
    kind: task/v1
    title: use cheaper model for this one
    status: todo
    model: claude-haiku-4-5
    provider: codex
    ---
    body
    """

    path = write_task(ctx, "t-42.md", content)

    assert {:ok, td} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)

    assert td.model == "claude-haiku-4-5"
    assert td.provider == "codex"
  end

  test "T23b: model/provider are nil when absent (preserves existing behaviour)", ctx do
    content = """
    ---
    kind: task/v1
    title: default
    status: todo
    ---
    body
    """

    path = write_task(ctx, "t-43.md", content)

    assert {:ok, td} =
             TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)

    assert td.model == nil
    assert td.provider == nil
  end

  # T25 — #243: per-task budget cap
  test "T25: parses optional budget_usd_cents cap", ctx do
    content = """
    ---
    kind: task/v1
    title: expensive research
    status: todo
    budget_usd_cents: 2500
    ---
    body
    """

    path = write_task(ctx, "t-b1.md", content)
    assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
    assert td.budget_usd_cents == 2500
  end

  test "T25b: string values parse too", ctx do
    content = """
    ---
    kind: task/v1
    title: quoted
    status: todo
    budget_usd_cents: "750"
    ---
    """

    path = write_task(ctx, "t-b2.md", content)
    assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
    assert td.budget_usd_cents == 750
  end

  test "T25c: malformed budget → nil", ctx do
    content = """
    ---
    kind: task/v1
    title: bad
    status: todo
    budget_usd_cents: abc
    ---
    """

    path = write_task(ctx, "t-b3.md", content)
    assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
    assert td.budget_usd_cents == nil
  end

  # T24 — #237: recurring tasks
  describe "recurring tasks (#237)" do
    test "T24a: schedule field parses into td.schedule", ctx do
      content = """
      ---
      kind: task/v1
      title: weekly summary
      status: todo
      schedule: every monday at 9am
      ---
      body
      """

      path = write_task(ctx, "t-r1.md", content)

      assert {:ok, td} =
               TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)

      assert td.schedule == "every monday at 9am"
    end

    test "T24b: writing status=done on a recurring task loops back to todo", ctx do
      content = """
      ---
      kind: task/v1
      title: daily standup review
      status: in-progress
      schedule: every morning
      ---
      """

      path = write_task(ctx, "t-r2.md", content)

      assert :ok = TaskDefinition.write(path, %{status: "done"})
      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
      assert td.status == "todo"
    end

    test "T24c: non-recurring task still transitions to done", ctx do
      content = """
      ---
      kind: task/v1
      title: one-off
      status: in-progress
      ---
      """

      path = write_task(ctx, "t-r3.md", content)

      assert :ok = TaskDefinition.write(path, %{status: "done"})
      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
      assert td.status == "done"
    end

    test "T24d: loop-back works with string-keyed updates", ctx do
      content = """
      ---
      kind: task/v1
      title: hourly check
      status: in-progress
      schedule: every hour
      ---
      """

      path = write_task(ctx, "t-r4.md", content)

      assert :ok = TaskDefinition.write(path, %{"status" => "done"})
      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
      assert td.status == "todo"
    end

    test "T24e2: write_frontmatter also loops back (agent-report / denial path)",
         ctx do
      content = """
      ---
      kind: task/v1
      title: weekly retro
      status: in-progress
      schedule: every friday at 5pm
      ---
      """

      path = write_task(ctx, "t-r2a.md", content)

      assert :ok =
               TaskDefinition.write_frontmatter(path, %{status: "done", title: "weekly retro"})

      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
      assert td.status == "todo"
    end

    test "T24e: other statuses on recurring tasks pass through unchanged", ctx do
      content = """
      ---
      kind: task/v1
      title: weekly
      status: todo
      schedule: every monday at 9am
      ---
      """

      path = write_task(ctx, "t-r5.md", content)

      assert :ok = TaskDefinition.write(path, %{status: "in-progress"})
      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
      assert td.status == "in-progress"
    end
  end

  # GEP-40 — chain-observability fields.
  describe "GEP-40: task chain observability fields" do
    test "G40-1: parses done_when / requested_by / peer_review_required / reviewer",
         ctx do
      content = """
      ---
      kind: task/v1
      title: Ship v1
      status: todo
      assigned_to: ceo
      requested_by: director
      severity: major
      peer_review_required: true
      reviewer: critiqueops
      done_when: |
        tag v1.0.0 exists; GH Release signed; tap updated.
      ---
      Body.
      """

      path = write_task(ctx, "ship-1.md", content)
      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)

      assert td.requested_by == "director"
      assert td.severity == :major
      assert td.peer_review_required == true
      assert td.reviewer == "critiqueops"
      assert td.done_when =~ "tag v1.0.0 exists"
    end

    test "G40-2: missing new fields default to nil / false / []", ctx do
      content = """
      ---
      kind: task/v1
      title: Minimal
      status: todo
      ---
      """

      path = write_task(ctx, "minimal.md", content)
      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)

      assert td.requested_by == nil
      assert td.peer_review_required == false
      assert td.reviewer == nil
      assert td.done_when == nil
      assert td.handoff_chain == []
    end

    test "G40-3: handoff_chain list-of-maps coerces to list of %{ts,from,to,reason}",
         ctx do
      content = """
      ---
      kind: task/v1
      title: Multi-hop
      status: in-progress
      assigned_to: engineer
      handoff_chain:
        - ts: "2026-04-24T14:00:00Z"
          from: director
          to: ceo
          reason: initial dispatch
        - ts: "2026-04-24T14:05:00Z"
          from: ceo
          to: engineer
          reason: needs build work
      ---
      """

      path = write_task(ctx, "multi-hop.md", content)
      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)

      assert length(td.handoff_chain) == 2
      [first, second] = td.handoff_chain
      assert first.from == "director"
      assert first.to == "ceo"
      assert first.reason == "initial dispatch"
      assert first.ts == "2026-04-24T14:00:00Z"
      assert second.from == "ceo"
      assert second.to == "engineer"
    end

    test "G40-4: handoff_chain entries missing required keys are dropped",
         ctx do
      content = """
      ---
      kind: task/v1
      title: Malformed chain
      status: todo
      handoff_chain:
        - ts: "2026-04-24T14:00:00Z"
          from: director
          to: ceo
          reason: good entry
        - from: ceo
          reason: bad entry (no ts, no to)
      ---
      """

      path = write_task(ctx, "bad-chain.md", content)
      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)

      assert length(td.handoff_chain) == 1
      assert hd(td.handoff_chain).reason == "good entry"
    end

    test "G40-5: peer_review_required normalises \"true\"/\"false\" strings; junk → false",
         ctx do
      # C-062: the quoted YAML string forms `"true"` / `"false"` now
      # coerce to the matching boolean. Previously `"true"` coerced to
      # `false`, which let a critical task look review-required while
      # the gate treated review as off (fail-open). Anything that is
      # neither a boolean nor `"true"`/`"false"` still falls to the
      # safe `false` default.
      true_content = """
      ---
      kind: task/v1
      title: String trick true
      status: todo
      peer_review_required: "true"
      ---
      """

      path = write_task(ctx, "string-bool-true.md", true_content)
      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
      assert td.peer_review_required == true

      false_content = """
      ---
      kind: task/v1
      title: String trick false
      status: todo
      peer_review_required: "false"
      ---
      """

      path2 = write_task(ctx, "string-bool-false.md", false_content)
      assert {:ok, td2} = TaskDefinition.parse_file(path2, base: ctx.base, company: ctx.company)
      assert td2.peer_review_required == false

      junk_content = """
      ---
      kind: task/v1
      title: String trick junk
      status: todo
      peer_review_required: "yes"
      ---
      """

      path3 = write_task(ctx, "string-bool-junk.md", junk_content)
      assert {:ok, td3} = TaskDefinition.parse_file(path3, base: ctx.base, company: ctx.company)
      assert td3.peer_review_required == false
    end

    test "G40-6: severity enum rejects unknown values (coerces to nil)",
         ctx do
      content = """
      ---
      kind: task/v1
      title: Bad severity
      status: todo
      severity: catastrophic
      ---
      """

      path = write_task(ctx, "bad-sev.md", content)
      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
      assert td.severity == nil
    end

    test "G40-7: write_frontmatter preserves handoff_chain across unrelated mutation",
         ctx do
      # Regression: write_frontmatter/2 rebuilds from @editor_keys.
      # handoff_chain is structured (list-of-maps), lives outside
      # editor_keys, and must NOT be dropped when an unrelated field
      # (status / priority / etc.) is written. @structured_keys +
      # extract_block handle this.
      content = """
      ---
      kind: task/v1
      title: Chain preserve test
      status: in-progress
      assigned_to: engineer
      handoff_chain:
        - from: director
          reason: initial dispatch
          to: ceo
          ts: "2026-04-24T14:00:00Z"
        - from: ceo
          reason: build work
          to: engineer
          ts: "2026-04-24T14:05:00Z"
      ---
      body
      """

      path = write_task(ctx, "preserve.md", content)

      # Write an unrelated scalar change — status only.
      assert :ok = TaskDefinition.write_frontmatter(path, %{status: "done"})

      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)

      # Scalar was written.
      assert td.status == "done"

      # Handoff chain preserved intact — same 2 entries, same order.
      assert length(td.handoff_chain) == 2
      assert Enum.at(td.handoff_chain, 0).from == "director"
      assert Enum.at(td.handoff_chain, 0).to == "ceo"
      assert Enum.at(td.handoff_chain, 1).from == "ceo"
      assert Enum.at(td.handoff_chain, 1).to == "engineer"
    end

    test "G40-8: write_frontmatter carries done_when through rewrites",
         ctx do
      content = """
      ---
      kind: task/v1
      title: done_when echo
      status: todo
      done_when: pipeline green; tests pass
      ---
      """

      path = write_task(ctx, "echo.md", content)

      assert :ok = TaskDefinition.write_frontmatter(path, %{status: "in-progress"})

      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
      assert td.status == "in-progress"
      assert td.done_when == "pipeline green; tests pass"
    end

    test "G40-9: write_frontmatter adds new scalar GEP-40 keys when caller includes them",
         ctx do
      # Baseline task has only required + severity. write_frontmatter/2
      # can ADD keys (unlike write/2 which only rewrites existing ones
      # via line-level substitution). Internal merge means the caller
      # still gets the existing frontmatter preserved.
      content = """
      ---
      kind: task/v1
      title: new-keys test
      status: todo
      ---
      """

      path = write_task(ctx, "write-new-keys.md", content)

      assert :ok =
               TaskDefinition.write_frontmatter(path, %{
                 severity: "major",
                 peer_review_required: true,
                 reviewer: "critiqueops",
                 requested_by: "director",
                 done_when: "ship v1"
               })

      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
      assert td.severity == :major
      assert td.peer_review_required == true
      assert td.reviewer == "critiqueops"
      assert td.requested_by == "director"
      assert td.done_when == "ship v1"
      # Title preserved via internal merge.
      assert td.title == "new-keys test"
    end

    # Codex P2 (v0.8.0 pre-release): `model:` and `provider:` are
    # task-level overrides of the agent's default dispatch config
    # (GEP-32). Pre-fix, the `@editor_keys` allowlist omitted both,
    # so any write_frontmatter call (reassign, peer-review verdict,
    # Kanban save) silently stripped them and dispatch fell back to
    # the agent default.
    test "G40-pv: write_frontmatter preserves model + provider overrides", ctx do
      content = """
      ---
      kind: task/v1
      title: tuned task
      status: todo
      model: qwen/qwen3.6-35b-a3b
      provider: opencode
      ---
      body
      """

      path = write_task(ctx, "t-pv.md", content)

      # Flip an unrelated field; model/provider should survive.
      assert :ok =
               TaskDefinition.write_frontmatter(path, %{"status" => "in-progress"})

      assert {:ok, td} = TaskDefinition.parse_file(path, base: ctx.base, company: ctx.company)
      assert td.status == "in-progress"
      # Raw frontmatter still contains model + provider.
      raw = File.read!(path)
      assert raw =~ ~r/^model: qwen\/qwen3\.6-35b-a3b$/m
      assert raw =~ ~r/^provider: opencode$/m
    end
  end
end
