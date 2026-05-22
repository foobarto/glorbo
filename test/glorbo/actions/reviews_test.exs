defmodule Glorbo.Actions.ReviewsTest do
  @moduledoc """
  GEP-42 — `Glorbo.Actions.Reviews` covers:

    * `request_peer_review/4` writes the canonical sentinel into
      the reviewer's inbox; emits `peer_review.dispatched` audit.
    * Pre-flight refuses + emits `peer_review.skipped_no_reviewer`
      when the reviewer's `AGENT.md` is absent (D5: stuck task,
      no silent skip).
    * Pre-flight refuses when the reviewer's inbox is missing or
      a symlink (atomic-write safety).
    * Atomic write — no leftover `.tmp.*` on success.
    * Idempotency — second call with the same task_id overwrites
      in place; no inbox accumulation.
    * `clear_request_sentinel/3` is a no-op when the file is
      missing.
    * `write_revise_feedback/5` lands the feedback sentinel in
      the assignee's inbox + emits `peer_review.feedback_sent`.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Actions.Reviews
  alias Glorbo.TaskDefinition

  defmodule FakeAudit do
    use GenServer
    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
    def calls(pid), do: GenServer.call(pid, :calls)

    @impl true
    def init(_opts), do: {:ok, []}

    @impl true
    def handle_call({:append, entry}, _from, state),
      do: {:reply, :ok, [entry | state]}

    def handle_call(:calls, _from, state),
      do: {:reply, Enum.reverse(state), state}
  end

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-reviews-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, audit} = start_supervised(FakeAudit)
    {:ok, base: base, audit: audit}
  end

  defp seed_company_with_reviewer(base, company, reviewer) do
    co_root = Path.join([base, "companies", company])
    reviewer_dir = Path.join([co_root, "agents", reviewer])
    File.mkdir_p!(Path.join(reviewer_dir, "inbox"))

    File.write!(Path.join(reviewer_dir, "AGENT.md"), """
    ---
    kind: agent/v1
    slug: #{reviewer}
    role: Peer reviewer
    provider: claude-code
    model: claude-sonnet-4-5
    network: loopback
    permissions: []
    ---
    """)

    co_root
  end

  defp seed_assignee_inbox(base, company, slug) do
    inbox = Path.join([base, "companies", company, "agents", slug, "inbox"])
    File.mkdir_p!(inbox)
    inbox
  end

  defp make_task(opts \\ []) do
    %TaskDefinition{
      task_id: opts[:task_id] || "demo-1",
      project: opts[:project] || "demo",
      title: opts[:title] || "demo task",
      status: opts[:status] || "pending-approval",
      assigned_to: opts[:assigned_to] || "engineer",
      severity: opts[:severity] || :major,
      peer_review_required: true,
      reviewer: opts[:reviewer]
    }
  end

  describe "request_peer_review/4" do
    test "writes sentinel + emits dispatched audit (happy path)",
         %{base: base, audit: audit} do
      seed_company_with_reviewer(base, "acme", "critiqueops")
      task = make_task(task_id: "release-01", project: "release")
      abs = Path.join([base, "companies/acme/projects/release/tasks/release-01.md"])

      assert {:ok, %{sentinel_path: path, reviewer: "critiqueops"}} =
               Reviews.request_peer_review("acme", abs, task, base: base, audit: audit)

      assert path ==
               Path.join([
                 base,
                 "companies/acme/agents/critiqueops/inbox/peer-review-release-01.md"
               ])

      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "kind: peer-review-request/v1"
      assert content =~ "task_path: projects/release/tasks/release-01.md"
      assert content =~ "task_id: release-01"
      assert content =~ "requesting_agent: engineer"
      assert content =~ "severity: major"
      assert content =~ "reviewer: critiqueops"

      [event] = FakeAudit.calls(audit)
      assert event.action == "peer_review.dispatched"
      assert event.detail["reviewer"] == "critiqueops"
      assert event.detail["task_id"] == "release-01"
      assert event.detail["severity"] == "major"
    end

    test "honours per-task `reviewer:` override",
         %{base: base, audit: audit} do
      seed_company_with_reviewer(base, "acme", "provenance-auditor")
      task = make_task(reviewer: "provenance-auditor")
      abs = Path.join([base, "companies/acme/projects/demo/tasks/demo-1.md"])

      assert {:ok, %{reviewer: "provenance-auditor"}} =
               Reviews.request_peer_review("acme", abs, task, base: base, audit: audit)
    end

    test "refuses + emits skipped audit when reviewer AGENT.md missing (D5)",
         %{base: base, audit: audit} do
      # Seed the company but NOT the reviewer.
      File.mkdir_p!(Path.join([base, "companies/acme"]))
      task = make_task()
      abs = Path.join([base, "companies/acme/projects/demo/tasks/demo-1.md"])

      assert {:error, :reviewer_absent} =
               Reviews.request_peer_review("acme", abs, task, base: base, audit: audit)

      [event] = FakeAudit.calls(audit)
      assert event.action == "peer_review.skipped_no_reviewer"
      assert event.detail["reviewer_slug"] == "critiqueops"
      assert event.detail["reason"] == "reviewer_absent"

      # Sentinel was NOT written.
      sentinel =
        Path.join([base, "companies/acme/agents/critiqueops/inbox/peer-review-demo-1.md"])

      refute File.exists?(sentinel)
    end

    test "refuses when reviewer inbox is a symlink (atomic-write safety)",
         %{base: base, audit: audit} do
      seed_company_with_reviewer(base, "acme", "critiqueops")
      inbox = Path.join([base, "companies/acme/agents/critiqueops/inbox"])
      # Replace the inbox dir with a symlink to /tmp.
      File.rm_rf!(inbox)
      File.ln_s!("/tmp", inbox)

      task = make_task()
      abs = Path.join([base, "companies/acme/projects/demo/tasks/demo-1.md"])

      assert {:error, :inbox_unwritable} =
               Reviews.request_peer_review("acme", abs, task, base: base, audit: audit)

      [event] = FakeAudit.calls(audit)
      assert event.action == "peer_review.skipped_no_reviewer"
      assert event.detail["reason"] == "inbox_unwritable"
    end

    test "atomic write leaves no .tmp.* on success",
         %{base: base, audit: audit} do
      seed_company_with_reviewer(base, "acme", "critiqueops")
      task = make_task()
      abs = Path.join([base, "companies/acme/projects/demo/tasks/demo-1.md"])

      assert {:ok, _} =
               Reviews.request_peer_review("acme", abs, task, base: base, audit: audit)

      tmps =
        Path.wildcard(Path.join([base, "companies/acme/agents/critiqueops/inbox/*.tmp.*"]))

      assert tmps == []
    end

    test "second call overwrites in place (idempotency)",
         %{base: base, audit: audit} do
      seed_company_with_reviewer(base, "acme", "critiqueops")
      task = make_task()
      abs = Path.join([base, "companies/acme/projects/demo/tasks/demo-1.md"])

      assert {:ok, %{sentinel_path: path1}} =
               Reviews.request_peer_review("acme", abs, task, base: base, audit: audit)

      assert {:ok, %{sentinel_path: path2}} =
               Reviews.request_peer_review("acme", abs, task, base: base, audit: audit)

      assert path1 == path2

      # Inbox has exactly one sentinel for this task — overwrite,
      # not append.
      files =
        Path.wildcard(
          Path.join([
            base,
            "companies/acme/agents/critiqueops/inbox/peer-review-demo-1.md"
          ])
        )

      assert length(files) == 1
    end
  end

  describe "clear_request_sentinel/4" do
    test "deletes the sentinel when present", %{base: base} do
      reviewer = "critiqueops"
      task_id = "demo-1"

      sentinel =
        Path.join([base, "companies/acme/agents/#{reviewer}/inbox/peer-review-#{task_id}.md"])

      File.mkdir_p!(Path.dirname(sentinel))
      File.write!(sentinel, "stub")

      assert :ok = Reviews.clear_request_sentinel("acme", reviewer, task_id, base: base)
      refute File.exists?(sentinel)
    end

    test "is a no-op when the sentinel is missing", %{base: base} do
      assert :ok =
               Reviews.clear_request_sentinel("acme", "critiqueops", "missing-task-99",
                 base: base
               )
    end
  end

  describe "write_revise_feedback/5" do
    test "lands the feedback sentinel in the assignee's inbox + emits audit",
         %{base: base, audit: audit} do
      seed_assignee_inbox(base, "acme", "engineer")
      task = make_task(task_id: "demo-1", project: "demo")

      assert :ok =
               Reviews.write_revise_feedback("acme", "engineer", task, "Citation 3 is dead.",
                 base: base,
                 audit: audit
               )

      sentinel =
        Path.join([base, "companies/acme/agents/engineer/inbox/peer-review-feedback-demo-1.md"])

      assert File.exists?(sentinel)
      content = File.read!(sentinel)
      assert content =~ "kind: peer-review-feedback/v1"
      assert content =~ "verdict: revise"
      assert content =~ "Citation 3 is dead."
      assert content =~ "reviewer: critiqueops"

      [event] = FakeAudit.calls(audit)
      assert event.action == "peer_review.feedback_sent"
      assert event.detail["to_agent"] == "engineer"
    end

    test "is a no-op when the assignee inbox doesn't exist",
         %{base: base, audit: audit} do
      task = make_task()

      assert :ok =
               Reviews.write_revise_feedback("acme", "ghost", task, "n/a",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    # B-008: `assignee` is attacker-controlled (it's the task's
    # `assigned_to` frontmatter). A traversal value must NOT write a
    # sentinel outside the company tree, and the path must be rejected
    # before any write — no audit, no file.
    test "rejects a traversal assignee and writes nothing outside the company",
         %{base: base, audit: audit} do
      # Stand up a sibling company with a victim agent inbox.
      victim_inbox =
        Path.join([base, "companies", "other-co", "agents", "victim", "inbox"])

      File.mkdir_p!(victim_inbox)

      task = make_task(task_id: "demo-1", project: "demo")

      assert :ok =
               Reviews.write_revise_feedback(
                 "acme",
                 "../../other-co/agents/victim",
                 task,
                 "pwned",
                 base: base,
                 audit: audit
               )

      # No sentinel landed in the victim's inbox.
      refute File.exists?(Path.join(victim_inbox, "peer-review-feedback-demo-1.md"))
      # And the path was rejected before any audit fired.
      assert FakeAudit.calls(audit) == []
    end

    # B-008: a symlinked inbox ancestor (e.g. the agent dir is a
    # symlink to another company) must NOT be followed — `File.lstat`
    # gating + `any_symlink_in_path?` reject it.
    test "refuses a symlinked inbox ancestor", %{base: base, audit: audit} do
      # Real inbox lives in the sibling company.
      real_inbox =
        Path.join([base, "companies", "other-co", "agents", "victim", "inbox"])

      File.mkdir_p!(real_inbox)

      # Plant a symlink: acme/agents/decoy -> other-co/agents/victim
      acme_agents = Path.join([base, "companies", "acme", "agents"])
      File.mkdir_p!(acme_agents)
      decoy = Path.join(acme_agents, "decoy")

      File.ln_s(
        Path.join([base, "companies", "other-co", "agents", "victim"]),
        decoy
      )

      task = make_task(task_id: "demo-1", project: "demo")

      assert :ok =
               Reviews.write_revise_feedback("acme", "decoy", task, "pwned",
                 base: base,
                 audit: audit
               )

      refute File.exists?(Path.join(real_inbox, "peer-review-feedback-demo-1.md"))
      assert FakeAudit.calls(audit) == []
    end

    # B-008: a malformed task_id must not become a path component.
    test "rejects a non-slug task_id before building the sentinel filename",
         %{base: base, audit: audit} do
      seed_assignee_inbox(base, "acme", "engineer")
      task = make_task(task_id: "../../escape", project: "demo")

      assert :ok =
               Reviews.write_revise_feedback("acme", "engineer", task, "note",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end
end
