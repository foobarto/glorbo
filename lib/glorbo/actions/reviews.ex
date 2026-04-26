defmodule Glorbo.Actions.Reviews do
  @moduledoc """
  Director-write actions for the GEP-42 reviewer auto-dispatcher.

  When `Glorbo.Approvals.Gate` first observes that a task needs
  peer review (per GEP-41), it calls
  `request_peer_review/4` here to drop a `peer-review-request/v1`
  sentinel into the configured reviewer's inbox. The reviewer's
  existing inotify wake pipeline picks the file up and runs
  the review; the verdict-side cleanup
  (`Glorbo.Actions.Tasks.record_peer_review_verdict/5` calling
  `clear_request_sentinel/3` + `write_revise_feedback/5`) closes
  the loop.

  ## Why this is its own module

  GEP-36 carved the Director-write surface into `Glorbo.Actions.*`
  so each write path is auditable, validated, and atomic. The
  Gate is an observer (parses task frontmatter, emits audits,
  manages dedupe state) — it's not an Actions module. Letting
  the Gate write the sentinel directly would cross the boundary
  GEP-36 just drew. This module is the seam.

  ## Why pointer-style sentinels

  The request sentinel carries `task_path`, not the prompt
  body. Two copies of the same content drift; one of them
  becomes wrong silently. See GEP-42 D1 for the full reasoning.

  ## Why missing reviewer fails loud

  GEP-42 D5: a reviewer that doesn't exist on disk is a stuck
  task with a `peer_review.skipped_no_reviewer` audit, not a
  silent skip. Auto-skipping is exfiltration-shaped — an attacker
  who deletes the reviewer's `agent.md` would silently bypass
  every review. Failing-loud-and-stuck is the conservative
  choice.
  """

  alias Glorbo.Actions.Support
  alias Glorbo.Company.AuditLog
  alias Glorbo.TaskDefinition

  @default_reviewer "critiqueops"

  @type opts :: [
          base: String.t(),
          audit: term(),
          now_fun: (-> DateTime.t())
        ]

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  @doc """
  Drop a peer-review wake sentinel into the reviewer's inbox.

  Resolves the reviewer slug from the task's `reviewer:` field,
  falling back to `#{@default_reviewer}` (matching GEP-41 D2).
  Refuses to write if the reviewer's `AGENT.md` doesn't exist or
  the reviewer's inbox isn't a writable regular directory —
  emits `peer_review.skipped_no_reviewer` and returns
  `{:error, :reviewer_absent | :inbox_unwritable}` so the gate
  can choose not to mark the dedupe set (next observation
  retries).

  ## Arguments

    * `company` — slug
    * `task_abs_path` — absolute path to the task file
    * `task` — parsed `Glorbo.TaskDefinition` struct (the gate
      already has it; passing avoids a re-parse)
    * `opts` — `:base` (default `~/.glorbo/`), `:audit` (default
      `AuditLog`), `:now_fun` (default `&DateTime.utc_now/0`)

  ## Audit

  Emits `peer_review.dispatched` on success or
  `peer_review.skipped_no_reviewer` on either pre-flight failure.
  """
  @spec request_peer_review(
          String.t(),
          Path.t(),
          TaskDefinition.t(),
          opts()
        ) ::
          {:ok, %{sentinel_path: Path.t(), reviewer: String.t()}}
          | {:error, :reviewer_absent | :inbox_unwritable | term()}
  def request_peer_review(company, task_abs_path, %TaskDefinition{} = task, opts \\ [])
      when is_binary(company) and is_binary(task_abs_path) do
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)
    now = Keyword.get(opts, :now_fun, &DateTime.utc_now/0).()

    reviewer = effective_reviewer(task)
    requesting_agent = task.assigned_to || "unassigned"
    severity = severity_for(task)

    with :ok <- Support.validate_slug(company, :company),
         :ok <- Support.validate_slug(reviewer, :agent),
         :ok <- ensure_reviewer_present(base, company, reviewer, audit, task, severity, now),
         {:ok, inbox_dir} <-
           ensure_reviewer_inbox(base, company, reviewer, audit, task, severity, now),
         sentinel_path = Path.join(inbox_dir, "peer-review-#{task.task_id}.md"),
         content = render_request_sentinel(task, reviewer, requesting_agent, severity, now),
         :ok <- atomic_write(sentinel_path, content),
         :ok <-
           emit_dispatched_audit(audit, company, task, reviewer, requesting_agent, severity) do
      {:ok, %{sentinel_path: sentinel_path, reviewer: reviewer}}
    end
  end

  @doc """
  Delete the peer-review request sentinel for `task_id` from
  `reviewer`'s inbox. Best-effort: a missing file is `:ok` (the
  sentinel may have been hand-cleaned, or the gate's MapSet
  already cleared on a prior verdict).
  """
  @spec clear_request_sentinel(String.t(), String.t(), String.t(), opts()) :: :ok
  def clear_request_sentinel(company, reviewer, task_id, opts \\ []) do
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)

    sentinel_path =
      Path.join([
        base,
        "companies",
        company,
        "agents",
        reviewer,
        "inbox",
        "peer-review-#{task_id}.md"
      ])

    case File.rm(sentinel_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Drop a `peer-review-feedback/v1` sentinel into the original
  assignee's inbox carrying the reviewer's revise note. Silently
  skipped if the assignee's inbox doesn't exist (the verdict
  frontmatter is the canonical state; the sentinel is a wake
  trigger, not source of truth).
  """
  @spec write_revise_feedback(
          String.t(),
          String.t(),
          TaskDefinition.t(),
          String.t(),
          opts()
        ) :: :ok
  def write_revise_feedback(company, assignee, %TaskDefinition{} = task, note, opts \\ [])
      when is_binary(company) and is_binary(assignee) and is_binary(note) do
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)
    now = Keyword.get(opts, :now_fun, &DateTime.utc_now/0).()

    inbox_dir =
      Path.join([base, "companies", company, "agents", assignee, "inbox"])

    if File.dir?(inbox_dir) do
      reviewer = effective_reviewer(task)
      sentinel_path = Path.join(inbox_dir, "peer-review-feedback-#{task.task_id}.md")
      content = render_feedback_sentinel(task, reviewer, note, now)

      case atomic_write(sentinel_path, content) do
        :ok ->
          emit_feedback_audit(audit, company, task, assignee, note)
          :ok

        {:error, _} ->
          :ok
      end
    else
      :ok
    end
  end

  # ----------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------

  defp effective_reviewer(%TaskDefinition{reviewer: reviewer})
       when is_binary(reviewer) and reviewer != "",
       do: reviewer

  defp effective_reviewer(_), do: @default_reviewer

  # The Gate only fires for tasks with `peer_review_required: true`,
  # which by GEP-41 §Trigger rules is severity-driven. Falling back
  # to "minor" when severity is unset keeps the audit + sentinel
  # frontmatter honest if a task had the flag set without a
  # severity (manual opt-in path).
  defp severity_for(%TaskDefinition{severity: :info}), do: "info"
  defp severity_for(%TaskDefinition{severity: :minor}), do: "minor"
  defp severity_for(%TaskDefinition{severity: :major}), do: "major"
  defp severity_for(%TaskDefinition{severity: :critical}), do: "critical"
  defp severity_for(_), do: "minor"

  defp ensure_reviewer_present(base, company, reviewer, audit, task, severity, _now) do
    agent_md = Path.join([base, "companies", company, "agents", reviewer, "AGENT.md"])

    if File.regular?(agent_md) do
      :ok
    else
      emit_skipped_audit(audit, company, task, reviewer, severity, :reviewer_absent)
      {:error, :reviewer_absent}
    end
  end

  defp ensure_reviewer_inbox(base, company, reviewer, audit, task, severity, _now) do
    inbox = Path.join([base, "companies", company, "agents", reviewer, "inbox"])

    case File.lstat(inbox) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, inbox}

      _ ->
        emit_skipped_audit(audit, company, task, reviewer, severity, :inbox_unwritable)
        {:error, :inbox_unwritable}
    end
  end

  defp render_request_sentinel(task, reviewer, requesting_agent, severity, now) do
    """
    ---
    kind: peer-review-request/v1
    task_path: #{task_rel_path(task)}
    task_id: #{task.task_id}
    requesting_agent: #{requesting_agent}
    severity: #{severity}
    requested_at: #{DateTime.to_iso8601(now)}
    reviewer: #{reviewer}
    ---

    # Peer review: #{task.title || task.task_id}

    You're being asked to review this task before Director approval.

    Read the original task at `#{task_rel_path(task)}` (relative to
    the company root) and produce a verdict using the standard
    reviewer reply contract:

        VERDICT: approve | revise | block
        NOTE: <free text — required for revise / block>

    Your verdict file lands in your outbox; the Router routes it
    through `Glorbo.Actions.Tasks.record_peer_review_verdict/5`
    and the sentinel here gets cleared.
    """
  end

  defp render_feedback_sentinel(task, reviewer, note, now) do
    """
    ---
    kind: peer-review-feedback/v1
    task_path: #{task_rel_path(task)}
    task_id: #{task.task_id}
    reviewer: #{reviewer}
    verdict: revise
    delivered_at: #{DateTime.to_iso8601(now)}
    note: |
    #{indent_block(note, "  ")}
    ---

    # Peer-review feedback for #{task.task_id}

    Your task got a `revise` verdict from #{reviewer}. See the
    `note` field above for the reviewer's justification. Address
    the feedback and re-submit (status flip back to
    `pending-approval` triggers re-review automatically).
    """
  end

  defp indent_block(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

  # Project-relative path stored in frontmatter — resolves the
  # canonical `projects/<p>/tasks/<id>.md` shape from a parsed
  # TaskDefinition without re-deriving it from the absolute path.
  defp task_rel_path(%TaskDefinition{project: project, task_id: id})
       when is_binary(project) and is_binary(id) do
    "projects/#{project}/tasks/#{id}.md"
  end

  defp atomic_write(path, content) do
    # Wave 28: sentinel writes land in `agents/<reviewer>/inbox/`,
    # which the reviewer agent has RW on. A predictable
    # `<sentinel>.tmp.<monotonic-int>` was attacker-plantable as a
    # symlink. Random-suffix + O_EXCL closes the TOCTOU.
    rand = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp = "#{path}.tmp-#{rand}"

    case :file.open(tmp, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} ->
        result = :file.write(fd, content)
        :file.close(fd)

        case result do
          :ok ->
            case File.rename(tmp, path) do
              :ok ->
                :ok

              {:error, _} = err ->
                _ = File.rm(tmp)
                err
            end

          {:error, _} = err ->
            _ = File.rm(tmp)
            err
        end

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------
  # Audit emission
  # ----------------------------------------------------------------

  defp emit_dispatched_audit(audit, company, task, reviewer, requesting_agent, severity) do
    entry = %{
      action: "peer_review.dispatched",
      actor: "system",
      target: task_rel_path(task),
      company: company,
      detail: %{
        "reviewer" => reviewer,
        "requesting_agent" => requesting_agent,
        "severity" => severity,
        "task_id" => task.task_id
      }
    }

    Support.append_audit(audit, company, entry)
  end

  defp emit_skipped_audit(audit, company, task, reviewer, severity, reason) do
    entry = %{
      action: "peer_review.skipped_no_reviewer",
      actor: "system",
      target: task_rel_path(task),
      company: company,
      detail: %{
        "reviewer_slug" => reviewer,
        "task_id" => task.task_id,
        "severity" => severity,
        "reason" => Atom.to_string(reason)
      }
    }

    Support.append_audit(audit, company, entry)
  end

  defp emit_feedback_audit(audit, company, task, to_agent, note) do
    entry = %{
      action: "peer_review.feedback_sent",
      actor: "system",
      target: task_rel_path(task),
      company: company,
      detail: %{
        "to_agent" => to_agent,
        "task_id" => task.task_id,
        "note_bytes" => byte_size(note)
      }
    }

    Support.append_audit(audit, company, entry)
  end
end
