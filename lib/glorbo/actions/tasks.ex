defmodule Glorbo.Actions.Tasks do
  @moduledoc """
  Task mutation operations (GEP-36). Every function performs the
  permission check + input validation + atomic filesystem write +
  audit-emit sequence. Callers (LiveView, MCP, shell) invoke these
  directly — no raw `File.*!` writes in frontend handlers.

  Current public API:

    * `create/4` — new task file in `projects/<p>/tasks/<id>.md`.
      Called by `KanbanLive.handle_event("new_task_create", ...)`
      and MCP's `create_task` tool.

  Planned next (not yet implemented):

    * `move/4` — status/column flip.
    * `update_status/4` — any status change.
    * `assign/4` — `assigned_to:` flip + `handoff_chain:` append
      (GEP-40 consumer).
    * `dispatch/3` — wake agent + record dispatch.
    * `request_peer_review/3` + `resolve_peer_review/4` (GEP-41).

  ## Contract

  Every function:

    * Returns `{:ok, result}` or `{:error, reason}`. No raised
      exceptions on expected failure paths.
    * Takes `opts :: keyword()` with mandatory `:actor` key.
      Missing `:actor` raises `ArgumentError` at the boundary.
    * Emits a `Glorbo.Company.AuditLog` entry before returning
      on success. Audit-emit failures surface as
      `{:error, :audit_failed}`.
  """

  alias Glorbo.Actions.Support
  alias Glorbo.Company.AuditLog
  alias Glorbo.Filesystem.FrontmatterWriter
  alias Glorbo.HomeHistory
  alias Glorbo.HomeHistory.Tx

  @title_max_bytes 200
  @task_id_re ~r/\A[a-z0-9][a-z0-9-]*\z/

  @type create_params :: %{
          optional(String.t()) => any()
        }

  @type create_opts ::
          [
            actor: String.t(),
            base: Path.t(),
            audit: atom(),
            attachments: [String.t()],
            task_id: String.t()
          ]

  @type create_result :: %{task_id: String.t(), rel_path: String.t(), abs_path: String.t()}

  @type trash_opts ::
          [
            actor: String.t(),
            base: Path.t(),
            audit: atom()
          ]

  @type trash_result :: %{dest_rel_path: String.t()}

  @type archive_opts ::
          [
            actor: String.t(),
            base: Path.t(),
            audit: atom()
          ]

  @type archive_result :: %{
          dest_rel_path: String.t(),
          attachments_moved: boolean()
        }

  @type reassign_opts ::
          [
            actor: String.t(),
            reason: String.t(),
            base: Path.t(),
            audit: atom()
          ]

  @type reassign_result :: %{
          from: String.t(),
          to: String.t(),
          handoff_chain_len: non_neg_integer()
        }

  @type verdict :: :approve | :revise | :block
  @type verdict_opts ::
          [
            actor: String.t(),
            note: String.t(),
            base: Path.t(),
            audit: atom()
          ]

  @type verdict_result :: %{verdict: verdict(), next_status: String.t()}

  @doc """
  Create a new task file under `projects/<project>/tasks/<task_id>.md`.

  `params` carries the task's frontmatter + body fields as string
  keys. Minimum: `"title"`. Optional: `"assigned_to"`,
  `"requested_by"`, `"priority"`, `"severity"`,
  `"peer_review_required"`, `"reviewer"`, `"model"`, `"provider"`,
  `"done_when"`, `"description"`, `"schedule"`.

  `opts`:

    * `:actor` (required) — who is creating the task (director /
      ceo / etc.). Surfaced in the audit entry.
    * `:base` — filesystem root (default `Glorbo.Path.base_dir/0`).
    * `:audit` — AuditLog target (default global).
    * `:attachments` — list of relative attachment paths to link
      from the body.

  ## Validations

  Company + project slugs must match `~r/\\A[a-z0-9][a-z0-9-]*\\z/`.
  Title is trimmed; must be 1..200 bytes. Next task ID is derived
  from existing filenames in the project's tasks dir
  (`<project>-NN.md`, legacy `t-NN.md` counted too).

  ## Audit

  Emits `task.create` with:

    * `actor` — from `opts[:actor]`.
    * `target` — `projects/<project>/tasks/<task_id>.md`.
    * `detail: %{"title" => title, "assigned_to" => ...}`.
  """
  @spec create(String.t(), String.t(), create_params(), create_opts()) ::
          {:ok, create_result()} | {:error, term()}
  def create(company, project, params, opts \\ [])
      when is_binary(company) and is_binary(project) and is_map(params) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)
    attachments = Keyword.get(opts, :attachments, [])
    # GEP-41 D1: major / critical tasks default to peer-review-required
    # unless the caller explicitly opted out. See `apply_severity_auto_flip/1`.
    params = apply_severity_auto_flip(params)

    history_meta = %{
      actor: HomeHistory.actor_from_string(actor),
      action: "task.create",
      target: "companies/#{company}/projects/#{project}/tasks"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        with :ok <- Support.validate_slug(company, :company),
             :ok <- Support.validate_slug(project, :project),
             title <- params |> Map.get("title", "") |> to_string() |> String.trim(),
             :ok <- validate_title(title),
             {:ok, task_id} <- resolve_task_id(opts, base, company, project),
             :ok <- write_task_file(base, company, project, task_id, params, attachments),
             rel_path = "projects/#{project}/tasks/#{task_id}.md",
             abs_path = Path.join([base, "companies", company, rel_path]),
             :ok <- Tx.mark_path(tx_id, abs_path),
             :ok <- emit_create_audit(audit, company, rel_path, title, actor, params),
             :ok <- Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(base, company)) do
          {:ok, %{task_id: task_id, rel_path: rel_path, abs_path: abs_path}}
        end
      end)

    case history_result do
      {:ok, result, _tx_id} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  # GEP-41 D1: if severity is major or critical and the caller did NOT
  # explicitly supply peer_review_required, flip it to true. Explicit
  # false from the caller wins — respect the opt-out.
  defp apply_severity_auto_flip(params) do
    severity = params |> Map.get("severity") |> to_string() |> String.downcase()
    explicit = Map.get(params, "peer_review_required")

    cond do
      severity not in ["major", "critical"] ->
        params

      # C-062: only a genuine boolean-false opt-out is honoured. The
      # string `"true"` previously counted as an "explicit value" and
      # returned params unchanged — but it round-trips through YAML as
      # a quoted string and `coerce_peer_review_required/1` coerces any
      # non-boolean to `false`, silently defeating the major/critical
      # auto-flip (GEP-41 D1). Force boolean `true` whenever the caller
      # did not supply an explicit boolean-false (or its `"false"`
      # string form), normalising any other value to the safe-on
      # default for high-severity tasks.
      explicit in [false, "false"] ->
        Map.put(params, "peer_review_required", false)

      true ->
        Map.put(params, "peer_review_required", true)
    end
  end

  @doc """
  Compute the next free task id in a project. Exposed so callers
  that need to place artifacts (upload dirs, etc.) under the
  task-id path BEFORE calling `create/4` can pre-reserve the id
  and pass it via `opts[:task_id]`.

  No filesystem mutation beyond `mkdir_p` on the tasks dir.
  """
  @spec next_task_id(Path.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def next_task_id(base, company, project)
      when is_binary(base) and is_binary(company) and is_binary(project) do
    with :ok <- Support.validate_slug(company, :company),
         :ok <- Support.validate_slug(project, :project) do
      do_next_task_id(base, company, project)
    end
  end

  @doc """
  Move a task file to `projects/<project>/history/deleted/` — a
  soft-delete, not a true unlink (recoverable by moving back).

  `task_rel_path` is relative to `companies/<company>/`, e.g.
  `projects/demo/tasks/demo-07.md`.

  `opts`:

    * `:actor` (required) — who deleted the task.
    * `:base` — filesystem root (default `~/.glorbo`).
    * `:audit` — AuditLog target (default global).

  ## Audit

  Emits `task.trash` with `target: <original rel_path>` and detail
  `dest: <history/deleted/... rel_path>`.
  """
  @spec trash(String.t(), String.t(), trash_opts()) ::
          {:ok, trash_result()} | {:error, term()}
  def trash(company, task_rel_path, opts \\ [])
      when is_binary(company) and is_binary(task_rel_path) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    history_meta = %{
      actor: HomeHistory.actor_from_string(actor),
      action: "task.trash",
      target: "companies/#{company}/#{task_rel_path}"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        with :ok <- Support.validate_slug(company, :company),
             {:ok, project} <- project_of(task_rel_path),
             abs_src = Path.join([base, "companies", company, task_rel_path]),
             :ok <- ensure_regular_file(abs_src),
             {:ok, dest_rel, abs_dest} <- build_trash_dest(base, company, project, abs_src),
             :ok <- File.rename(abs_src, abs_dest),
             :ok <- Tx.mark_path(tx_id, abs_src),
             :ok <- Tx.mark_path(tx_id, abs_dest),
             :ok <- emit_trash_audit(audit, company, task_rel_path, dest_rel, actor),
             :ok <- Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(base, company)) do
          {:ok, %{dest_rel_path: dest_rel}}
        end
      end)

    case history_result do
      {:ok, result, _tx_id} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  @doc """
  Archive a task into `projects/<p>/history/tasks/<id>.md`,
  preserving its id and filename. Also moves its attachments dir
  from `projects/<p>/attachments/<id>/` to
  `projects/<p>/history/attachments/<id>/` if one exists.

  Distinct from `trash/3` — trash is soft-delete with timestamped
  destination; archive is treated as completion and keeps the
  canonical filename so links still work for historical readers.

  Enforces **threatmodel M18**: refuses to proceed if any segment
  on the `history/` path is a symlink (which `File.mkdir_p` +
  `File.rename` would follow and could redirect into another
  company's tree).

  `task_rel_path` is relative to `companies/<company>/`, e.g.
  `projects/demo/tasks/demo-07.md`.

  ## Audit

  Emits `task.delete` (pre-migration KanbanLive label preserved).
  Contains `target`, `dest`, and `attachments_moved: "true"/"false"`.
  """
  @spec archive_to_history(String.t(), String.t(), archive_opts()) ::
          {:ok, archive_result()} | {:error, term()}
  def archive_to_history(company, task_rel_path, opts \\ [])
      when is_binary(company) and is_binary(task_rel_path) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    history_meta = %{
      actor: HomeHistory.actor_from_string(actor),
      action: "task.archive",
      target: "companies/#{company}/#{task_rel_path}"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        with :ok <- Support.validate_slug(company, :company),
             {:ok, project} <- project_of(task_rel_path),
             abs_src = Path.join([base, "companies", company, task_rel_path]),
             :ok <- ensure_regular_file(abs_src),
             {:ok, filename, task_id} <- parse_task_filename(task_rel_path),
             history_dir =
               Path.join([base, "companies", company, "projects", project, "history", "tasks"]),
             :ok <- ensure_no_symlink_directory(history_dir),
             :ok <- File.mkdir_p(history_dir),
             history_md = Path.join(history_dir, filename),
             :ok <- ensure_regular_file_or_absent(history_md),
             :ok <- File.rename(abs_src, history_md) do
          attachments_moved =
            maybe_move_attachments(base, company, project, task_id)

          dest_rel = "projects/#{project}/history/tasks/#{filename}"

          :ok = Tx.mark_path(tx_id, abs_src)
          :ok = Tx.mark_path(tx_id, history_md)

          :ok =
            emit_archive_audit(
              audit,
              company,
              task_rel_path,
              dest_rel,
              attachments_moved,
              actor
            )

          :ok = Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(base, company))

          {:ok, %{dest_rel_path: dest_rel, attachments_moved: attachments_moved}}
        end
      end)

    case history_result do
      {:ok, result, _tx_id} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  defp parse_task_filename(rel_path) do
    case Path.split(rel_path) do
      ["projects", _project, "tasks", filename] ->
        {:ok, filename, String.replace_suffix(filename, ".md", "")}

      _ ->
        {:error, {:invalid_task_rel_path, rel_path}}
    end
  end

  # threatmodel M18: refuse to recurse into symlinked directories.
  defp ensure_no_symlink_directory(dir) do
    Enum.reduce_while(Path.split(dir), "", fn seg, acc ->
      next = if acc == "", do: seg, else: Path.join(acc, seg)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, next}
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink_in_path}}
        {:ok, %File.Stat{}} -> {:halt, {:error, :not_a_directory}}
        {:error, :enoent} -> {:halt, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _} = err -> err
      path when is_binary(path) -> :ok
    end
  end

  defp ensure_regular_file_or_absent(path) do
    case Glorbo.Filesystem.AgentWritableFile.ensure_writable(path) do
      :ok -> :ok
      {:error, {:not_regular_file, _}} -> {:error, :not_a_regular_file}
      {:error, {:stat_failed, reason}} -> {:error, reason}
    end
  end

  defp maybe_move_attachments(base, company, project, task_id) do
    src =
      Path.join([base, "companies", company, "projects", project, "attachments", task_id])

    dst =
      Path.join([
        base,
        "companies",
        company,
        "projects",
        project,
        "history",
        "attachments",
        task_id
      ])

    cond do
      not File.dir?(src) ->
        false

      match?({:error, _}, ensure_no_symlink_directory(Path.dirname(dst))) ->
        false

      true ->
        :ok = File.mkdir_p(Path.dirname(dst))

        case File.rename(src, dst) do
          :ok -> true
          _ -> false
        end
    end
  end

  defp emit_archive_audit(audit, company, task_rel_path, dest_rel, moved, actor) do
    entry = %{
      actor: actor,
      action: "task.delete",
      target: task_rel_path,
      company: company,
      dest: dest_rel,
      attachments_moved: to_string(moved)
    }

    Support.append_audit(audit, company, entry)
  end

  @doc """
  Reassign a task to a new agent + append an entry to its
  `handoff_chain:` (GEP-40). Exactly one filesystem write; the
  chain entry and the `assigned_to:` flip land atomically so a
  crash mid-handoff can't leave the two out of sync.

  `task_rel_path` is relative to `companies/<company>/`.

  Required `opts`:

    * `:actor` — who is initiating the handoff (typically the
      current assignee; for the approvals-deny path, the
      approvals gate passes "director").
    * `:reason` — free-text justification for the handoff (e.g.
      `"plan done, please implement"`).

  Optional `opts`:

    * `:base`, `:audit` — test seams, same semantics as the
      rest of the Actions module.

  ## Behaviour

  The new chain entry is built from:

      %{
        "from" => <old assigned_to (or "unassigned")>,
        "to"   => <new_assignee>,
        "reason" => <reason>,
        "ts"   => <ISO 8601 UTC>
      }

  When the target agent equals the current assignee the call is
  a no-op (returns `{:ok, result}` with an empty-append flag
  via `handoff_chain_len` unchanged + no audit emission).

  ## Audit

  Emits `task.reassign` with detail `from` / `to` / `reason`.
  """
  @spec reassign(String.t(), String.t(), String.t(), reassign_opts()) ::
          {:ok, reassign_result()} | {:error, term()}
  def reassign(company, task_rel_path, to_agent, opts \\ [])
      when is_binary(company) and is_binary(task_rel_path) and is_binary(to_agent) and
             is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    reason = opts |> Keyword.fetch!(:reason) |> to_string() |> String.trim()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    history_meta = %{
      actor: HomeHistory.actor_from_string(actor),
      action: "task.reassign",
      target: "companies/#{company}/#{task_rel_path}"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        with :ok <- Support.validate_slug(company, :company),
             :ok <- Support.validate_slug(to_agent, :agent),
             :ok <- validate_reason(reason),
             {:ok, project} <- project_of(task_rel_path),
             abs_path = Path.join([base, "companies", company, task_rel_path]),
             {:ok, task} <-
               Glorbo.TaskDefinition.parse_file(abs_path, base: base, company: company),
             from_agent = existing_assignee(task),
             :ok <- guard_non_noop(from_agent, to_agent) do
          do_reassign_write(tx_id, abs_path, base, company, task_rel_path, project, task,
            from_agent: from_agent,
            to_agent: to_agent,
            reason: reason,
            actor: actor,
            audit: audit
          )
        end
      end)

    case history_result do
      {:ok, result, _tx_id} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  defp do_reassign_write(tx_id, abs_path, base, company, task_rel_path, project, task, opts) do
    from_agent = Keyword.fetch!(opts, :from_agent)
    to_agent = Keyword.fetch!(opts, :to_agent)
    reason = Keyword.fetch!(opts, :reason)
    actor = Keyword.fetch!(opts, :actor)
    audit = Keyword.fetch!(opts, :audit)

    new_entry = build_entry(from_agent, to_agent, reason)
    new_chain = task.handoff_chain ++ [new_entry]

    updates = %{
      "assigned_to" => to_agent,
      "handoff_chain" => new_chain
    }

    with :ok <- Glorbo.TaskDefinition.write_frontmatter(abs_path, updates),
         :ok <- Tx.mark_path(tx_id, abs_path),
         :ok <-
           emit_reassign_audit(audit, company, task_rel_path, from_agent, to_agent,
             reason: reason,
             actor: actor,
             project: project
           ),
         :ok <- Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(base, company)) do
      {:ok,
       %{
         from: from_agent,
         to: to_agent,
         handoff_chain_len: length(new_chain)
       }}
    end
  end

  @doc """
  Record a peer-review verdict on a task (GEP-41). Flips
  `peer_review_verdict:` + the verdict-metadata fields
  (`_by`, `_at`, `_note`) atomically via `write_frontmatter/2`.
  Side-effects `status:` based on the verdict so the next
  consumer (Director approval gate, Kanban filter) sees a
  single state transition:

    * `:approve` → leaves status at `pending-approval`
    * `:revise`  → flips status to `in-progress`
    * `:block`   → flips status to `blocked` (new state is not
      yet in the enum — for now we emit `denied` so the
      existing board surfaces it; GEP-41 follow-up adds
      `blocked` to the enum)

  Required opts:

    * `:actor` — reviewer slug (normally `"critiqueops"`; the
      caller may pass a different slug if the task's
      `reviewer:` field named one).

  Optional opts:

    * `:note` — free-text justification (≤500 bytes). When
      present, stored in `peer_review_verdict_note:`.
    * `:base`, `:audit` — test seams.

  Rejects:

    * `:not_required` — task's `peer_review_required:` is false.
      Callers must check before invoking (the router will
      short-circuit for the common case).
    * `:already_decided` — a verdict was already recorded;
      GEP-41 D6 (append-only semantics) forbids overwrite.
      Callers handle re-review via a new task.

  ## Audit

  Emits `task.peer_review.<verdict>` with the note in detail.
  """
  @spec record_peer_review_verdict(
          String.t(),
          String.t(),
          verdict(),
          verdict_opts()
        ) ::
          {:ok, verdict_result()} | {:error, term()}
  def record_peer_review_verdict(company, task_rel_path, verdict, opts \\ [])
      when is_binary(company) and is_binary(task_rel_path) and
             verdict in [:approve, :revise, :block] and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    note = opts |> Keyword.get(:note, "") |> to_string() |> String.trim()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    history_meta = %{
      actor: HomeHistory.actor_from_string("agent:" <> actor),
      action: "task.peer_review.#{verdict}",
      target: "companies/#{company}/#{task_rel_path}"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        with :ok <- Support.validate_slug(company, :company),
             :ok <- Support.validate_slug(actor, :agent),
             :ok <- validate_note(note),
             {:ok, _project} <- project_of(task_rel_path),
             abs_path = Path.join([base, "companies", company, task_rel_path]),
             {:ok, task} <-
               Glorbo.TaskDefinition.parse_file(abs_path, base: base, company: company),
             :ok <- guard_review_required(task),
             :ok <- guard_actor_is_reviewer(actor, task),
             :ok <- guard_not_already_decided(task) do
          do_verdict_write(tx_id, abs_path, base, company, task_rel_path, task, verdict,
            actor: actor,
            note: note,
            audit: audit
          )
        end
      end)

    case history_result do
      {:ok, result, _tx_id} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  defp do_verdict_write(tx_id, abs_path, base, company, task_rel_path, task, verdict, opts) do
    actor = Keyword.fetch!(opts, :actor)
    note = Keyword.fetch!(opts, :note)
    audit = Keyword.fetch!(opts, :audit)

    verdict_str = Atom.to_string(verdict)
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    next_status = next_status_for(verdict, task.status)

    updates =
      %{
        "peer_review_verdict" => verdict_str,
        "peer_review_verdict_by" => actor,
        "peer_review_verdict_at" => ts,
        "status" => next_status
      }
      |> maybe_put("peer_review_verdict_note", note)

    with :ok <- Glorbo.TaskDefinition.write_frontmatter(abs_path, updates),
         :ok <- Tx.mark_path(tx_id, abs_path),
         :ok <- emit_verdict_audit(audit, company, task_rel_path, verdict_str, actor, note),
         :ok <- Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(base, company)) do
      # GEP-42: clean up the request sentinel from the reviewer's
      # inbox (best-effort — missing file is fine, the sentinel is
      # a wake trigger, not source of truth). On `revise`, drop a
      # feedback sentinel into the original assignee's inbox. Both
      # are inbox/state writes (excluded scope per GEP-33 §3.2) so
      # they don't get marked here.
      :ok =
        Glorbo.Actions.Reviews.clear_request_sentinel(company, actor, task.task_id, base: base)

      maybe_send_revise_feedback(verdict, company, task, actor, note, base, audit)
      {:ok, %{verdict: verdict, next_status: next_status}}
    end
  end

  # GEP-42: only `revise` with a non-empty note + a real
  # original-assignee distinct from the reviewer routes a feedback
  # sentinel. Approve / block don't generate feedback files; a
  # reviewer who is also the original assignee is a degenerate case
  # that doesn't need a wake (they already know what they wrote).
  defp maybe_send_revise_feedback(:revise, company, task, actor, note, base, audit)
       when is_binary(note) and note != "" do
    original_assignee = existing_assignee(task)

    if original_assignee != "unassigned" and original_assignee != actor do
      Glorbo.Actions.Reviews.write_revise_feedback(
        company,
        original_assignee,
        task,
        note,
        base: base,
        audit: audit
      )
    else
      :ok
    end
  end

  defp maybe_send_revise_feedback(_verdict, _co, _task, _actor, _note, _base, _audit), do: :ok

  defp validate_note(""), do: :ok
  defp validate_note(v) when is_binary(v) and byte_size(v) <= 500, do: :ok
  defp validate_note(_), do: {:error, :invalid_note}

  defp guard_review_required(%Glorbo.TaskDefinition{peer_review_required: true}), do: :ok
  defp guard_review_required(_), do: {:error, :not_required}

  # GEP-41 D2: only the task's configured reviewer (or the default
  # critiqueops when none is set) may record a verdict. Without this
  # guard, any agent with `tasks:update` could self-clear peer review
  # by writing an `ACTIONS: verdict: approve` reply through the
  # `Agent.Server` → `record_peer_review_verdict/5` path.
  defp guard_actor_is_reviewer(actor, %Glorbo.TaskDefinition{reviewer: reviewer}) do
    if actor == effective_reviewer(reviewer),
      do: :ok,
      else: {:error, :wrong_reviewer}
  end

  defp effective_reviewer(slug) when is_binary(slug) and slug != "", do: slug
  defp effective_reviewer(_), do: "critiqueops"

  defp guard_not_already_decided(%Glorbo.TaskDefinition{peer_review_verdict: nil}), do: :ok
  defp guard_not_already_decided(_), do: {:error, :already_decided}

  defp next_status_for(:approve, current), do: current || "pending-approval"
  defp next_status_for(:revise, _), do: "in-progress"
  defp next_status_for(:block, _), do: "denied"

  defp maybe_put(map, _k, ""), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp emit_verdict_audit(audit, company, rel_path, verdict, actor, note) do
    entry =
      %{
        actor: actor,
        action: "task.peer_review.#{verdict}",
        target: rel_path,
        company: company,
        verdict: verdict
      }
      |> Support.put_detail("note", note)

    Support.append_audit(audit, company, entry)
  end

  defp validate_reason(""), do: {:error, :invalid_reason}
  defp validate_reason(v) when is_binary(v) and byte_size(v) <= 500, do: :ok
  defp validate_reason(_), do: {:error, :invalid_reason}

  defp existing_assignee(%Glorbo.TaskDefinition{assigned_to: slug})
       when is_binary(slug) and slug != "",
       do: slug

  defp existing_assignee(_), do: "unassigned"

  defp guard_non_noop(same, same), do: {:error, :noop}
  defp guard_non_noop(_, _), do: :ok

  defp build_entry(from, to, reason) do
    %{
      "from" => from,
      "to" => to,
      "reason" => reason,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp emit_reassign_audit(audit, company, rel_path, from, to, opts) do
    entry =
      %{
        actor: Keyword.fetch!(opts, :actor),
        action: "task.reassign",
        target: rel_path,
        company: company,
        from: from,
        to: to
      }
      |> Support.put_detail("reason", Keyword.get(opts, :reason))
      |> Support.put_detail("project", Keyword.get(opts, :project))

    Support.append_audit(audit, company, entry)
  end

  defp resolve_task_id(opts, base, company, project) do
    case Keyword.get(opts, :task_id) do
      nil -> do_next_task_id(base, company, project)
      id when is_binary(id) -> validate_given_task_id(id)
      other -> {:error, {:invalid_task_id, other}}
    end
  end

  defp validate_given_task_id(id) do
    if Regex.match?(@task_id_re, id), do: {:ok, id}, else: {:error, {:invalid_task_id, id}}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp validate_title(title) when is_binary(title) do
    cond do
      title == "" -> {:error, :invalid_title}
      byte_size(title) > @title_max_bytes -> {:error, :invalid_title}
      true -> :ok
    end
  end

  # `<project>-NN.md` is the canonical filename (GEP-13). Legacy
  # `t-NN.md` files from pre-v0.0.3 are counted in the max so a mixed
  # tasks dir doesn't collide on id generation.
  defp do_next_task_id(base, company, project) do
    tasks_dir = Path.join([base, "companies", company, "projects", project, "tasks"])

    # Wave 26: an agent with `projects:write:<p>` can replace
    # `projects/<p>/tasks` with a symlink and redirect a director
    # task creation across companies. Refuse symlinked ancestors
    # before mkdir_p so the next-id scan + write stays in tree.
    if Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(tasks_dir) do
      {:error, :symlinked_ancestor}
    else
      File.mkdir_p!(tasks_dir)

      prefixed_re = ~r/\A#{Regex.escape(project)}-(\d+)\.md\z/
      legacy_re = ~r/\At-(\d+)\.md\z/

      max_n =
        case File.ls(tasks_dir) do
          {:ok, files} ->
            files
            |> Enum.map(fn f -> Regex.run(prefixed_re, f) || Regex.run(legacy_re, f) end)
            |> Enum.reject(&is_nil/1)
            |> Enum.map(fn [_, n] -> String.to_integer(n) end)
            |> Enum.max(fn -> 0 end)

          _ ->
            0
        end

      next = max_n + 1

      n_str =
        if next <= 99,
          do: String.pad_leading(Integer.to_string(next), 2, "0"),
          else: Integer.to_string(next)

      task_id = "#{project}-#{n_str}"

      if Regex.match?(@task_id_re, task_id),
        do: {:ok, task_id},
        else: {:error, {:invalid_task_id, task_id}}
    end
  end

  defp write_task_file(base, company, project, task_id, params, attachments) do
    title = params |> Map.get("title", "") |> to_string() |> String.trim()

    frontmatter = build_frontmatter(params, title)
    body = build_body(params, attachments)

    content = "---\n" <> frontmatter <> "---\n\n" <> body <> "\n"

    path = Path.join([base, "companies", company, "projects", project, "tasks", "#{task_id}.md"])

    # Threatmodel: `projects/<p>/tasks/` is RW-mounted for agents
    # holding `tasks:write:<p>`. A predictable tempfile name
    # (`path.tmp-<monotonic>`) lets an attacker pre-plant a symlink
    # at the next-integer name and redirect File.write. Use exclusive
    # open with an 8-byte random suffix so the path can't be predicted
    # AND can't be a symlink even on (vanishingly unlikely) collision.
    rand_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    tmp =
      "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}-#{rand_suffix}"

    case :file.open(tmp, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} ->
        result = :file.write(fd, content)
        :ok = :file.close(fd)

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

  # Compose the task's frontmatter as text. Ordered for human
  # readability; `FileSpec.Formatter` canonical order is applied by
  # `mix glorbo fmt` if the user ever runs it.
  defp build_frontmatter(params, title) do
    kind = "kind: task/v1\n"

    scalar = fn key ->
      params
      |> Map.get(key)
      |> case do
        v when v in [nil, "", false] -> ""
        v -> "#{key}: #{FrontmatterWriter.yaml_scalar(v)}\n"
      end
    end

    # Required + optional scalar keys, emitted only when non-empty.
    lines = [
      kind,
      "title: #{FrontmatterWriter.yaml_scalar(title)}\n",
      "status: todo\n",
      scalar.("assigned_to"),
      scalar.("requested_by"),
      scalar.("priority"),
      scalar.("severity"),
      scalar.("goal"),
      scalar.("schedule"),
      scalar.("requires_approval"),
      scalar.("peer_review_required"),
      scalar.("reviewer"),
      scalar.("provider"),
      scalar.("model"),
      scalar.("done_when")
    ]

    IO.iodata_to_binary(lines)
  end

  defp build_body(params, attachments) do
    description = params |> Map.get("description", "") |> to_string() |> String.trim()

    attach_block =
      case attachments do
        [] ->
          ""

        list ->
          "\n\n## Attachments\n\n" <>
            Enum.map_join(list, "\n", fn rel -> "- [#{Path.basename(rel)}](../#{rel})" end) <>
            "\n"
      end

    body_text =
      if description == "",
        do: params |> Map.get("title", "") |> to_string() |> String.trim(),
        else: description

    body_text <> attach_block
  end

  defp emit_create_audit(audit, company, rel_path, title, actor, params) do
    # AuditLog.append treats any key outside {ts, company, actor,
    # action, target} as a detail field — "detail:" is not a wrapper
    # key. Flatten detail fields at the top level of the entry so
    # they land in the JSONL's "detail" object under drop_known_keys.
    entry =
      %{
        actor: actor,
        action: "task.create",
        target: rel_path,
        company: company
      }
      |> Support.put_detail("title", title)
      |> Support.put_detail("assigned_to", Map.get(params, "assigned_to"))
      |> Support.put_detail("priority", Map.get(params, "priority"))
      |> Support.put_detail("severity", Map.get(params, "severity"))

    Support.append_audit(audit, company, entry)
  end

  # Derive `<project>` from a `projects/<project>/tasks/<id>.md` path.
  # Rejects anything else so callers can't trash a file outside a
  # project's tasks dir.
  defp project_of(rel_path) do
    case Regex.run(~r|\Aprojects/([a-z0-9][a-z0-9-]*)/tasks/[^/]+\.md\z|, rel_path) do
      [_whole, project] -> {:ok, project}
      _ -> {:error, {:invalid_task_rel_path, rel_path}}
    end
  end

  defp ensure_regular_file(abs_path) do
    case File.lstat(abs_path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: other}} -> {:error, {:not_regular_file, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_trash_dest(base, company, project, abs_src) do
    trash_dir =
      Path.join([base, "companies", company, "projects", project, "history", "deleted"])

    # Wave 26: refuse a symlinked `projects/<p>/history` or
    # `history/deleted` ancestor — without this an agent could
    # redirect the trash rename across companies.
    if Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(trash_dir) do
      {:error, :symlinked_ancestor}
    else
      with :ok <- File.mkdir_p(trash_dir) do
        ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")
        dest_name = "#{ts}-#{Path.basename(abs_src)}"
        abs_dest = Path.join(trash_dir, dest_name)
        dest_rel = "projects/#{project}/history/deleted/#{dest_name}"
        {:ok, dest_rel, abs_dest}
      end
    end
  end

  defp emit_trash_audit(audit, company, rel_path, dest_rel, actor) do
    Support.append_audit(audit, company, %{
      actor: actor,
      action: "task.trash",
      target: rel_path,
      company: company,
      dest: dest_rel
    })
  end
end
