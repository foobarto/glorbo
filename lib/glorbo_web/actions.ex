defmodule GlorboWeb.Actions do
  @moduledoc """
  Director write-actions. Every call resolves to a filesystem mutation
  (markdown append, frontmatter rewrite, or wake-request write) followed
  by an append-only `AuditLog` event — in that order, so a write failure
  never leaves an orphan audit trail (CLAUDE.md invariant: filesystem is
  source of truth).

  ## Functions

    * `post_message/4` — Director posts to `channels/<ch>.md`
      (`[:append, :sync]`); audit action `chat.post`.
    * `set_approval/4` — Director approves/denies a task by mutating
      its frontmatter `status:` via `Glorbo.TaskDefinition.write/2`;
      audit action `approval.approve` or `approval.deny`.
    * `wake_agent/3` — Director writes `agents/<slug>/state/wake-request.md`
      (the 4th wake trigger type, after inbox/heartbeat/mention);
      audit action `agent.wake_request`.

  ## Security posture (threat register T-04-01..T-04-08)

    * **Slug validation.** `company`, `channel`, and `agent` strings MUST
      match `~r/\\A[a-z0-9-]+\\z/` — otherwise path-traversal (T-04-08) is
      possible via `../`. All three public functions reject bad slugs up
      front with `{:error, :invalid_slug}`.
    * **Task path validation.** `task_path` passed to `set_approval/4`
      must start with `projects/`, end with `.md`, and contain no `..`
      segments.
    * **Regular-file check.** `post_message/4` calls `File.lstat!/1`
      before `:append` to defend against a symlink swap
      (T-04-01).
    * **Body cap.** 10 KiB per message — matches the Frontmatter size
      cap (T-04-01 DoS defense).

  ## Dep injection

  Every function accepts `opts[:base]` (default `~/.glorbo`) for
  filesystem root and `opts[:audit]` (default the global `AuditLog`
  name) for test-time capture.
  """

  alias Glorbo.Company.AuditLog
  alias Glorbo.TaskDefinition

  @slug_re ~r/\A[a-z0-9-]+\z/
  @body_max_bytes 10_240
  # WR-05: cap wake-agent reason to 500 bytes (UI client-side is 200
  # chars; the channel payload is untrusted, so enforce a hard cap
  # server-side too). Parallels @body_max_bytes for post_message/4.
  @reason_max_bytes 500

  @type ok_or_err :: :ok | {:error, term()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Append a Director message to `channels/<channel>.md`.

  Writes the message FIRST (with `[:append, :sync]`); emits the
  `chat.post` audit event SECOND. If the file write fails, no audit
  event is emitted and the error is returned verbatim.
  """
  @spec post_message(String.t(), String.t(), String.t(), keyword()) :: ok_or_err
  def post_message(company, channel, body, opts \\ []) when is_binary(body) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    audit = Keyword.get_lazy(opts, :audit, fn -> resolve_audit(company) end)

    with :ok <- validate_slug(company),
         :ok <- validate_slug(channel),
         :ok <- validate_body(body),
         path = channel_path(base, company, channel),
         :ok <- ensure_regular_file(path) do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      entry = "\n## #{ts} | Director\n#{body}\n"

      case File.write(path, entry, [:append, :sync]) do
        :ok ->
          AuditLog.append(audit, %{
            company: company,
            actor: "director",
            action: "chat.post",
            target: "channels/#{channel}.md",
            channel: channel
          })

          # Director mentions wake the named agent(s). Mirrors the
          # Glorbo.Company.Router mention-write shape so the downstream
          # Agent.Server treats it identically (same inbox/mentions/
          # path + `agent.wake` audit with `trigger: "mention"`).
          _ =
            route_director_mentions(
              base,
              company,
              channel,
              body,
              ts,
              audit
            )

          :ok

        {:error, _} = err ->
          err
      end
    end
  end

  @task_path_re ~r{\Aprojects/[a-z0-9-]+/tasks/[a-z0-9-]+\.md\z}

  @doc """
  Append a Director comment to a task's body and wake everyone who
  should see it (assignee + any `@mentioned` agents).

  Comments are stored inline at the end of the task's body using the
  same `## <ts> | <author>\\n<body>` shape that channels use. This
  makes the task file the single source of truth for the conversation
  — the agent's next invocation reads the whole task file and sees
  the new comment.

  Wake targets:
    * The task's `assigned_to` agent (if any) — as a `task-<id>` mention
      delivered to `agents/<slug>/inbox/mentions/<ts>-task-<id>.md`.
    * Every `@slug` in the comment body — same shape.

  Rejects the same things `post_message/4` does: invalid company slug,
  empty body, oversize body, symlinked target.
  """
  @spec post_task_comment(String.t(), String.t(), String.t(), keyword()) :: ok_or_err
  def post_task_comment(company, task_path, body, opts \\ []) when is_binary(body) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    audit = Keyword.get_lazy(opts, :audit, fn -> resolve_audit(company) end)

    with :ok <- validate_slug(company),
         :ok <- validate_task_path_strict(task_path),
         :ok <- validate_body(body),
         :ok <- validate_comment_nonblank(body),
         abs = Path.join([base, "companies", company, task_path]),
         :ok <- ensure_regular_file(abs) do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      entry = "\n## #{ts} | Director\n#{body}\n"

      case File.write(abs, entry, [:append, :sync]) do
        :ok ->
          task_id = task_path |> Path.basename() |> Path.rootname()

          AuditLog.append(audit, %{
            company: company,
            actor: "director",
            action: "task.comment",
            target: task_path
          })

          _ = wake_task_assignee(base, company, abs, task_id, body, ts, audit)
          _ = route_director_mentions(base, company, "task-#{task_id}", body, ts, audit)

          :ok

        {:error, _} = err ->
          err
      end
    end
  end

  defp validate_task_path_strict(p) when is_binary(p) do
    cond do
      String.contains?(p, "..") -> {:error, :invalid_task_path}
      not Regex.match?(@task_path_re, p) -> {:error, :invalid_task_path}
      true -> :ok
    end
  end

  defp validate_task_path_strict(_), do: {:error, :invalid_task_path}

  defp wake_task_assignee(base, company, abs_task_path, task_id, body, ts, audit) do
    with {:ok, content} <- File.read(abs_task_path),
         {:ok, fm} <- extract_frontmatter(content),
         assignee when is_binary(assignee) and assignee != "" <- Map.get(fm, "assigned_to") do
      # The Router's `@mention` path only fires for literal `@slug` matches
      # in the body — an assignee who isn't @mentioned wouldn't otherwise
      # get notified. Write the same inbox/mentions shape for them.
      write_director_mention(base, company, "task-#{task_id}", assignee, body, ts, audit)
    else
      _ -> :ok
    end
  end

  defp extract_frontmatter(content) do
    case String.split(content, ~r/\A---\r?\n|\r?\n---\r?\n/, parts: 3) do
      ["", fm, _body] ->
        pairs =
          fm
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_fm_line/1)
          |> Enum.reject(&is_nil/1)
          |> Map.new()

        {:ok, pairs}

      _ ->
        {:error, :no_frontmatter}
    end
  end

  defp parse_fm_line(line) do
    case Regex.run(~r/\A\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)\z/, line) do
      [_, key, value] ->
        {key, value |> String.trim() |> String.trim(~s("))}

      _ ->
        nil
    end
  end

  @mention_regex ~r/@([a-z][a-z0-9_-]{0,63})/

  defp route_director_mentions(base, company, channel, body, ts, audit) do
    @mention_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.each(fn mentioned ->
      write_director_mention(base, company, channel, mentioned, body, ts, audit)
    end)
  end

  defp write_director_mention(base, company, channel, mentioned, body, ts, audit) do
    agent_dir = Path.join([base, "companies", company, "agents", mentioned])

    if File.dir?(agent_dir) do
      inbox_mentions = Path.join(agent_dir, "inbox/mentions")
      File.mkdir_p!(inbox_mentions)

      now = DateTime.utc_now()
      fname_ts = DateTime.to_unix(now, :millisecond)
      path = Path.join(inbox_mentions, "#{fname_ts}-#{channel}.md")

      frontmatter = """
      ---
      channel: "#{channel}"
      from: "director"
      source_msg: "#{ts}"
      delivered_at: "#{DateTime.to_iso8601(now)}"
      ---

      """

      _ = File.write(path, frontmatter <> body)

      AuditLog.append(audit, %{
        company: company,
        actor: "system",
        action: "agent.wake",
        agent: mentioned,
        trigger: "mention"
      })
    end

    :ok
  end

  @doc """
  Mutate a task's frontmatter `status:` to either `"approved"` or
  `"denied"`. The actual rewrite is delegated to
  `Glorbo.TaskDefinition.write/2`, which is atomic (tmp + rename).
  """
  @spec set_approval(String.t(), String.t(), :approved | :denied, keyword()) :: ok_or_err
  def set_approval(company, task_path, decision, opts \\ [])
      when decision in [:approved, :denied] do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    audit = Keyword.get_lazy(opts, :audit, fn -> resolve_audit(company) end)
    denial_reason = Keyword.get(opts, :denial_reason)

    with :ok <- validate_slug(company),
         :ok <- validate_task_path(task_path) do
      abs = Path.join([base, "companies", company, task_path])
      status = to_string(decision)

      write_result =
        if decision == :denied and is_binary(denial_reason) and denial_reason != "" do
          # Use write_frontmatter so we can ADD denial_reason even if the
          # file doesn't currently declare it. Rebuild from parsed fm.
          rebuild_frontmatter_with_denial(abs, status, String.trim(denial_reason))
        else
          TaskDefinition.write(abs, %{status: status})
        end

      case write_result do
        :ok ->
          entry =
            %{
              company: company,
              actor: "director",
              action: "approval.#{decision}",
              target: task_path
            }
            |> maybe_put_denial_reason(decision, denial_reason)

          AuditLog.append(audit, entry)

          :ok

        {:error, _} = err ->
          err
      end
    end
  end

  defp maybe_put_denial_reason(entry, :denied, r) when is_binary(r) and r != "" do
    Map.put(entry, :denial_reason, String.trim(r))
  end

  defp maybe_put_denial_reason(entry, _, _), do: entry

  @doc """
  Write a `state/wake-request.md` file for `agent` — this is the 4th
  wake trigger type (after inbox, heartbeat, mention). Agent.Server
  subscribes to `company:<co>:agents:<ag>:wake` via the Watcher and
  handles the file's appearance.
  """
  @spec wake_agent(String.t(), String.t(), String.t() | nil, keyword()) :: ok_or_err
  def wake_agent(company, agent, reason, opts \\ []) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    audit = Keyword.get_lazy(opts, :audit, fn -> resolve_audit(company) end)
    reason = reason || ""

    with :ok <- validate_slug(company),
         :ok <- validate_slug(agent),
         :ok <- validate_reason(reason),
         dir = Path.join([base, "companies", company, "agents", agent, "state"]),
         # WR-06: use non-bang mkdir_p so a permission/disk failure
         # surfaces as {:error, reason} and doesn't crash the caller LV.
         :ok <- File.mkdir_p(dir) do
      path = Path.join(dir, "wake-request.md")
      ts = DateTime.utc_now() |> DateTime.to_iso8601()

      body = """
      ---
      requested_at: "#{ts}"
      reason: #{yaml_scalar(reason)}
      ---

      Director wake request.
      """

      case File.write(path, body, [:sync]) do
        :ok ->
          AuditLog.append(audit, %{
            company: company,
            actor: "director",
            action: "agent.wake_request",
            target: "agents/#{agent}",
            reason: reason
          })

          :ok

        {:error, _} = err ->
          err
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp channel_path(base, company, channel),
    do: Path.join([base, "companies", company, "channels", "#{channel}.md"])

  # Denial with reason: read existing fm, merge status+denial_reason, write
  # via write_frontmatter which can add keys the file didn't declare.
  defp rebuild_frontmatter_with_denial(abs, status, denial_reason) do
    with {:ok, content} <- File.read(abs),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      merged =
        fm
        |> Map.put("status", status)
        |> Map.put("denial_reason", denial_reason)

      TaskDefinition.write_frontmatter(abs, merged)
    end
  end

  defp validate_slug(s) when is_binary(s) do
    if Regex.match?(@slug_re, s), do: :ok, else: {:error, :invalid_slug}
  end

  defp validate_slug(_), do: {:error, :invalid_slug}

  defp validate_body(""), do: {:error, :empty_body}
  defp validate_body(b) when byte_size(b) > @body_max_bytes, do: {:error, :body_too_large}
  defp validate_body(b) when is_binary(b), do: :ok
  defp validate_body(_), do: {:error, :invalid_body}

  defp validate_comment_nonblank(b) when is_binary(b) do
    if String.trim(b) == "", do: {:error, :empty_body}, else: :ok
  end

  # WR-05: cap reason size and require a binary. nil is coerced to ""
  # by the caller, so all paths land here with a binary.
  defp validate_reason(r) when is_binary(r) and byte_size(r) > @reason_max_bytes,
    do: {:error, :reason_too_large}

  defp validate_reason(r) when is_binary(r), do: :ok
  defp validate_reason(_), do: {:error, :invalid_reason}

  # WR-05: YAML scalar emitter matching Glorbo.TaskDefinition.yaml_scalar/1
  # semantics — quotes when the value contains YAML-ambiguous chars or a
  # reserved word, and escapes `\` / `"` / newlines / control chars so the
  # resulting frontmatter is always parse-safe. Empty strings emit `""`.
  defp yaml_scalar(""), do: ~s("")

  defp yaml_scalar(v) when is_binary(v) do
    if v =~ ~r/[\s#:\[\]\{\},&\*!\|>'"%@`]|\A(true|false|null|yes|no)\z|[\x00-\x1f]/ do
      escaped =
        v
        |> String.replace("\\", "\\\\")
        |> String.replace(~s("), ~s(\\"))
        |> String.replace("\n", "\\n")
        |> String.replace("\r", "\\r")
        |> String.replace("\t", "\\t")
        # Strip any remaining control chars to keep scalars single-line.
        |> String.replace(~r/[\x00-\x1f]/, "")

      ~s("#{escaped}")
    else
      v
    end
  end

  defp validate_task_path(p) when is_binary(p) do
    cond do
      String.contains?(p, "..") -> {:error, :invalid_task_path}
      not String.starts_with?(p, "projects/") -> {:error, :invalid_task_path}
      not String.ends_with?(p, ".md") -> {:error, :invalid_task_path}
      true -> :ok
    end
  end

  defp validate_task_path(_), do: {:error, :invalid_task_path}

  # Defense against symlink-swap (T-04-01). If the file exists it must be
  # a regular file; :enoent is allowed (first write creates the file).
  defp ensure_regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :not_a_regular_file}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Resolve the per-company AuditLog server. Falls back to the bare module
  # name if no pid is registered under the company-scoped via tuple — that
  # path keeps test-time fallbacks (where LiveCase starts an AuditLog under
  # the module name directly) working without changes.
  defp resolve_audit(company) do
    via = {:via, Registry, {Glorbo.Agent.Registry, {:company_child, company, :audit_log}}}

    case Registry.lookup(Glorbo.Agent.Registry, {:company_child, company, :audit_log}) do
      [{_pid, _}] -> via
      _ -> AuditLog
    end
  end
end
