defmodule Glorbo.FileSpecTest do
  @moduledoc """
  Registry-level tests for `Glorbo.FileSpec` (GEP-25 R26.1 scaffolding).

  Covers:
    * classification by path (fallback lookup when frontmatter isn't parsed)
    * classification by `kind:` (primary lookup once frontmatter loaded)
    * every registered spec module satisfies the behaviour contract
    * every spec module declares `kind` in the `<name>/<version>` shape
    * `kind:` values are globally unique
  """
  use ExUnit.Case, async: true

  alias Glorbo.FileSpec

  @expected_kinds [
    "company/v1",
    "agent/v1",
    "project/v1",
    "task/v1",
    "task-comments/v1",
    "skill/v1",
    "agent-heartbeat/v1",
    "agent-soul/v1",
    "agent-memory-index/v1",
    "agent-memory/v1",
    "sentinel-approval/v1",
    "sentinel-stuck/v1",
    "sentinel-resolution/v1",
    "braindump/v1",
    "channel-log/v1",
    "audit-event/v1",
    "inbox-archive/v1",
    "emergency-stop/v1",
    "inbox-message/v1",
    "goal/v1",
    "config/v1",
    "path-request/v1",
    "proposal/v1"
  ]

  describe "registry" do
    test "specs/0 returns all 24 per-kind modules" do
      assert length(FileSpec.specs()) == 24
    end

    test "every spec module declares a kind in `<name>/<version>` shape" do
      for mod <- FileSpec.specs() do
        kind = mod.kind()
        assert is_binary(kind), "#{inspect(mod)}.kind/0 must return a binary"

        assert Regex.match?(~r{\A[a-z][a-z0-9-]*/v[0-9]+\z}, kind),
               "#{inspect(mod)}.kind/0 = #{inspect(kind)} doesn't match `<name>/<version>`"
      end
    end

    test "kind values are unique" do
      kinds = Enum.map(FileSpec.specs(), & &1.kind())
      assert kinds == Enum.uniq(kinds), "duplicate kinds: #{inspect(kinds -- Enum.uniq(kinds))}"
    end

    test "all expected kinds are present" do
      kinds = FileSpec.specs() |> Enum.map(& &1.kind()) |> MapSet.new()

      for expected <- @expected_kinds do
        assert MapSet.member?(kinds, expected), "kind `#{expected}` missing from registry"
      end
    end

    test "every spec module's schema has :required and :optional keys" do
      for mod <- FileSpec.specs() do
        schema = mod.frontmatter_schema()
        assert is_list(schema.required), "#{inspect(mod)} schema.required must be a list"
        assert is_list(schema.optional), "#{inspect(mod)} schema.optional must be a list"
        assert :kind in schema.required, "#{inspect(mod)} must list :kind as required"
      end
    end

    test "canonical_key_order starts with :kind" do
      for mod <- FileSpec.specs() do
        order = mod.canonical_key_order()
        assert is_list(order), "#{inspect(mod)}.canonical_key_order/0 must be a list"
        assert hd(order) == :kind, "#{inspect(mod)} must put :kind first in canonical order"
      end
    end

    test "docs/0 returns title + summary for every spec" do
      for mod <- FileSpec.specs() do
        docs = mod.docs()
        assert is_binary(docs.title) and docs.title != "", "#{inspect(mod)} missing docs.title"

        assert is_binary(docs.summary) and docs.summary != "",
               "#{inspect(mod)} missing docs.summary"
      end
    end
  end

  describe "classify_by_path/1" do
    test "classifies company.md" do
      assert {:ok, Glorbo.FileSpec.CompanyMd} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/company.md")
    end

    test "classifies AGENT.md (ALLCAPS required — GEP-15)" do
      assert {:ok, Glorbo.FileSpec.AgentMd} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/agents/ceo/AGENT.md")
    end

    test "rejects lowercase agent.md (soft-migration window closed — GEP-25 D9)" do
      assert {:error, :unknown} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/agents/ceo/agent.md")
    end

    test "classifies project.md" do
      assert {:ok, Glorbo.FileSpec.ProjectMd} =
               FileSpec.classify_by_path(
                 "/home/u/.glorbo/companies/acme/projects/release/project.md"
               )
    end

    test "classifies task files by /tasks/ path segment (R28 widened)" do
      assert {:ok, Glorbo.FileSpec.TaskMd} =
               FileSpec.classify_by_path(
                 "/home/u/.glorbo/companies/acme/projects/release/tasks/release-01.md"
               )

      # Non-canonical filename still classifies as TaskMd — any *.md
      # under projects/<proj>/tasks/ is a task. The Validator
      # separately emits an info-level finding for non-canonical
      # filenames (see Glorbo.FileSpec.Validator tests).
      assert {:ok, Glorbo.FileSpec.TaskMd} =
               FileSpec.classify_by_path(
                 "/home/u/.glorbo/companies/acme/projects/release/tasks/cut-release.md"
               )
    end

    test "classifies sibling `<task>.comments.md` as TaskCommentsMd (GEP-30 D8)" do
      # Must classify BEFORE TaskMd — both match `.md` under
      # projects/<proj>/tasks/ but `.comments.md` is more specific.
      assert {:ok, Glorbo.FileSpec.TaskCommentsMd} =
               FileSpec.classify_by_path(
                 "/home/u/.glorbo/companies/acme/projects/blog/tasks/blog-2.comments.md"
               )
    end

    test "classifies skills (builtin + user override)" do
      assert {:ok, Glorbo.FileSpec.SkillMd} =
               FileSpec.classify_by_path("/opt/glorbo/priv/templates/skills/code-review.md")

      assert {:ok, Glorbo.FileSpec.SkillMd} =
               FileSpec.classify_by_path("/home/u/.glorbo/skills/code-review.md")
    end

    test "classifies HEARTBEAT.md + SOUL.md" do
      assert {:ok, Glorbo.FileSpec.HeartbeatMd} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/agents/ceo/HEARTBEAT.md")

      assert {:ok, Glorbo.FileSpec.SoulMd} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/agents/ceo/SOUL.md")
    end

    test "classifies memory index vs memory entry distinctly" do
      assert {:ok, Glorbo.FileSpec.MemoryIndexMd} =
               FileSpec.classify_by_path(
                 "/home/u/.glorbo/companies/acme/agents/ceo/memory/MEMORY.md"
               )

      for prefix <- ~w(user feedback project reference) do
        path = "/home/u/.glorbo/companies/acme/agents/ceo/memory/#{prefix}_role.md"
        assert {:ok, Glorbo.FileSpec.MemoryEntryMd} = FileSpec.classify_by_path(path)
      end
    end

    test "classifies stuck-on / awaiting-approval / resolved sentinels" do
      base = "/home/u/.glorbo/companies/acme/agents/ceo/state"

      assert {:ok, Glorbo.FileSpec.SentinelApprovalMd} =
               FileSpec.classify_by_path("#{base}/awaiting-approval-release-01.md")

      assert {:ok, Glorbo.FileSpec.SentinelStuckMd} =
               FileSpec.classify_by_path("#{base}/stuck-on-release-01.md")

      assert {:ok, Glorbo.FileSpec.SentinelResolutionMd} =
               FileSpec.classify_by_path("#{base}/resolved-retry-release-01.md")
    end

    test "classifies audit JSONL (per-company + _system)" do
      assert {:ok, Glorbo.FileSpec.AuditMonthJsonl} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/audit/2026-04.jsonl")

      assert {:ok, Glorbo.FileSpec.AuditMonthJsonl} =
               FileSpec.classify_by_path("/home/u/.glorbo/audit/_system/2026-04.jsonl")
    end

    test "classifies inbox archive JSON" do
      assert {:ok, Glorbo.FileSpec.InboxArchiveJson} =
               FileSpec.classify_by_path(
                 "/home/u/.glorbo/companies/acme/audit/_inbox_archive.json"
               )
    end

    test "classifies channel logs" do
      assert {:ok, Glorbo.FileSpec.ChannelLogMd} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/channels/general.md")
    end

    test "classifies braindump entries" do
      assert {:ok, Glorbo.FileSpec.BraindumpMd} =
               FileSpec.classify_by_path(
                 "/home/u/.glorbo/companies/acme/braindump/2026-04-21-1030.md"
               )
    end

    test "unknown paths return :unknown" do
      assert {:error, :unknown} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/RANDOM-NOTE.md")

      assert {:error, :unknown} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/something.txt")
    end

    test "soft-migration closures from GEP-25 D9" do
      # `t-01.md` in a project/foo tasks dir classifies as TaskMd
      # (the filename matches `<slug>-<NN>.md`) but the validator
      # in R26.2 will flag the stem/parent-dir mismatch (project
      # dir is `foo`, filename claims project `t`). Classification
      # is path-shape only — validation is semantic.
      assert {:ok, Glorbo.FileSpec.TaskMd} =
               FileSpec.classify_by_path(
                 "/home/u/.glorbo/companies/acme/projects/foo/tasks/t-01.md"
               )

      # A file named strictly `t-NN.md` at the project root (not
      # under tasks/) is unknown — the old GEP-13 soft-migration
      # location.
      assert {:error, :unknown} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/projects/foo/t-01.md")
    end

    test "classifies proposal/v1 by /proposals/ path segment" do
      assert {:ok, Glorbo.FileSpec.ProposalMd} =
               FileSpec.classify_by_path(
                 "/home/u/.glorbo/companies/acme/proposals/hire-writer-2026-04-21.md"
               )

      # Files outside proposals/ do NOT classify as ProposalMd
      assert {:error, :unknown} =
               FileSpec.classify_by_path("/home/u/.glorbo/companies/acme/hire-writer.md")
    end
  end

  describe "classify_by_kind/1" do
    test "classifies by frontmatter `kind:` (binary key)" do
      assert {:ok, Glorbo.FileSpec.TaskMd} =
               FileSpec.classify_by_kind(%{"kind" => "task/v1", "id" => "release-01"})
    end

    test "classifies by frontmatter `kind:` (atom key)" do
      assert {:ok, Glorbo.FileSpec.AgentMd} =
               FileSpec.classify_by_kind(%{kind: "agent/v1", slug: "ceo"})
    end

    test "missing kind returns :missing_kind" do
      assert {:error, :missing_kind} = FileSpec.classify_by_kind(%{"slug" => "acme"})
    end

    test "unknown kind returns :unknown_kind" do
      assert {:error, :unknown_kind} =
               FileSpec.classify_by_kind(%{"kind" => "something/v99"})
    end

    test "all registered kinds classify to their spec module" do
      for mod <- FileSpec.specs() do
        kind_value = mod.kind()

        assert {:ok, ^mod} = FileSpec.classify_by_kind(%{"kind" => kind_value}),
               "kind=#{kind_value} should classify to #{inspect(mod)}"
      end
    end
  end
end
