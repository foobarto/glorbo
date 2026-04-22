defmodule Glorbo.Company.ProposalsSinkTest do
  use ExUnit.Case, async: false

  alias Glorbo.Company.ProposalsSink

  # Dep-inject a capturing audit_fun + read_fun so the test never
  # touches the real AuditLog / disk. `test_pid:` sends a mirror
  # of every emission to the test for assert_receive.
  defp start_sink!(opts \\ []) do
    name = Glorbo.Test.UniqueName.gen("proposals_sink")
    company = Keyword.get(opts, :company, "acme-#{System.unique_integer([:positive])}")

    base =
      Path.join(System.tmp_dir!(), "glorbo-proposals-sink-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([base, "companies", company, "proposals"]))
    on_exit(fn -> File.rm_rf!(base) end)

    # Ensure :glorbo is up so Glorbo.PubSub is alive.
    Application.ensure_all_started(:glorbo)

    test_pid = self()
    audit_fun = fn co, entry -> send(test_pid, {:audit, co, entry}) end

    pid =
      start_supervised!(
        {ProposalsSink,
         Keyword.merge(
           [
             name: name,
             company: company,
             base: base,
             audit_fun: audit_fun,
             test_pid: test_pid
           ],
           Keyword.drop(opts, [:company])
         )}
      )

    # Wait for the :subscribe continuation to complete so the
    # broadcast below is guaranteed to reach the GenServer.
    :sys.get_state(pid)

    %{pid: pid, company: company, base: base}
  end

  defp write_proposal!(base, company, filename, content) do
    path = Path.join([base, "companies", company, "proposals", filename])
    File.write!(path, content)
    path
  end

  defp broadcast_event(company, rel) do
    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:#{company}:proposals",
      {:file_event, rel, [:created]}
    )
  end

  # ---------------------------------------------------------------------------
  # T1 — pending-approval emits proposal.requested with actor from proposed_by
  # ---------------------------------------------------------------------------

  test "T1: pending-approval write emits proposal.requested with actor=proposed_by" do
    %{base: base, company: company} = start_sink!()

    content = """
    ---
    kind: proposal/v1
    id: hire-writer-2026-04-21
    subtype: hire
    status: pending-approval
    proposed_by: ceo
    requires_approval: director
    proposed_at: 2026-04-21T10:00:00Z
    ---

    # Rationale
    Need a writer.
    """

    rel = "proposals/hire-writer-2026-04-21.md"
    write_proposal!(base, company, "hire-writer-2026-04-21.md", content)
    broadcast_event(company, rel)

    assert_receive {:audit, ^company, entry}, 1_000
    # Threatmodel T12: sink is an observer, not an oracle. The audit
    # action signals "this status was seen in the file", not "this
    # status was authorised". Actor is the sentinel; the claimed
    # proposed_by value is preserved in `detail` for investigators.
    assert entry.action == "proposal.file_pending"
    assert entry.actor == "proposal-file"
    assert entry.detail.claimed_proposed_by == "ceo"
    assert entry.target == rel
    assert entry.detail.subtype == "hire"
    assert entry.detail.id == "hire-writer-2026-04-21"
    assert entry.company == company
  end

  # ---------------------------------------------------------------------------
  # T2 — approved emits observer entry with claimed approver in detail
  # ---------------------------------------------------------------------------

  test "T2: approved write emits proposal.file_approved with claimed_approved_by in detail (T12)" do
    %{base: base, company: company} = start_sink!()

    content = """
    ---
    kind: proposal/v1
    id: increase-ceo-budget
    subtype: budget
    status: approved
    proposed_by: ceo
    requires_approval: director
    proposed_at: 2026-04-21T10:00:00Z
    approved_by: director
    approved_at: 2026-04-21T11:00:00Z
    ---

    # Rationale
    Budget hit.
    """

    rel = "proposals/increase-ceo-budget.md"
    write_proposal!(base, company, "increase-ceo-budget.md", content)
    broadcast_event(company, rel)

    assert_receive {:audit, ^company, entry}, 1_000
    assert entry.action == "proposal.file_approved"
    assert entry.actor == "proposal-file"
    # The original "approved_by: director" claim is preserved in
    # detail so investigators can still see what the file said — we
    # just don't let it become the audit record's authoritative actor.
    assert entry.detail.claimed_approved_by == "director"
    assert entry.target == rel
    assert entry.detail.subtype == "budget"
    assert entry.detail.id == "increase-ceo-budget"
  end

  # Threatmodel T12: a malicious agent with `proposals:write:*` (not
  # `proposals:propose:*`) can write directly to proposals/*.md,
  # setting `approved_by: director` + `status: approved` to forge a
  # director-signed approval. The sink must NOT lift those claims into
  # the audit record's `actor` field.
  test "T12: forged approved_by claim does not pollute audit actor" do
    %{base: base, company: company} = start_sink!()

    content = """
    ---
    kind: proposal/v1
    id: evil-forge
    subtype: hire
    status: approved
    proposed_by: ceo
    approved_by: director
    approved_at: 2026-04-22T00:00:00Z
    ---
    body
    """

    rel = "proposals/evil-forge.md"
    write_proposal!(base, company, "evil-forge.md", content)
    broadcast_event(company, rel)

    assert_receive {:audit, ^company, entry}, 1_000
    # The actor field must not be "director" — the sink is not an
    # authorization oracle.
    refute entry.actor == "director"
    assert entry.actor == "proposal-file"
    # And the claimed approver is preserved verbatim in detail.
    assert entry.detail.claimed_approved_by == "director"
  end

  # ---------------------------------------------------------------------------
  # T3 — malformed frontmatter does not crash the sink
  # ---------------------------------------------------------------------------

  test "T3: malformed frontmatter file does NOT crash the sink; later events still process" do
    %{pid: pid, base: base, company: company} = start_sink!()

    # First event: malformed YAML inside the frontmatter fence —
    # unbalanced brackets guarantee yamerl rejects it. The sink should
    # log and skip without crashing.
    bad_content = """
    ---
    kind: proposal/v1
    id: bad
    subtype: [unterminated
    status: pending-approval
    proposed_by: ceo
    ---

    body
    """

    write_proposal!(base, company, "bad.md", bad_content)
    broadcast_event(company, "proposals/bad.md")

    # Give the sink a moment to process and (not) crash.
    refute_receive {:audit, ^company, _}, 200
    assert Process.alive?(pid)

    # Second event with a well-formed file still emits.
    good = """
    ---
    kind: proposal/v1
    id: good
    subtype: hire
    status: pending-approval
    proposed_by: ceo
    requires_approval: director
    proposed_at: 2026-04-21T10:00:00Z
    ---

    body
    """

    write_proposal!(base, company, "good.md", good)
    broadcast_event(company, "proposals/good.md")

    assert_receive {:audit, ^company, entry}, 1_000
    assert entry.action == "proposal.file_pending"
    assert entry.detail.id == "good"
    assert Process.alive?(pid)
  end
end
