defmodule Glorbo.Actions.Audit do
  @moduledoc """
  Audit-UI-triggered mutations (GEP-36).

  Single function today: `scaffold_from_entry/3` — convert an audit
  log entry into a follow-up task under
  `companies/<co>/projects/inbox/tasks/`.

  Enforces the **threatmodel H6** symlink-swap guard: agents can
  pre-seed paths inside the shared `projects/inbox/tasks/` directory,
  so `lstat` the target + `.tmp` path and refuse anything
  non-regular before writing.

  ## Contract

    * Returns `{:ok, result}` or `{:error, reason}`.
    * `opts` requires `:actor` — the director (or other user) who
      clicked "convert to task" in the Audit UI. This is the task's
      provenance actor, distinct from the audit entry's own
      `"actor"`.
    * Emits a `task.create` audit entry on success with
      `source: "audit"` + originating entry's action/ts as details.
  """

  alias Glorbo.Actions.Support
  alias Glorbo.Company.AuditLog

  @type scaffold_opts ::
          [actor: String.t(), base: Path.t(), audit: atom()]

  @type scaffold_result :: %{
          task_id: String.t(),
          rel_path: String.t(),
          abs_path: String.t()
        }

  @doc """
  Scaffold a follow-up task from the given audit log entry.

  `entry` is the audit JSON map as loaded by `AuditLive`
  (string-keyed; at minimum `"ts"`, `"actor"`, `"action"`, `"target"`
  are consulted — each defaults to a safe placeholder when missing).
  """
  @spec scaffold_from_entry(String.t(), map(), scaffold_opts()) ::
          {:ok, scaffold_result()} | {:error, term()}
  def scaffold_from_entry(company, entry, opts \\ [])
      when is_binary(company) and is_map(entry) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- Support.validate_slug(company, :company),
         {:ok, result} <- do_scaffold(base, company, entry) do
      :ok =
        emit_scaffold_audit(
          audit,
          company,
          result.rel_path,
          actor,
          entry
        )

      {:ok, result}
    end
  end

  defp do_scaffold(base, company, entry) do
    tasks_dir = Path.join([base, "companies", company, "projects", "inbox", "tasks"])
    :ok = File.mkdir_p(tasks_dir)

    ts = to_string(entry["ts"] || DateTime.to_iso8601(DateTime.utc_now()))
    audit_actor = to_string(entry["actor"] || "system")
    action = to_string(entry["action"] || "unknown")
    target = to_string(entry["target"] || "")

    task_id = uniqify(tasks_dir, gen_base(ts, action), 0)
    abs = Path.join(tasks_dir, "#{task_id}.md")
    rel = Path.join(["projects", "inbox", "tasks", "#{task_id}.md"])
    title = "Follow up on audit event: #{audit_actor} · #{action}"
    content = render(title, ts, audit_actor, action, target, entry)
    tmp = abs <> ".tmp"

    with :ok <- refuse_if_symlink(tmp),
         :ok <- refuse_if_symlink(abs),
         :ok <- write_atomic(tmp, abs, content) do
      {:ok, %{task_id: task_id, rel_path: rel, abs_path: abs}}
    end
  rescue
    e -> {:error, e}
  end

  defp write_atomic(tmp, abs, content) do
    with :ok <- File.write(tmp, content, [:sync]),
         :ok <- File.rename(tmp, abs) do
      :ok
    else
      err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp gen_base(ts, action) do
    slug =
      action
      |> String.replace(~r/[^a-z0-9]+/i, "-")
      |> String.downcase()
      |> String.trim("-")

    date = ts |> String.slice(0, 10) |> String.replace("-", "")
    "t-audit-#{date}-#{slug}"
  end

  defp uniqify(dir, base, n) do
    candidate = if n == 0, do: base, else: "#{base}-#{n}"

    if File.exists?(Path.join(dir, "#{candidate}.md")) do
      uniqify(dir, base, n + 1)
    else
      candidate
    end
  end

  defp render(title, ts, audit_actor, action, target, entry) do
    """
    ---
    title: #{yaml_escape(title)}
    status: todo
    source: audit
    audit_ts: #{ts}
    ---

    Follow-up triggered by an audit event.

    ## Context

    - **Timestamp**: #{ts}
    - **Actor**: #{audit_actor}
    - **Action**: #{action}
    - **Target**: #{target}

    ```json
    #{Jason.encode!(entry, pretty: true)}
    ```
    """
  end

  defp yaml_escape(s) when is_binary(s) do
    if String.contains?(s, [":", "#", "\""]) do
      "\"" <> String.replace(s, "\"", "\\\"") <> "\""
    else
      s
    end
  end

  # threatmodel H6: same semantic as Projects.ensure_writable —
  # regular file or enoent is OK, anything else (symlink,
  # directory, device) is a refuse.
  defp refuse_if_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :not_a_regular_file}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_scaffold_audit(audit, company, rel_path, actor, entry) do
    entry_ts = to_string(entry["ts"] || "")
    entry_action = to_string(entry["action"] || "")

    map =
      %{
        actor: actor,
        action: "task.create",
        target: rel_path,
        company: company,
        project: "inbox"
      }
      |> Support.put_detail("source", "audit")
      |> Support.put_detail("origin_ts", entry_ts)
      |> Support.put_detail("origin_action", entry_action)

    Support.append_audit(audit, company, map)
  end
end
