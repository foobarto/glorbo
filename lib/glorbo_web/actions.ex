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
    actor = Keyword.get(opts, :actor, "director")

    with :ok <- validate_slug(company),
         :ok <- validate_slug(channel),
         :ok <- validate_body(body),
         path = channel_path(base, company, channel),
         :ok <- ensure_regular_file(path) do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      entry = "\n## #{ts} | #{actor}\n#{body}\n"

      case File.write(path, entry, [:append, :sync]) do
        :ok ->
          AuditLog.append(audit, %{
            company: company,
            actor: actor,
            action: "chat.post",
            target: "channels/#{channel}.md",
            channel: channel
          })

          # #238 — rotate the channel file if it crossed size/line
          # thresholds. Rotation is post-append and best-effort:
          # failure here does NOT fail the post — the message is
          # already durably on disk + audited.
          _ = maybe_rotate_channel(company, path, channel, audit)

          # Mentions wake the named agent(s). Mirrors the
          # Glorbo.Company.Router mention-write shape so the downstream
          # Agent.Server treats it identically (same inbox/mentions/
          # path + `agent.wake` audit with `trigger: "mention"`).
          # T6 threatmodel: propagate the actor into the mention file
          # frontmatter so MCP-originated posts don't end up claiming
          # `from: "director"`.
          _ =
            route_mentions(
              base,
              company,
              channel,
              body,
              ts,
              audit,
              actor
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
         abs_task = Path.join([base, "companies", company, task_path]),
         :ok <- ensure_regular_file(abs_task) do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      task_id = task_path |> Path.basename() |> Path.rootname()
      # GEP-30 D8: comments live in a sibling `.comments.md` file,
      # not inline in the task body. The task file stays diff-clean;
      # the thread is rendered from the sibling by Kanban + TaskLive.
      comments_path = Glorbo.TaskComments.path_for(abs_task)

      case Glorbo.TaskComments.append(comments_path, "director", body,
             ts: ts,
             task_id: task_id
           ) do
        :ok ->
          AuditLog.append(audit, %{
            company: company,
            actor: "director",
            action: "task.comment",
            target: task_path
          })

          _ = wake_task_assignee(base, company, abs_task, task_id, body, ts, audit)
          _ = route_mentions(base, company, "task-#{task_id}", body, ts, audit, "director")

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
    # threatmodel [41]: assignee comes from the task file, which an
    # agent can author. Without slug validation, values like
    # `../../companies/other/agents/ceo` would let a task comment
    # land in another company's inbox (cross-company isolation
    # bypass) or any directory writable by the Glorbo user.
    with {:ok, content} <- File.read(abs_task_path),
         {:ok, fm} <- extract_frontmatter(content),
         assignee when is_binary(assignee) and assignee != "" <- Map.get(fm, "assigned_to"),
         true <- Glorbo.Slug.valid?(assignee) do
      write_mention(base, company, "task-#{task_id}", assignee, body, ts, audit, "director")
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

  defp route_mentions(base, company, channel, body, ts, audit, actor) do
    @mention_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.each(fn mentioned ->
      write_mention(base, company, channel, mentioned, body, ts, audit, actor)
    end)
  end

  defp write_mention(base, company, channel, mentioned, body, ts, audit, actor) do
    agent_dir = Path.join([base, "companies", company, "agents", mentioned])

    if File.dir?(agent_dir) do
      inbox_mentions = Path.join(agent_dir, "inbox/mentions")
      File.mkdir_p!(inbox_mentions)

      now = DateTime.utc_now()
      fname_ts = DateTime.to_unix(now, :millisecond)
      path = Path.join(inbox_mentions, "#{fname_ts}-#{channel}.md")

      # T6 threatmodel: stamp the actual caller's slug, not a hardcoded
      # "director". MCP-originated posts must carry `from: "mcp:<client>"`
      # so agents can distinguish Director instructions from tool-
      # initiated messages. Sanitized via `safe_actor_tag/1`.
      frontmatter = """
      ---
      channel: "#{channel}"
      from: "#{safe_actor_tag(actor)}"
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

      # Belt-and-braces: directly nudge the agent's Server.
      # Filesystem event → Watcher → PubSub → Agent.Server is the
      # canonical path but can miss in a few scenarios (watcher
      # subscription failed on boot before PubSub was ready, agent
      # was restarted between mention-write and event-propagation,
      # an inotify event got dropped under kernel pressure). A
      # direct `wake/3` call is idempotent with the handle_info
      # path — the server's wake-queue dedupes most-recent-wins —
      # so the worst case is we wake once instead of twice. Best
      # case, the mention lands on the agent within milliseconds.
      _ = safe_wake_mention(company, mentioned)
    end

    :ok
  end

  # T6 defense-in-depth: strip newlines, double-quotes, and leading/
  # trailing whitespace from the actor before it lands in YAML
  # frontmatter. Caller-supplied actors are already built from
  # `"mcp:#{context.client}"` or the literal "director", but an
  # adversarial context could push bad bytes in. Fall back to
  # "director" on pathological values to preserve the old default.
  defp safe_actor_tag(actor) when is_binary(actor) do
    cleaned =
      actor
      |> String.replace(~r/[\r\n\"]/, "")
      |> String.trim()

    cond do
      cleaned == "" -> "director"
      byte_size(cleaned) > 128 -> "director"
      true -> cleaned
    end
  end

  defp safe_actor_tag(_), do: "director"

  defp safe_wake_mention(company, slug) do
    case Registry.lookup(Glorbo.Agent.Registry, {:agent_server, company, slug}) do
      [{pid, _}] when is_pid(pid) ->
        try do
          Glorbo.Agent.Server.wake(pid, :mention, nil)
        catch
          _, _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
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
    actor = Keyword.get(opts, :actor, "director")

    with :ok <- validate_slug(company),
         :ok <- validate_task_path(task_path) do
      abs = Path.join([base, "companies", company, task_path])
      status = to_string(decision)
      # Threatmodel H4: tell the Gate a Director-driven status flip
      # is coming BEFORE the file write lands so its watcher-driven
      # handler doesn't misread our own write as an agent bypass
      # and revert it.
      mark_director_approval(company, task_path)

      # On approve, restore the task's assigned_to to the requesting
      # agent recorded in the sentinel. Request-flow (Gate) reassigns
      # to "director" while awaiting; grant must put it back so the
      # Kanban reflects the agent owning the work. We also look up on
      # denial so the audit entry carries the requesting agent.
      requesting_agent = lookup_requesting_agent(base, company, task_path)

      write_result =
        cond do
          decision == :denied and is_binary(denial_reason) and denial_reason != "" ->
            # Use write_frontmatter so we can ADD denial_reason even if the
            # file doesn't currently declare it. Rebuild from parsed fm.
            rebuild_frontmatter_with_denial(
              abs,
              status,
              String.trim(denial_reason),
              requesting_agent
            )

          is_binary(requesting_agent) ->
            # Both :approved and :denied (without reason) restore the task
            # assignment to the requesting agent so the requester sees the
            # outcome on their own lane instead of "director".
            TaskDefinition.write(abs, %{status: status, assigned_to: requesting_agent})

          true ->
            TaskDefinition.write(abs, %{status: status})
        end

      case write_result do
        :ok ->
          entry =
            %{
              company: company,
              actor: actor,
              action: "approval.#{decision}",
              target: task_path
            }
            |> maybe_put_denial_reason(decision, denial_reason)
            |> maybe_put_requesting_agent(requesting_agent)

          AuditLog.append(audit, entry)

          # Scaffold-on-approve: if this was a `kind: hire` task and
          # the decision was :approved, automatically run the agent
          # scaffold. Director remains the approval authority
          # (AGT-05 P15 preserved — agents never get agents:create);
          # Glorbo only automates the mechanical scaffold step the
          # Director would otherwise run via CLI.
          if decision == :approved do
            maybe_scaffold_hired_agent(company, abs, audit,
              scaffold_fun: Keyword.get(opts, :scaffold_fun)
            )
          end

          :ok

        {:error, _} = err ->
          err
      end
    end
  end

  # If the approved task frontmatter has `kind: hire` plus valid
  # `agent_slug` + `role` + `provider` + `model`, scaffold the agent
  # automatically and emit an `agent.scaffold` audit event. Opt-out:
  # omit any required field → no scaffold (caller can still run
  # `./glorbo new agent` manually).
  defp maybe_scaffold_hired_agent(company, abs_path, audit, opts) do
    scaffold = Keyword.get(opts, :scaffold_fun) || (&Glorbo.CLI.Scaffold.Agent.run/1)

    with {:ok, content} <- File.read(abs_path),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content),
         :ok <- hire_task?(fm),
         {:ok, args} <- hire_argv(company, fm) do
      case scaffold.(args) do
        {:new_agent, 0, msg} ->
          AuditLog.append(audit, %{
            company: company,
            actor: "director",
            action: "agent.scaffold",
            target: "agents/#{Enum.at(args, 0) |> String.split("/") |> List.last()}",
            source: "approval",
            argv: args,
            stdout: String.slice(msg, 0, 500)
          })

          :ok

        {:new_agent, code, msg} ->
          AuditLog.append(audit, %{
            company: company,
            actor: "director",
            action: "agent.scaffold_failed",
            target: abs_path,
            source: "approval",
            argv: args,
            exit_code: code,
            stdout: String.slice(msg, 0, 500)
          })

          :ok
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp hire_task?(%{"kind" => "hire"}), do: :ok
  defp hire_task?(_), do: {:error, :not_a_hire}

  # threatmodel M12: hire-task frontmatter is authored by an
  # agent (the HR role). Role + provider flow verbatim into
  # AGENT.md frontmatter via the scaffold CLI, so unescaped
  # newlines / `---` / `"` let a malicious HR agent inject extra
  # keys (permissions, network=open, etc.) into the new agent's
  # spec and self-escalate once the director approves the hire.
  # Slug is already regex-validated; tighten role to a printable
  # ASCII subset and pin provider to the known allowlist.
  @hire_role_re ~r/\A[A-Za-z][A-Za-z0-9 _.-]{0,63}\z/
  @hire_provider_allowlist ~w(claude-code codex gemini opencode)

  defp hire_argv(company, fm) do
    slug = to_string(fm["agent_slug"] || "")
    role = to_string(fm["role"] || "")
    provider = to_string(fm["provider"] || "")

    cond do
      slug == "" or role == "" or provider == "" ->
        {:error, :missing_hire_fields}

      not Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, slug) ->
        {:error, :invalid_agent_slug}

      not Regex.match?(@hire_role_re, role) ->
        {:error, :invalid_hire_role}

      provider not in @hire_provider_allowlist ->
        {:error, :invalid_hire_provider}

      true ->
        {:ok, ["#{company}/#{slug}", "--role", role, "--provider", provider]}
    end
  end

  defp maybe_put_requesting_agent(entry, agent) when is_binary(agent) and agent != "" do
    Map.put(entry, :agent, agent)
  end

  defp maybe_put_requesting_agent(entry, _), do: entry

  # Threatmodel H4: flag the Gate that a Director-initiated status flip
  # is in flight for this task_path. The Gate's watcher handler consumes
  # the mark and treats marked writes as legitimate; an unmarked transition
  # to approved/denied is treated as an agent self-approval attempt and
  # reverted.
  defp mark_director_approval(company, task_path) do
    gate = Glorbo.Company.Supervisor.via(company, :approvals_gate)
    _ = Glorbo.Approvals.Gate.mark_director_decision(gate, task_path)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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
    actor = Keyword.get(opts, :actor, "director")
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

      # threatmodel M03: `state/` is agent-writable. Without an lstat
      # check the agent could pre-plant a symlink at `wake-request.md`
      # pointing at an arbitrary host file, turning a Director-initiated
      # wake into a write into (say) `~/.glorbo/config.md`.
      with :ok <- ensure_regular_file_for_write(path),
           :ok <- File.write(path, body, [:sync]) do
        AuditLog.append(audit, %{
          company: company,
          actor: actor,
          action: "agent.wake_request",
          target: "agents/#{agent}",
          reason: reason
        })

        :ok
      end
    end
  end

  # M03 host-write guard — delegate to the canonical AgentWritableFile
  # seam. Local wrapper preserves the old `{:path_not_regular, _}` /
  # `{:path_stat_failed, _}` error shape callers match on.
  defp ensure_regular_file_for_write(path) do
    case Glorbo.Filesystem.AgentWritableFile.ensure_writable(path) do
      :ok -> :ok
      {:error, {:not_regular_file, type}} -> {:error, {:path_not_regular, type}}
      {:error, {:stat_failed, reason}} -> {:error, {:path_stat_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp channel_path(base, company, channel),
    do: Path.join([base, "companies", company, "channels", "#{channel}.md"])

  # Denial with reason: read existing fm, merge status+denial_reason, write
  # via write_frontmatter which can add keys the file didn't declare. When
  # a requesting agent slug is recoverable (sentinel present), also restore
  # assigned_to so the task lands back on the requester's lane.
  defp rebuild_frontmatter_with_denial(abs, status, denial_reason, requesting_agent) do
    with {:ok, content} <- File.read(abs),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      merged =
        fm
        |> Map.put("status", status)
        |> Map.put("denial_reason", denial_reason)
        |> maybe_put_assigned_to(requesting_agent)

      TaskDefinition.write_frontmatter(abs, merged)
    end
  end

  defp maybe_put_assigned_to(fm, agent) when is_binary(agent) and agent != "",
    do: Map.put(fm, "assigned_to", agent)

  defp maybe_put_assigned_to(fm, _), do: fm

  # Scan `agents/*/state/awaiting-approval-<task_id>.md` to recover the
  # requesting agent's slug so grant can restore task assignment. Returns
  # nil if no sentinel found (e.g. director pre-approving without a
  # request, or a task whose agent already retired).
  defp lookup_requesting_agent(base, company, task_path) do
    task_id = task_path |> Path.basename() |> Path.rootname()
    agents_dir = Path.join([base, "companies", company, "agents"])

    case File.ls(agents_dir) do
      {:ok, agents} ->
        Enum.find_value(agents, fn ag ->
          sentinel = Path.join([agents_dir, ag, "state", "awaiting-approval-#{task_id}.md"])
          if File.exists?(sentinel), do: ag
        end)

      _ ->
        nil
    end
  rescue
    _ -> nil
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

  defp yaml_scalar(v), do: Glorbo.Filesystem.FrontmatterWriter.yaml_scalar(v)

  defp validate_task_path(p) when is_binary(p) do
    cond do
      String.contains?(p, "..") -> {:error, :invalid_task_path}
      not String.starts_with?(p, "projects/") -> {:error, :invalid_task_path}
      not String.ends_with?(p, ".md") -> {:error, :invalid_task_path}
      true -> :ok
    end
  end

  defp validate_task_path(_), do: {:error, :invalid_task_path}

  # Defense against symlink-swap (T-04-01). Delegates to the canonical
  # AgentWritableFile seam and flattens the error shape to what the
  # post_message / post_task_comment callers already match on.
  defp ensure_regular_file(path) do
    case Glorbo.Filesystem.AgentWritableFile.ensure_writable(path) do
      :ok -> :ok
      {:error, {:not_regular_file, _}} -> {:error, :not_a_regular_file}
      {:error, {:stat_failed, reason}} -> {:error, reason}
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

  # #238 — post-append rotation hook. Best-effort; failure is logged
  # but never bubbles up (the caller's chat.post audit has already
  # been written). Emits `channel.rotate` on success so the archive
  # boundary is itself a durable audit record.
  defp maybe_rotate_channel(company, path, channel, audit) do
    case Glorbo.Chat.Rotation.maybe_rotate(path) do
      {:rotated, archive_path, kept} ->
        AuditLog.append(audit, %{
          company: company,
          actor: "system",
          action: "channel.rotate",
          target: "channels/#{channel}.md",
          archive_path: archive_path,
          kept_messages: kept
        })

        :ok

      _ ->
        :ok
    end
  end
end
