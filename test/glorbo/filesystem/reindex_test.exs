defmodule Glorbo.Filesystem.ReindexTest do
  use Glorbo.DataCase, async: false

  alias Glorbo.{Agent, Company}
  alias Glorbo.Filesystem.{Reindex, ReindexState}
  alias Glorbo.Test.TmpGlorboHome

  # Helper: build the companies/<co>/... scaffold and write a file.
  defp write!(base, rel, content) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    full
  end

  # Helper: write a minimal `companies/acme/company.md` so reindex's
  # group-by-company filter accepts the audit JSONL siblings the test
  # then writes. Returns the file path.
  defp seed_company(base, slug \\ "acme") do
    write!(base, "companies/#{slug}/company.md", "---\nname: #{slug}\n---\n")
  end

  describe "run/1 (Tests 5–11)" do
    test "Test 5: empty companies tree returns {:ok, %{indexed: 0, skipped: 0, deleted: 0}}" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join(base, "companies"))

      assert {:ok, %{indexed: 0, skipped: 0, deleted: 0}} = Reindex.run(base: base)
    end

    test "Test 5b: missing companies dir returns zero counts without crashing" do
      base = TmpGlorboHome.setup()
      # no companies dir
      assert {:ok, %{indexed: 0, skipped: 0, deleted: 0}} = Reindex.run(base: base)
    end

    test "Test 6: company.md is inserted into companies table" do
      base = TmpGlorboHome.setup()

      company_path =
        write!(
          base,
          "companies/acme/company.md",
          "---\nname: acme\nmission: do stuff\n---\n# Acme\n"
        )

      assert {:ok, %{indexed: 1}} = Reindex.run(base: base)

      [row] = Repo.all(Company)
      assert row.name == "acme"
      assert row.mission == "do stuff"
      assert row.file_path == company_path
    end

    test "Test 7: agent.md is inserted and linked to its company" do
      base = TmpGlorboHome.setup()

      _co = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      agent_path =
        write!(
          base,
          "companies/acme/agents/ceo/agent.md",
          "---\nname: ceo\nrole: CEO\nprovider: ollama\nmodel: qwen3:8b\n---\n"
        )

      assert {:ok, %{indexed: 2}} = Reindex.run(base: base)

      [company] = Repo.all(Company)
      [agent] = Repo.all(Agent)

      assert agent.name == "ceo"
      assert agent.role == "CEO"
      assert agent.provider == "ollama"
      assert agent.model == "qwen3:8b"
      assert agent.company_id == company.id
      assert agent.file_path == agent_path
    end

    test "Test 8: re-running without changes is a no-op (all unchanged)" do
      base = TmpGlorboHome.setup()
      write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      assert {:ok, %{indexed: 1}} = Reindex.run(base: base)
      # Second pass: md5 matches → unchanged
      assert {:ok, %{indexed: 0, skipped: 0, deleted: 0}} = Reindex.run(base: base)

      # reindex_state has exactly 1 row
      assert length(Repo.all(ReindexState)) == 1
    end

    test "Test 9: modifying a file re-indexes it" do
      base = TmpGlorboHome.setup()
      path = write!(base, "companies/acme/company.md", "---\nname: acme\n---\nv1\n")

      assert {:ok, %{indexed: 1}} = Reindex.run(base: base)

      # Modify the file content — md5 must change
      File.write!(path, "---\nname: acme\nmission: updated\n---\nv2\n")

      assert {:ok, %{indexed: 1}} = Reindex.run(base: base)

      [row] = Repo.all(Company)
      assert row.mission == "updated"
    end

    test "Test 10: deleting a file deletes its reindex_state + domain row" do
      base = TmpGlorboHome.setup()

      write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")
      agent = write!(base, "companies/acme/agents/ceo/agent.md", "---\nname: ceo\n---\n")

      assert {:ok, %{indexed: 2}} = Reindex.run(base: base)
      assert length(Repo.all(Agent)) == 1

      File.rm!(agent)

      assert {:ok, %{deleted: 1}} = Reindex.run(base: base)
      assert Repo.all(Agent) == []
      # Company row is untouched
      assert length(Repo.all(Company)) == 1
    end

    test "Test 11: corrupt YAML is skipped, logged, other files still indexed" do
      base = TmpGlorboHome.setup()

      # Valid company
      write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      # Corrupt agent
      write!(
        base,
        "companies/acme/agents/ceo/agent.md",
        "---\nname: : : :\n  - broken\n  garbage:\n---\nbody\n"
      )

      import ExUnit.CaptureLog

      {result, log} =
        with_log(fn ->
          Reindex.run(base: base)
        end)

      assert {:ok, %{indexed: 1, skipped: 1}} = result
      assert log =~ "skipped"

      # Company still indexed
      assert length(Repo.all(Company)) == 1
      assert Repo.all(Agent) == []
    end

    test "symlinked markdown file is refused by safe_markdown_files filter" do
      base = TmpGlorboHome.setup()
      external = write!(base, "outside/company.md", "---\nname: leak\n---\n")
      company_dir = Path.join(base, "companies/acme")
      File.mkdir_p!(company_dir)
      File.ln_s!(external, Path.join(company_dir, "company.md"))

      # The file-collector filters out paths with a symlinked ancestor
      # before process_file/1 even sees them, so it neither indexes nor
      # counts as a "skipped" processing — it's just not picked up.
      # The structured result is the security contract: `indexed: 0`
      # proves the smuggled company.md never reached the DB.
      assert {:ok, %{indexed: 0, skipped: 0, deleted: 0}} = Reindex.run(base: base)
      assert Repo.all(Company) == []
    end

    test "symlinked directory ANCESTOR rejected (codex/opencode round-3)" do
      base = TmpGlorboHome.setup()
      # External target that smuggles a company.md with bad content.
      outside = Path.join(base, "attacker-tree/companies/smuggled")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "company.md"), "---\nname: smuggled\n---\n")

      # Symlink companies/smuggled → attacker-tree/companies/smuggled.
      File.mkdir_p!(Path.join(base, "companies"))
      link = Path.join([base, "companies", "smuggled"])
      File.ln_s!(outside, link)

      import ExUnit.CaptureLog

      {result, log} =
        with_log(fn ->
          Reindex.run(base: base)
        end)

      assert {:ok, %{indexed: 0, skipped: 0, deleted: 0}} = result
      assert log =~ "symlinked ancestor segment"
      # Smuggled company stayed out of the DB.
      assert Repo.all(Company) |> Enum.any?(&(&1.name == "smuggled")) == false
    end
  end

  describe "audit_events rebuild from JSONL (GEP-34 / wave-29)" do
    alias Glorbo.AuditEvent

    test "stream-imports company audit JSONL into audit_events on full reindex" do
      base = TmpGlorboHome.setup()
      _co = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      jsonl =
        ~s|{"ts":"2026-04-26T01:23:45Z","company":"acme","actor":"ceo","action":"task.create","target":"projects/x/tasks/x-01.md"}\n| <>
          ~s|{"ts":"2026-04-26T01:24:00Z","company":"acme","actor":"director","action":"approval.granted","target":"projects/x/tasks/x-01.md","detail":"ok"}\n|

      _audit = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{audit_events: 2}} = Reindex.run(base: base)

      events = AuditEvent |> Repo.all() |> Enum.sort_by(& &1.ts)
      assert length(events) == 2
      [first, second] = events
      assert first.actor == "ceo"
      assert first.action == "task.create"
      assert first.company == "acme"
      assert second.action == "approval.granted"
      # `detail` column is JSON-encoded — the inline `detail` key from
      # the JSONL is preserved while the well-known top-level keys are
      # peeled off.
      assert {:ok, %{"detail" => "ok"}} = Jason.decode(second.detail)
      refute Jason.decode!(second.detail) |> Map.has_key?("ts")
      refute Jason.decode!(second.detail) |> Map.has_key?("actor")
    end

    test "wipes existing rows so reindex is idempotent" do
      base = TmpGlorboHome.setup()
      _co = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      jsonl =
        ~s|{"ts":"2026-04-26T01:23:45Z","company":"acme","actor":"ceo","action":"task.create","target":"x"}\n|

      _audit = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{audit_events: 1}} = Reindex.run(base: base)
      assert {:ok, %{audit_events: 1}} = Reindex.run(base: base)
      # 1 row, not 2 — second run wiped the table before re-importing.
      assert length(Repo.all(AuditEvent)) == 1
    end

    test "imports `_system` events under company `_system` (subdirectory layout)" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join(base, "companies"))

      jsonl =
        ~s|{"ts":"2026-04-26T01:00:00Z","actor":"system","action":"orchestrator.boot","target":"all"}\n|

      # Production layout: `Company.AuditLog.jsonl_path/3` puts orchestrator
      # events at `<base>/audit/_system/<YYYY-MM>.jsonl` (subdirectory),
      # not flat under `<base>/audit/`.
      _audit = write!(base, "audit/_system/2026-04.jsonl", jsonl)

      assert {:ok, %{audit_events: 1}} = Reindex.run(base: base)
      [row] = Repo.all(AuditEvent)
      assert row.company == "_system"
      assert row.action == "orchestrator.boot"
    end

    test "ignores legacy flat `<base>/audit/*.jsonl` (writer never produces this)" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join(base, "companies"))

      # Pre-fix layout written under the wrong path. The fixed reader looks
      # under `audit/_system/` only, so this file is correctly ignored.
      jsonl =
        ~s|{"ts":"2026-04-26T01:00:00Z","actor":"system","action":"orchestrator.boot","target":"all"}\n|

      _ = write!(base, "audit/2026-04.jsonl", jsonl)

      assert {:ok, %{audit_events: 0}} = Reindex.run(base: base)
      assert Repo.all(AuditEvent) == []
    end

    test "skips malformed JSONL lines without crashing" do
      base = TmpGlorboHome.setup()
      _co = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      mixed =
        ~s|{"ts":"2026-04-26T01:00:00Z","actor":"ceo","action":"good","target":"x"}\n| <>
          "not-json garbage line\n" <>
          ~s|{"missing":"required-fields"}\n| <>
          ~s|{"ts":"2026-04-26T01:01:00Z","actor":"ceo","action":"good2","target":"y"}\n|

      _audit = write!(base, "companies/acme/audit/2026-04.jsonl", mixed)

      assert {:ok, %{audit_events: 2}} = Reindex.run(base: base)
      events = Repo.all(AuditEvent)
      assert Enum.map(events, & &1.action) |> Enum.sort() == ["good", "good2"]
    end

    test "drops oversized lines (> 64KiB) with a warning" do
      base = TmpGlorboHome.setup()
      _co = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      huge_target = String.duplicate("X", 70_000)

      jsonl =
        ~s|{"ts":"2026-04-26T01:00:00Z","actor":"ceo","action":"big","target":"#{huge_target}"}\n| <>
          ~s|{"ts":"2026-04-26T01:01:00Z","actor":"ceo","action":"small","target":"y"}\n|

      _audit = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      log = ExUnit.CaptureLog.capture_log(fn -> Reindex.run(base: base) end)
      assert log =~ "oversized line"

      [row] = Repo.all(AuditEvent)
      assert row.action == "small"
    end
  end

  describe "slug validation on JSONL fields (wave 30 defense-in-depth)" do
    alias Glorbo.{AuditEvent, Budget, TasksApprovalState}

    test "Phase 1: bad `company` slug in JSONL is ignored (dirname canonical)" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"../../etc","actor":"ceo","action":"task.create","target":"x"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{audit_events: 1}} = Reindex.run(base: base)
      [row] = Repo.all(AuditEvent)
      assert row.company == "acme"
    end

    test "Phase 1 wave 33: dirname is canonical — JSONL spoof of `company:` is ignored" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")
      _ = write!(base, "companies/beta/company.md", "---\nname: beta\n---\n")

      # An attacker-crafted line in acme's audit dir claiming
      # `company: "beta"`. Pre-wave-33 behaviour would have stored
      # this as a row attributed to beta, polluting beta's audit
      # feed.
      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"beta","actor":"ceo","action":"task.create","target":"x"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{audit_events: 1}} = Reindex.run(base: base)
      [row] = Repo.all(AuditEvent)
      assert row.company == "acme"
    end

    test "Phase 2: non-slug `agent` skips the row" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"acme","actor":"../etc","action":"approval.requested","agent":"../etc","target":"projects/x/tasks/x-01.md","task_id":"x-01"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{tasks_approval_state: 0}} = Reindex.run(base: base)
      assert Repo.all(TasksApprovalState) == []
    end

    test "Phase 2 wave 32: dirname is canonical — JSONL `company:` is ignored" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")
      _ = write!(base, "companies/beta/company.md", "---\nname: beta\n---\n")

      # An attacker-crafted line in acme's audit dir claiming
      # `company: "beta"`. Wave 32 ignores the JSONL field — the row
      # gets attributed to acme (the dirname).
      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"beta","actor":"ceo","action":"approval.requested","agent":"ceo","target":"projects/x/tasks/x.md","task_id":"x"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{tasks_approval_state: 1}} = Reindex.run(base: base)
      [row] = Repo.all(Glorbo.TasksApprovalState)
      assert row.company_slug == "acme"
    end

    test "Phase 2: granted resolution synthesis with non-slug agent skips" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      # No prior request line — resolution would normally synthesize a row,
      # but the `agent` is non-slug, so reject instead.
      jsonl =
        ~s|{"ts":"2026-04-26T10:05:00Z","company":"acme","actor":"director","action":"approval.granted","agent":"../etc","target":"projects/z/tasks/z-03.md","approved_at":"2026-04-26T10:05:00Z"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{tasks_approval_state: 0}} = Reindex.run(base: base)
      assert Repo.all(TasksApprovalState) == []
    end

    test "Phase 3: non-slug `agent` skips the row" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"acme","actor":"../etc","action":"budget.usage","agent":"../etc","prompt_tokens":100,"completion_tokens":30,"cost_usd_cents":5}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 0}} = Reindex.run(base: base)
      assert Repo.all(Budget) == []
    end

    test "Phase 3 wave 32: dirname is canonical — JSONL `company:` is ignored" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")
      _ = write!(base, "companies/beta/company.md", "---\nname: beta\n---\n")

      # An attacker-crafted line in acme's audit dir trying to spoof
      # cross-company attribution by claiming `company: "beta"`. Wave 32
      # ignores the JSONL field — the dirname (acme) is canonical.
      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"beta","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":100,"completion_tokens":30,"cost_usd_cents":5}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 1}} = Reindex.run(base: base)
      [row] = Repo.all(Budget)
      assert row.company_slug == "acme"
    end

    test "Phase 3 wave 32: traversal-shaped `company:` field is ignored" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"../../malicious","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":100,"completion_tokens":30,"cost_usd_cents":5}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 1}} = Reindex.run(base: base)
      [row] = Repo.all(Budget)
      assert row.company_slug == "acme"
    end
  end

  describe "audit dir symlink rejection (wave 29 defense-in-depth)" do
    alias Glorbo.{AuditEvent, Budget, TasksApprovalState}

    test "all three rebuild paths refuse a symlinked companies/<co>/audit/" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      # Real audit dir somewhere reindex won't walk; we'll point a symlink
      # at it from the place where reindex DOES walk and confirm the
      # symlink is refused.
      decoy_dir = Path.join(base, "decoy_audit")
      File.mkdir_p!(decoy_dir)

      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"acme","actor":"ceo","action":"approval.requested","agent":"ceo","target":"projects/x/tasks/x-01.md","task_id":"x-01"}\n| <>
          ~s|{"ts":"2026-04-26T10:01:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":100,"completion_tokens":30,"cost_usd_cents":5}\n| <>
          ~s|{"ts":"2026-04-26T10:02:00Z","company":"acme","actor":"ceo","action":"task.create","target":"x"}\n|

      File.write!(Path.join(decoy_dir, "2026-04.jsonl"), jsonl)

      audit_dir = Path.join([base, "companies", "acme", "audit"])
      File.ln_s!(decoy_dir, audit_dir)

      log = ExUnit.CaptureLog.capture_log(fn -> Reindex.run(base: base) end)
      assert log =~ "rejected audit dir (symlinked ancestor segment)"

      # All three projections must be empty — no row was imported via the
      # symlink path.
      assert Repo.all(AuditEvent) == []
      assert Repo.all(TasksApprovalState) == []
      assert Repo.all(Budget) == []
    end

    test "_system audit symlink at <base>/audit/_system is refused" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join(base, "companies"))

      decoy_dir = Path.join(base, "decoy_system_audit")
      File.mkdir_p!(decoy_dir)

      jsonl =
        ~s|{"ts":"2026-04-26T01:00:00Z","actor":"system","action":"orchestrator.boot","target":"all"}\n|

      File.write!(Path.join(decoy_dir, "2026-04.jsonl"), jsonl)

      File.mkdir_p!(Path.join(base, "audit"))
      File.ln_s!(decoy_dir, Path.join([base, "audit", "_system"]))

      log = ExUnit.CaptureLog.capture_log(fn -> Reindex.run(base: base) end)
      assert log =~ "rejected audit dir (symlinked ancestor segment)"
      assert Repo.all(AuditEvent) == []
    end
  end

  describe "tasks_approval_state rebuild from JSONL (GEP-34 Phase 2)" do
    alias Glorbo.TasksApprovalState

    defp seed_acme(base), do: seed_company(base, "acme")

    test "awaiting-only request lands as status: awaiting" do
      base = TmpGlorboHome.setup()
      seed_acme(base)

      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"acme","actor":"ceo","action":"approval.requested","agent":"ceo","target":"projects/x/tasks/x-01.md","task_id":"x-01"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{tasks_approval_state: 1}} = Reindex.run(base: base)

      [row] = Repo.all(TasksApprovalState)
      assert row.task_path == "projects/x/tasks/x-01.md"
      assert row.agent_slug == "ceo"
      assert row.status == "awaiting"
      assert row.resolved_at == nil
      assert row.reason == nil
      assert DateTime.to_iso8601(row.requested_at) == "2026-04-26T10:00:00Z"
    end

    test "request → granted folds chronologically into approved row" do
      base = TmpGlorboHome.setup()
      seed_acme(base)

      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"acme","actor":"ceo","action":"approval.requested","agent":"ceo","target":"projects/x/tasks/x-01.md","task_id":"x-01"}\n| <>
          ~s|{"ts":"2026-04-26T10:05:00Z","company":"acme","actor":"director","action":"approval.granted","agent":"ceo","target":"projects/x/tasks/x-01.md","approved_at":"2026-04-26T10:05:00Z"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{tasks_approval_state: 1}} = Reindex.run(base: base)

      [row] = Repo.all(TasksApprovalState)
      assert row.status == "approved"
      assert row.agent_slug == "ceo"
      assert DateTime.to_iso8601(row.requested_at) == "2026-04-26T10:00:00Z"
      assert DateTime.to_iso8601(row.resolved_at) == "2026-04-26T10:05:00Z"
      assert row.reason == nil
    end

    test "request → denied carries denial_reason and denied_at" do
      base = TmpGlorboHome.setup()
      seed_acme(base)

      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"acme","actor":"editor","action":"approval.requested","agent":"editor","target":"projects/y/tasks/y-02.md","task_id":"y-02"}\n| <>
          ~s|{"ts":"2026-04-26T10:07:00Z","company":"acme","actor":"director","action":"approval.denied","agent":"editor","target":"projects/y/tasks/y-02.md","denied_at":"2026-04-26T10:07:00Z","denial_reason":"out of scope"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{tasks_approval_state: 1}} = Reindex.run(base: base)

      [row] = Repo.all(TasksApprovalState)
      assert row.status == "denied"
      assert row.reason == "out of scope"
      assert DateTime.to_iso8601(row.resolved_at) == "2026-04-26T10:07:00Z"
    end

    test "resolution without prior request synthesizes a row" do
      base = TmpGlorboHome.setup()
      seed_acme(base)

      # Audit log truncated to retention window — the original request line
      # is gone, but a granted line remains. Replay must still surface it.
      jsonl =
        ~s|{"ts":"2026-04-26T10:05:00Z","company":"acme","actor":"director","action":"approval.granted","agent":"ceo","target":"projects/z/tasks/z-03.md","approved_at":"2026-04-26T10:05:00Z"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{tasks_approval_state: 1}} = Reindex.run(base: base)

      [row] = Repo.all(TasksApprovalState)
      assert row.status == "approved"
      assert row.agent_slug == "ceo"
      # When request is missing, requested_at falls back to the resolution ts.
      assert row.requested_at == row.resolved_at
    end

    test "events spread across two monthly files fold across the boundary" do
      base = TmpGlorboHome.setup()
      seed_acme(base)

      _ =
        write!(
          base,
          "companies/acme/audit/2026-03.jsonl",
          ~s|{"ts":"2026-03-31T23:59:00Z","company":"acme","actor":"ceo","action":"approval.requested","agent":"ceo","target":"projects/x/tasks/x-01.md","task_id":"x-01"}\n|
        )

      _ =
        write!(
          base,
          "companies/acme/audit/2026-04.jsonl",
          ~s|{"ts":"2026-04-01T00:01:00Z","company":"acme","actor":"director","action":"approval.granted","agent":"ceo","target":"projects/x/tasks/x-01.md","approved_at":"2026-04-01T00:01:00Z"}\n|
        )

      assert {:ok, %{tasks_approval_state: 1}} = Reindex.run(base: base)

      [row] = Repo.all(TasksApprovalState)
      assert row.status == "approved"
      assert DateTime.to_iso8601(row.requested_at) == "2026-03-31T23:59:00Z"
      assert DateTime.to_iso8601(row.resolved_at) == "2026-04-01T00:01:00Z"
    end

    test "rebuild is idempotent — re-running does not double rows" do
      base = TmpGlorboHome.setup()
      seed_acme(base)

      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"acme","actor":"ceo","action":"approval.requested","agent":"ceo","target":"projects/x/tasks/x-01.md","task_id":"x-01"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{tasks_approval_state: 1}} = Reindex.run(base: base)
      assert {:ok, %{tasks_approval_state: 1}} = Reindex.run(base: base)
      assert length(Repo.all(TasksApprovalState)) == 1
    end

    test "wave 31: two companies with same relative task_path get isolated rows" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")
      _ = write!(base, "companies/beta/company.md", "---\nname: beta\n---\n")

      _ =
        write!(
          base,
          "companies/acme/audit/2026-04.jsonl",
          ~s|{"ts":"2026-04-26T10:00:00Z","company":"acme","actor":"ceo","action":"approval.requested","agent":"ceo","target":"projects/foo/tasks/x.md","task_id":"x"}\n|
        )

      _ =
        write!(
          base,
          "companies/beta/audit/2026-04.jsonl",
          ~s|{"ts":"2026-04-26T10:00:00Z","company":"beta","actor":"ceo","action":"approval.requested","agent":"ceo","target":"projects/foo/tasks/x.md","task_id":"x"}\n|
        )

      assert {:ok, %{tasks_approval_state: 2}} = Reindex.run(base: base)

      [acme_row, beta_row] = Repo.all(TasksApprovalState) |> Enum.sort_by(& &1.company_slug)
      assert acme_row.company_slug == "acme"
      assert acme_row.task_path == "projects/foo/tasks/x.md"
      assert beta_row.company_slug == "beta"
      assert beta_row.task_path == "projects/foo/tasks/x.md"
    end

    test "non-approval audit lines are ignored" do
      base = TmpGlorboHome.setup()
      seed_acme(base)

      jsonl =
        ~s|{"ts":"2026-04-26T01:23:45Z","company":"acme","actor":"ceo","action":"task.create","target":"projects/x/tasks/x-01.md"}\n| <>
          ~s|{"ts":"2026-04-26T01:24:00Z","company":"acme","actor":"director","action":"agent.error","target":"projects/x/tasks/x-01.md"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{tasks_approval_state: 0}} = Reindex.run(base: base)
      assert Repo.all(TasksApprovalState) == []
    end

    test "drops oversized lines (> 64KiB) without crashing" do
      base = TmpGlorboHome.setup()
      seed_acme(base)

      huge = String.duplicate("X", 70_000)

      jsonl =
        ~s|{"ts":"2026-04-26T10:00:00Z","company":"acme","actor":"ceo","action":"approval.requested","agent":"ceo","target":"#{huge}","task_id":"big"}\n| <>
          ~s|{"ts":"2026-04-26T10:01:00Z","company":"acme","actor":"ceo","action":"approval.requested","agent":"ceo","target":"projects/y/tasks/y-02.md","task_id":"y-02"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      log = ExUnit.CaptureLog.capture_log(fn -> Reindex.run(base: base) end)
      assert log =~ "oversized line"

      [row] = Repo.all(TasksApprovalState)
      assert row.task_path == "projects/y/tasks/y-02.md"
    end
  end

  describe "budgets rebuild from JSONL (GEP-34 Phase 3)" do
    alias Glorbo.Budget

    defp seed_acme_budget(base), do: seed_company(base, "acme")

    test "single budget.usage line lands as one row" do
      base = TmpGlorboHome.setup()
      seed_acme_budget(base)

      jsonl =
        ~s|{"ts":"2026-04-15T10:00:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":120,"completion_tokens":40,"cost_usd_cents":7,"model":"qwen3:8b"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 1}} = Reindex.run(base: base)

      [row] = Repo.all(Budget)
      assert row.company_slug == "acme"
      assert row.agent_slug == "ceo"
      assert row.year_month == "2026-04"
      assert row.prompt_tokens == 120
      assert row.completion_tokens == 40
      assert row.cost_usd_cents == 7
    end

    test "multiple events in same month sum into one row" do
      base = TmpGlorboHome.setup()
      seed_acme_budget(base)

      jsonl =
        ~s|{"ts":"2026-04-01T10:00:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":100,"completion_tokens":30,"cost_usd_cents":5}\n| <>
          ~s|{"ts":"2026-04-15T10:00:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":200,"completion_tokens":50,"cost_usd_cents":10}\n| <>
          ~s|{"ts":"2026-04-30T10:00:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":50,"completion_tokens":20,"cost_usd_cents":3}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 1}} = Reindex.run(base: base)

      [row] = Repo.all(Budget)
      assert row.prompt_tokens == 350
      assert row.completion_tokens == 100
      assert row.cost_usd_cents == 18
    end

    test "events spread across months produce separate rows" do
      base = TmpGlorboHome.setup()
      seed_acme_budget(base)

      _ =
        write!(
          base,
          "companies/acme/audit/2026-03.jsonl",
          ~s|{"ts":"2026-03-15T10:00:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":100,"completion_tokens":30,"cost_usd_cents":5}\n|
        )

      _ =
        write!(
          base,
          "companies/acme/audit/2026-04.jsonl",
          ~s|{"ts":"2026-04-15T10:00:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":200,"completion_tokens":60,"cost_usd_cents":11}\n|
        )

      assert {:ok, %{budgets: 2}} = Reindex.run(base: base)

      rows = Budget |> Repo.all() |> Enum.sort_by(& &1.year_month)
      assert Enum.map(rows, & &1.year_month) == ["2026-03", "2026-04"]
      assert Enum.at(rows, 0).cost_usd_cents == 5
      assert Enum.at(rows, 1).cost_usd_cents == 11
    end

    test "different agents in same month produce separate rows" do
      base = TmpGlorboHome.setup()
      seed_acme_budget(base)

      jsonl =
        ~s|{"ts":"2026-04-15T10:00:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":100,"completion_tokens":30,"cost_usd_cents":5}\n| <>
          ~s|{"ts":"2026-04-16T10:00:00Z","company":"acme","actor":"editor","action":"budget.usage","agent":"editor","prompt_tokens":200,"completion_tokens":60,"cost_usd_cents":11}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 2}} = Reindex.run(base: base)

      rows = Budget |> Repo.all() |> Enum.sort_by(& &1.agent_slug)
      assert Enum.map(rows, & &1.agent_slug) == ["ceo", "editor"]
    end

    test "two companies stay isolated" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")
      _ = write!(base, "companies/beta/company.md", "---\nname: beta\n---\n")

      _ =
        write!(
          base,
          "companies/acme/audit/2026-04.jsonl",
          ~s|{"ts":"2026-04-15T10:00:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":100,"completion_tokens":30,"cost_usd_cents":5}\n|
        )

      _ =
        write!(
          base,
          "companies/beta/audit/2026-04.jsonl",
          ~s|{"ts":"2026-04-15T10:00:00Z","company":"beta","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":700,"completion_tokens":200,"cost_usd_cents":42}\n|
        )

      assert {:ok, %{budgets: 2}} = Reindex.run(base: base)

      rows = Budget |> Repo.all() |> Enum.sort_by(& &1.company_slug)
      [acme, beta] = rows
      assert acme.company_slug == "acme"
      assert acme.cost_usd_cents == 5
      assert beta.company_slug == "beta"
      assert beta.cost_usd_cents == 42
    end

    test "rebuild is idempotent — re-running does not double rows" do
      base = TmpGlorboHome.setup()
      seed_acme_budget(base)

      jsonl =
        ~s|{"ts":"2026-04-15T10:00:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo","prompt_tokens":100,"completion_tokens":30,"cost_usd_cents":5}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 1}} = Reindex.run(base: base)
      assert {:ok, %{budgets: 1}} = Reindex.run(base: base)
      [row] = Repo.all(Budget)
      assert row.prompt_tokens == 100
      assert row.cost_usd_cents == 5
    end

    test "non-budget lines are ignored" do
      base = TmpGlorboHome.setup()
      seed_acme_budget(base)

      jsonl =
        ~s|{"ts":"2026-04-15T10:00:00Z","company":"acme","actor":"ceo","action":"task.create","target":"x"}\n| <>
          ~s|{"ts":"2026-04-15T10:01:00Z","company":"acme","actor":"director","action":"approval.granted","agent":"ceo","target":"x","approved_at":"2026-04-15T10:01:00Z"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 0}} = Reindex.run(base: base)
      assert Repo.all(Budget) == []
    end

    test "missing/invalid token fields default to zero" do
      base = TmpGlorboHome.setup()
      seed_acme_budget(base)

      jsonl =
        ~s|{"ts":"2026-04-15T10:00:00Z","company":"acme","actor":"ceo","action":"budget.usage","agent":"ceo"}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 1}} = Reindex.run(base: base)

      [row] = Repo.all(Budget)
      assert row.prompt_tokens == 0
      assert row.completion_tokens == 0
      assert row.cost_usd_cents == 0
    end

    # C-053: the production writer (Company.AuditLog.append/2) nests
    # token/cost under `detail`, NOT at the JSON top level. The replay
    # must read from `detail` or it sums zeros and the wipe-then-replay
    # rebuild silently resets current-month spend → budget hard-stops
    # undercounted after reindex/restore.
    test "C-053: sums token/cost from the production nested `detail` shape" do
      base = TmpGlorboHome.setup()
      seed_acme_budget(base)

      # Exact on-disk shape AuditLog.append/2 produces: core fields at
      # top level, everything else under `detail`.
      jsonl =
        ~s|{"kind":"audit-event/v1","ts":"2026-04-15T10:00:00Z","actor":"ceo","action":"budget.usage","target":null,"detail":{"company":"acme","agent":"ceo","prompt_tokens":120,"completion_tokens":40,"cost_usd_cents":7,"model":"qwen3:8b"}}\n| <>
          ~s|{"kind":"audit-event/v1","ts":"2026-04-20T10:00:00Z","actor":"ceo","action":"budget.usage","target":null,"detail":{"company":"acme","agent":"ceo","prompt_tokens":80,"completion_tokens":10,"cost_usd_cents":3}}\n|

      _ = write!(base, "companies/acme/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 1}} = Reindex.run(base: base)

      [row] = Repo.all(Budget)
      assert row.agent_slug == "ceo"
      assert row.prompt_tokens == 200
      assert row.completion_tokens == 50
      # The bug zeroed this; with the detail-aware read it must sum.
      assert row.cost_usd_cents == 10
    end

    # C-054: agent/company slugs legitimately allow underscores
    # (`[a-z][a-z0-9_-]{0,63}`). The reindex replay previously used the
    # hyphen-only Actions slug rule and silently dropped underscore
    # slugs from the rebuild, vanishing their spend after reindex.
    test "C-054: underscore agent + company slugs survive the replay" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme_inc/company.md", "---\nname: acme_inc\n---\n")

      jsonl =
        ~s|{"kind":"audit-event/v1","ts":"2026-04-15T10:00:00Z","actor":"data_bot","action":"budget.usage","target":null,"detail":{"company":"acme_inc","agent":"data_bot","prompt_tokens":150,"completion_tokens":50,"cost_usd_cents":9}}\n|

      _ = write!(base, "companies/acme_inc/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{budgets: 1}} = Reindex.run(base: base)

      [row] = Repo.all(Budget)
      assert row.company_slug == "acme_inc"
      assert row.agent_slug == "data_bot"
      assert row.cost_usd_cents == 9
    end

    # C-053 + C-054 together on the approval replay: underscore agent,
    # production nested `detail`, resolves to an approval row.
    test "C-053/C-054: approval replay reads nested detail for underscore agent" do
      base = TmpGlorboHome.setup()
      _ = write!(base, "companies/acme_inc/company.md", "---\nname: acme_inc\n---\n")

      jsonl =
        ~s|{"kind":"audit-event/v1","ts":"2026-04-26T10:00:00Z","actor":"data_bot","action":"approval.requested","target":"projects/x/tasks/x-01.md","detail":{"company":"acme_inc","agent":"data_bot","task_id":"x-01"}}\n|

      _ = write!(base, "companies/acme_inc/audit/2026-04.jsonl", jsonl)

      assert {:ok, %{tasks_approval_state: 1}} = Reindex.run(base: base)

      [row] = Repo.all(Glorbo.TasksApprovalState)
      assert row.company_slug == "acme_inc"
      assert row.agent_slug == "data_bot"
      assert row.status == "awaiting"
    end
  end

  describe "mark_dirty/2 + process_path/2 (Plan 04 B4)" do
    test "process_path/2 indexes a single file without a full run" do
      base = TmpGlorboHome.setup()

      path =
        write!(
          base,
          "companies/acme/company.md",
          "---\nname: acme\nmission: x\n---\n"
        )

      assert :indexed = Reindex.process_path("acme", path)
      [row] = Repo.all(Company)
      assert row.name == "acme"
    end

    test "mark_dirty/2 returns :ok and triggers incremental index" do
      base = TmpGlorboHome.setup()

      path =
        write!(
          base,
          "companies/acme/company.md",
          "---\nname: acme\n---\n"
        )

      assert :ok = Reindex.mark_dirty("acme", path)
      [row] = Repo.all(Company)
      assert row.name == "acme"

      # Second call on an unchanged file should still return :ok.
      assert :ok = Reindex.mark_dirty("acme", path)
    end

    test "process_path/2 skips a symlinked markdown leaf" do
      base = TmpGlorboHome.setup()
      external = write!(base, "outside/company.md", "---\nname: leak\n---\n")
      company_dir = Path.join(base, "companies/acme")
      File.mkdir_p!(company_dir)
      path = Path.join(company_dir, "company.md")
      File.ln_s!(external, path)

      assert {:skip, {:not_regular_file, :symlink}} = Reindex.process_path("acme", path)
      assert Repo.all(Company) == []
    end

    # Codex round-2 finding: a SYMLINKED ANCESTOR (not just the leaf)
    # must also be refused. Full-pass reindex's `safe_markdown_files/1`
    # already checks this — incremental `process_path/2` did NOT, so an
    # agent with `projects:write` could plant a symlinked directory and
    # have files reached through it indexed as if they belonged to the
    # company.
    test "process_path/2 skips a path whose ancestor directory is a symlink" do
      base = TmpGlorboHome.setup()
      external_dir = Path.join(base, "outside-project")
      File.mkdir_p!(external_dir)
      File.write!(Path.join(external_dir, "leak.md"), "---\nname: leak\n---\n")

      project_dir = Path.join([base, "companies/acme/projects/realproj"])
      File.mkdir_p!(project_dir)
      symlinked_subdir = Path.join(project_dir, "shortcut")
      File.ln_s!(external_dir, symlinked_subdir)

      # The leaf itself is a regular file, but `shortcut/` is a symlink.
      target_path = Path.join(symlinked_subdir, "leak.md")

      assert {:skip, :symlinked_ancestor} = Reindex.process_path("acme", target_path)
      assert Repo.all(Company) == []
    end
  end

  # GEP-0058: reindex rebuilds the semantic recall index LAZILY — only for
  # companies that opted in via `glorbo memory index --enable` (D6). The
  # embedder is injected through `:memory_index_opts` so no real
  # `/v1/embeddings` server is contacted.
  describe "GEP-0058 lazy memory-index rebuild" do
    alias Glorbo.Memory.{ChunkVector, Index}

    defp stub_mem_opts do
      embed_fun = fn _model, texts -> {:ok, Enum.map(texts, fn _ -> [1.0, 0.0] end)} end
      [memory_index_opts: [embed_fun: embed_fun, model: "stub"]]
    end

    test "a disabled company is NOT embedded (default OFF)" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      write!(base, "companies/acme/memory/notes.md", "the fox jumped over the lazy dog")

      assert {:ok, %{memory_chunks: 0}} = Reindex.run([base: base] ++ stub_mem_opts())
      assert Repo.all(ChunkVector) == []
    end

    test "an enabled company is embedded and its chunks become searchable" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      write!(base, "companies/acme/memory/notes.md", "the fox jumped over the lazy dog")

      # GEP-3: the opt-in is persisted to this base's company.md (the disk
      # source of truth reindex re-derives from), so pass `base:`.
      :ok = Index.enable("acme", base: base)

      assert {:ok, %{memory_chunks: n}} = Reindex.run([base: base] ++ stub_mem_opts())
      assert n >= 1

      vectors = Repo.all(ChunkVector)
      assert vectors != []
      assert Enum.all?(vectors, &(&1.company == "acme"))

      hits = Index.keyword_candidates("acme", "fox")
      assert Enum.any?(hits, &String.contains?(&1.content, "fox"))
    end

    test "only the enabled company is embedded, never its neighbour" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      seed_company(base, "globex")
      write!(base, "companies/acme/memory/a.md", "acme fox notes here")
      write!(base, "companies/globex/memory/b.md", "globex secret blueprint")

      # GEP-3: the opt-in is persisted to this base's company.md (the disk
      # source of truth reindex re-derives from), so pass `base:`.
      :ok = Index.enable("acme", base: base)

      assert {:ok, _} = Reindex.run([base: base] ++ stub_mem_opts())

      companies = Repo.all(ChunkVector) |> Enum.map(& &1.company) |> Enum.uniq()
      assert companies == ["acme"]
    end
  end
end
