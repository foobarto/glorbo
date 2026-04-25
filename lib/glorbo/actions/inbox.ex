defmodule Glorbo.Actions.Inbox do
  @moduledoc """
  Agent inbox write operations (GEP-36).

  Currently one function: `deliver_task_assignment/5` — write a
  `task_assignment` inbox-message to `<agent>/inbox/` so the agent
  picks up a newly-assigned task on its next wake.

  Enforces **threatmodel M03**: `inbox/` is `--ro-bind` for each
  agent inside its sandbox, but defense-in-depth dictates we refuse
  to follow a pre-planted symlink on the host side.

  ## Contract

    * Returns `{:ok, result}` or `{:error, reason}`.
    * `opts` requires `:actor`.
    * Emits `inbox.deliver` audit entry on success.
  """

  alias Glorbo.Actions.Support
  alias Glorbo.Company.AuditLog

  @type deliver_opts :: [actor: String.t(), base: Path.t(), audit: atom()]

  @type deliver_result :: %{
          rel_path: String.t(),
          abs_path: String.t(),
          agent: String.t()
        }

  @doc """
  Deliver a task-assignment inbox message.

  ### Args

    * `company` — company slug.
    * `agent` — agent slug; must exist (agent dir present).
    * `task_id` — task id (referenced in the message header).
    * `title` — new task's title (shown in the inbox message body).
    * `body` — free-form message body.

  Returns `{:error, :agent_not_found}` when `<agent>/` isn't a
  directory, `{:error, :not_a_regular_file}` when the target
  inbox path is non-regular.
  """
  @spec deliver_task_assignment(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          deliver_opts()
        ) ::
          {:ok, deliver_result()} | {:error, term()}
  def deliver_task_assignment(company, agent, task_id, title, body, opts \\ [])
      when is_binary(company) and is_binary(agent) and is_binary(task_id) and
             is_binary(title) and is_binary(body) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- Support.validate_slug(company, :company),
         :ok <- Support.validate_slug(agent, :agent),
         agent_dir = agent_dir_path(base, company, agent),
         :ok <- guard_agent_exists(agent_dir),
         inbox_dir = Path.join(agent_dir, "inbox"),
         # Wave 27: refuse a pre-planted `inbox -> ../../audit` or
         # similar symlinked ancestor before mkdir_p / File.write.
         :ok <- refuse_symlinked_ancestors(inbox_dir),
         :ok <- File.mkdir_p(inbox_dir),
         path = inbox_path(inbox_dir, task_id),
         :ok <- ensure_writable(path),
         content = render(task_id, title, body),
         :ok <- File.write(path, content),
         rel = Path.join(["agents", agent, "inbox", Path.basename(path)]),
         :ok <- emit_deliver_audit(audit, company, agent, task_id, rel, actor) do
      {:ok, %{rel_path: rel, abs_path: path, agent: agent}}
    end
  end

  defp refuse_symlinked_ancestors(path) do
    if Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(path),
      do: {:error, :symlinked_ancestor},
      else: :ok
  end

  defp agent_dir_path(base, company, agent),
    do: Path.join([base, "companies", company, "agents", agent])

  defp inbox_path(inbox_dir, task_id) do
    ts = System.system_time(:millisecond)
    Path.join(inbox_dir, "#{ts}-task-#{task_id}.md")
  end

  defp guard_agent_exists(agent_dir) do
    if File.dir?(agent_dir), do: :ok, else: {:error, :agent_not_found}
  end

  defp ensure_writable(path) do
    case Glorbo.Filesystem.AgentWritableFile.ensure_writable(path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp render(task_id, title, body) do
    """
    ---
    kind: inbox-message/v1
    from: director
    task_id: "#{task_id}"
    subkind: task_assignment
    delivered_at: "#{DateTime.to_iso8601(DateTime.utc_now())}"
    ---

    # New task assigned: #{title}

    #{body}
    """
  end

  defp emit_deliver_audit(audit, company, agent, task_id, rel_path, actor) do
    entry = %{
      actor: actor,
      action: "inbox.deliver",
      target: rel_path,
      company: company,
      agent: agent,
      task_id: task_id,
      subkind: "task_assignment"
    }

    Support.append_audit(audit, company, entry)
  end
end
