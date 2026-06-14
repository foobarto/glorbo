defmodule Glorbo.FileSpec.ValidatorTest do
  @moduledoc """
  Tests for the read-only `Glorbo.FileSpec.Validator` (GEP-25 R27).

  Layout: each test seeds a minimal `/tmp/glorbo-validator-test-*`
  workspace with just the files it needs, then asserts finding codes
  and exit semantics.
  """
  use ExUnit.Case, async: true

  alias Glorbo.FileSpec.Validator

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "glorbo-validator-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  # Helper: seed a single file in the workspace at rel_path.
  defp seed(base, rel, content) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    full
  end

  describe "missing kind: field" do
    test "company.md without kind: is an error", %{base: base} do
      seed(base, "companies/acme/company.md", """
      ---
      slug: acme
      name: Acme
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)

      assert Enum.any?(findings, &(&1.severity == :error and &1.code == :missing_kind))
      assert Validator.exit_code(findings) == 1
    end

    test "task file without kind: is an error", %{base: base} do
      seed(base, "companies/acme/projects/release/tasks/release-01.md", """
      ---
      id: release-01
      title: Cut release
      status: todo
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      assert Enum.any?(findings, &(&1.code == :missing_kind))
    end
  end

  describe "happy path" do
    test "well-formed company.md with kind: company/v1 validates clean",
         %{base: base} do
      seed(base, "companies/acme/company.md", """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      ---
      """)

      %{findings: findings, stats: stats} = Validator.validate_path(base)

      refute Enum.any?(findings, &(&1.severity == :error))
      assert Validator.exit_code(findings) == 0
      assert stats.errors == 0
    end

    test "well-formed agent, task, memory entry all validate clean",
         %{base: base} do
      seed(base, "companies/acme/agents/ceo/AGENT.md", """
      ---
      kind: agent/v1
      slug: ceo
      role: Chief Executive Officer
      provider: claude-code
      network: proxy
      ---
      System prompt body.
      """)

      seed(base, "companies/acme/projects/release/tasks/release-01.md", """
      ---
      kind: task/v1
      id: release-01
      title: Cut v0.0.5 release
      status: in-progress
      ---
      Body.
      """)

      seed(base, "companies/acme/agents/ceo/memory/user_role.md", """
      ---
      kind: agent-memory/v1
      name: Director role
      description: Acme director
      type: user
      ---
      Body.
      """)

      %{findings: findings} = Validator.validate_path(base)
      assert Validator.exit_code(findings) == 0
      refute Enum.any?(findings, &(&1.severity == :error))
    end
  end

  describe "GEP-25 memory type↔filename" do
    test "a memory filename prefix that disagrees with type: is a type_filename_mismatch error",
         %{base: base} do
      # filename says feedback_, frontmatter says type: user.
      seed(base, "companies/acme/agents/ceo/memory/feedback_role.md", """
      ---
      kind: agent-memory/v1
      name: Mislabelled
      description: prefix says feedback, type says user
      type: user
      ---
      Body.
      """)

      %{findings: findings} = Validator.validate_path(base)
      assert Enum.any?(findings, &(&1.code == :type_filename_mismatch and &1.severity == :error))
    end

    test "a matching prefix and type: validates clean", %{base: base} do
      seed(base, "companies/acme/agents/ceo/memory/feedback_role.md", """
      ---
      kind: agent-memory/v1
      name: Matched
      description: prefix and type agree
      type: feedback
      ---
      Body.
      """)

      %{findings: findings} = Validator.validate_path(base)
      refute Enum.any?(findings, &(&1.code == :type_filename_mismatch))
    end

    test "a non-string type: (YAML mapping) does not crash validate", %{base: base} do
      seed(base, "companies/acme/agents/ceo/memory/feedback_role.md", """
      ---
      kind: agent-memory/v1
      name: Weird
      description: type is a mapping, not a scalar
      type:
        value: user
      ---
      Body.
      """)

      # The mismatch check must skip a non-binary type rather than raise
      # Protocol.UndefinedError on to_string/1 and abort the whole validate.
      %{findings: findings} = Validator.validate_path(base)
      assert is_list(findings)
      refute Enum.any?(findings, &(&1.code == :type_filename_mismatch))
    end
  end

  describe "enum checks" do
    test "task status out of enum is an error", %{base: base} do
      seed(base, "companies/acme/projects/release/tasks/release-01.md", """
      ---
      kind: task/v1
      id: release-01
      title: x
      status: purple
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)

      assert Enum.any?(
               findings,
               &(&1.code == :enum_out_of_range and &1.severity == :error)
             )
    end

    test "agent network out of enum is an error", %{base: base} do
      seed(base, "companies/acme/agents/ceo/AGENT.md", """
      ---
      kind: agent/v1
      slug: ceo
      role: CEO
      provider: claude-code
      network: intergalactic
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      assert Enum.any?(findings, &(&1.code == :enum_out_of_range))
    end
  end

  describe "pattern checks" do
    test "company slug with uppercase fails pattern", %{base: base} do
      seed(base, "companies/acme/company.md", """
      ---
      kind: company/v1
      slug: ACME
      name: Acme
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      assert Enum.any?(findings, &(&1.code == :pattern_mismatch))
    end
  end

  describe "kind mismatch" do
    test "kind: task/v1 at agent path is a mismatch error", %{base: base} do
      seed(base, "companies/acme/agents/ceo/AGENT.md", """
      ---
      kind: task/v1
      slug: ceo
      role: CEO
      provider: claude-code
      network: proxy
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      assert Enum.any?(findings, &(&1.code == :kind_path_mismatch))
    end
  end

  describe "unknown key" do
    test "extra frontmatter key is a warning", %{base: base} do
      seed(base, "companies/acme/company.md", """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      mystery_field: 42
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)

      assert Enum.any?(
               findings,
               &(&1.code == :unknown_key and &1.severity == :warning)
             )

      # Unknown keys don't affect exit code.
      assert Validator.exit_code(findings) == 0
    end
  end

  describe "unknown file" do
    test "foreign file is info-severity only", %{base: base} do
      seed(base, "companies/acme/RANDOM-NOTE.md", "director notes\n")

      %{findings: findings} = Validator.validate_path(base)

      assert Enum.any?(
               findings,
               &(&1.code == :unknown_file and &1.severity == :info)
             )

      assert Validator.exit_code(findings) == 0
    end
  end

  describe "YAML parse error" do
    test "broken YAML in frontmatter is an error", %{base: base} do
      seed(base, "companies/acme/company.md", """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      # genuinely broken YAML — an unclosed flow sequence
      tags: [alpha, beta
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      assert Enum.any?(findings, &(&1.code == :yaml_parse_error))
    end
  end

  describe "GEP-63 — goals: removed from company.md" do
    test "a stray company.md goals: key is an unknown_key finding", %{base: base} do
      seed(base, "companies/acme/company.md", """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      goals:
        - slug: ship-v1
          name: Ship v1
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)

      assert Enum.any?(
               findings,
               &(&1.code == :unknown_key and &1.message =~ "goals")
             )
    end
  end

  describe "opts filters" do
    test "severity: :error filters out warnings and infos", %{base: base} do
      seed(base, "companies/acme/company.md", """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      mystery_field: 42
      ---
      """)

      seed(base, "companies/acme/RANDOM.md", "notes\n")

      %{findings: findings_all} = Validator.validate_path(base)
      %{findings: findings_err} = Validator.validate_path(base, severity: :error)

      assert length(findings_err) < length(findings_all)
      # Info/warning codes excluded.
      refute Enum.any?(findings_err, &(&1.severity in [:warning, :info]))
    end

    test "kind: filters to one spec", %{base: base} do
      seed(base, "companies/acme/company.md", """
      ---
      kind: company/v1
      slug: BAD
      name: Acme
      ---
      """)

      seed(base, "companies/acme/agents/ceo/AGENT.md", """
      ---
      kind: agent/v1
      slug: ceo
      role: CEO
      provider: claude-code
      network: broken_value
      ---
      """)

      %{findings: company_only} = Validator.validate_path(base, kind: "company/v1")
      %{findings: agent_only} = Validator.validate_path(base, kind: "agent/v1")

      assert Enum.all?(company_only, fn f -> String.ends_with?(f.file, "company.md") end)
      assert Enum.all?(agent_only, fn f -> String.ends_with?(f.file, "AGENT.md") end)
    end
  end

  describe "non-canonical task filename (R28)" do
    test "info-level finding for hand-written task slugs", %{base: base} do
      seed(base, "companies/acme/projects/release/tasks/cut-release.md", """
      ---
      kind: task/v1
      id: cut-release
      title: Cut release
      status: todo
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)

      assert Enum.any?(
               findings,
               &(&1.code == :non_canonical_task_filename and &1.severity == :info)
             )

      # Info findings don't change exit code.
      assert Validator.exit_code(findings) == 0
    end

    test "canonical <project>-NN.md files pass silently", %{base: base} do
      seed(base, "companies/acme/projects/release/tasks/release-01.md", """
      ---
      kind: task/v1
      id: release-01
      title: Release task
      status: todo
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      refute Enum.any?(findings, &(&1.code == :non_canonical_task_filename))
    end
  end

  describe "GEP-47 depends_on resolution (task.dependency_missing)" do
    test "dangling depends_on is an error", %{base: base} do
      seed(base, "companies/acme/projects/release/tasks/release-02.md", """
      ---
      kind: task/v1
      id: release-02
      title: Depends on a ghost
      status: todo
      depends_on:
        - ghost-01
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)

      assert Enum.any?(
               findings,
               &(&1.code == :task_dependency_missing and &1.severity == :error)
             )

      assert Validator.exit_code(findings) == 1
    end

    test "a live task in the same project resolves the dependency", %{base: base} do
      seed(base, "companies/acme/projects/release/tasks/release-01.md", """
      ---
      kind: task/v1
      id: release-01
      title: Upstream
      status: done
      ---
      """)

      seed(base, "companies/acme/projects/release/tasks/release-02.md", """
      ---
      kind: task/v1
      id: release-02
      title: Downstream
      status: todo
      depends_on:
        - release-01
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      refute Enum.any?(findings, &(&1.code == :task_dependency_missing))
    end

    test "a task_id unique across projects resolves (cross-project)", %{base: base} do
      seed(base, "companies/acme/projects/infra/tasks/infra-09.md", """
      ---
      kind: task/v1
      id: infra-09
      title: Infra upstream
      status: in-progress
      ---
      """)

      seed(base, "companies/acme/projects/release/tasks/release-02.md", """
      ---
      kind: task/v1
      id: release-02
      title: Cross-project dependent
      status: todo
      depends_on:
        - infra-09
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      refute Enum.any?(findings, &(&1.code == :task_dependency_missing))
    end

    test "an archived (history) task resolves the dependency", %{base: base} do
      seed(base, "companies/acme/projects/release/history/tasks/release-01.md", """
      ---
      kind: task/v1
      id: release-01
      title: Archived upstream
      status: done
      ---
      """)

      seed(base, "companies/acme/projects/release/tasks/release-02.md", """
      ---
      kind: task/v1
      id: release-02
      title: Depends on archived
      status: todo
      depends_on:
        - release-01
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      refute Enum.any?(findings, &(&1.code == :task_dependency_missing))
    end

    test "a malformed depends_on entry (path-escape) is flagged, never resolved off-tree",
         %{base: base} do
      seed(base, "companies/acme/projects/release/tasks/release-02.md", """
      ---
      kind: task/v1
      id: release-02
      title: Malformed dep
      status: todo
      depends_on:
        - ../../../etc/passwd
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      assert Enum.any?(findings, &(&1.code == :task_dependency_missing))
    end

    test "no depends_on key produces no dependency finding", %{base: base} do
      seed(base, "companies/acme/projects/release/tasks/release-02.md", """
      ---
      kind: task/v1
      id: release-02
      title: No deps
      status: todo
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      refute Enum.any?(findings, &(&1.code == :task_dependency_missing))
    end

    test "resolution is robust when the base path itself contains a projects/ segment",
         %{base: outer} do
      # Nest the whole glorbo tree under a `projects/` dir: the company-root
      # derivation must not anchor on the wrong `/projects/` (a naive split on
      # the first occurrence would look under <outer>/projects and miss it).
      base = Path.join([outer, "projects", "glorbo-home"])
      File.mkdir_p!(base)

      seed(base, "companies/acme/projects/release/tasks/release-01.md", """
      ---
      kind: task/v1
      id: release-01
      title: Upstream
      status: done
      ---
      """)

      seed(base, "companies/acme/projects/release/tasks/release-02.md", """
      ---
      kind: task/v1
      id: release-02
      title: Downstream
      status: todo
      depends_on:
        - release-01
      ---
      """)

      %{findings: findings} = Validator.validate_path(base)
      refute Enum.any?(findings, &(&1.code == :task_dependency_missing))
    end
  end

  describe "stats" do
    test "stats count files_examined and severity buckets", %{base: base} do
      seed(base, "companies/acme/company.md", """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      ---
      """)

      seed(base, "companies/acme/RANDOM.md", "notes\n")

      %{stats: stats} = Validator.validate_path(base)

      assert stats.files_examined == 2
      assert stats.errors == 0
      assert stats.infos >= 1
    end
  end

  describe "symlink rejection" do
    test "validate skips symlinks (no follow)", %{base: base} do
      # Threatmodel: an agent with workspace-write could plant
      # `companies/acme/evil.md -> /etc/passwd` (or /dev/zero) to
      # turn `glorbo validate` into a DoS / arbitrary-read primitive.
      # Validator must skip symlinks entirely (lstat, not stat).
      seed(base, "companies/acme/company.md", """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      ---
      """)

      decoy = Path.join([base, "companies/acme/decoy.md"])
      File.write!(decoy, "decoy\n")

      symlink = Path.join([base, "companies/acme/symlink.md"])
      :ok = File.ln_s(decoy, symlink)

      %{stats: stats, findings: findings} = Validator.validate_path(base)

      # Only `company.md` and `decoy.md` were examined; the symlink
      # didn't get walked (no findings tagged at its path either).
      assert stats.files_examined == 2

      symlink_paths = findings |> Enum.map(& &1.file) |> Enum.uniq()
      refute Enum.any?(symlink_paths, &String.ends_with?(&1, "symlink.md"))
    end
  end
end
