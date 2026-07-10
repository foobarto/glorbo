defmodule Glorbo.Security.ACLMapper do
  @moduledoc """
  Pure permission-to-ACL mapper (D-06).

  Translates `resource:action:scope` permission tuples from `agent.md`
  frontmatter into POSIX ACL entries for `setfacl` commands inside the
  container (Plan 05 ACLReconciler consumes `acl_entries/2`).

  Also provides `check_action/2` for the Router's application-layer
  permission check (SEC-01).

  **T-03-01 mitigation:** `parse_permission/1` uses `String.split/3` with
  `parts: 3` and pattern-matches against a fixed verb whitelist. No
  `String.to_atom` or `String.to_existing_atom` is ever called on user input.
  """

  alias Glorbo.Security.Capability

  @type permission :: {resource :: String.t(), action :: String.t(), scope :: String.t()}
  @type acl_mode :: :rwx | :rx | :r
  @type acl_entry :: {username :: String.t(), acl_mode(), path :: String.t()}

  @doc """
  Parse a `"resource:action:scope"` string into a permission tuple.

  Returns `{:ok, {resource, action, scope}}` on success,
  `{:error, :malformed}` if the string doesn't split into 3 non-empty parts,
  `{:error, :unknown_resource}` if the resource isn't in the whitelist,
  or `{:error, :invalid_scope}` if the scope is neither `"*"` nor a valid slug.
  """
  @spec parse_permission(String.t()) ::
          {:ok, permission()}
          | {:error,
             :invalid_scope | :unknown_resource | :unknown_action | :malformed | :not_implemented}
  def parse_permission(string) when is_binary(string) do
    case String.split(string, ":", parts: 3) do
      [resource, action, scope]
      when resource != "" and action != "" and scope != "" ->
        permission = {resource, action, scope}

        case Capability.validate(permission) do
          {:ok, _enforcement} -> {:ok, permission}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :malformed}
    end
  end

  @doc """
  Check whether `permissions` grant the requested `action`.

  Returns `:ok` on first matching permission (resource + action match,
  AND either wildcard scope or exact scope match). Returns
  `{:error, {:permission_denied, "resource:action:scope"}}` otherwise.
  """
  @spec check_action([permission()], {String.t(), String.t(), String.t()}) ::
          :ok | {:error, {:permission_denied, String.t()}}
  def check_action(permissions, {resource, action, target_scope}) do
    if Enum.any?(permissions, fn {r, a, s} ->
         r == resource and a == action and (s == "*" or s == target_scope)
       end) do
      :ok
    else
      {:error, {:permission_denied, "#{resource}:#{action}:#{target_scope}"}}
    end
  end

  @doc """
  Generate deterministic ACL entries for an agent username and permission set.

  Always includes the D-07 baseline (own outbox/workspace/state `:rwx`,
  own inbox `:r`). Permission-specific entries are added per the mapping
  table (D-06). Results are sorted by path for stable `permissions_hash`
  computation.
  """
  @spec acl_entries(String.t(), [permission()]) :: [acl_entry()]
  def acl_entries(username, permissions) when is_binary(username) and is_list(permissions) do
    Enum.each(permissions, &validate_permission!/1)
    agent_slug = extract_agent_slug(username)

    baseline = [
      {username, :r, "agents/#{agent_slug}/inbox"},
      {username, :rwx, "agents/#{agent_slug}/outbox"},
      {username, :rwx, "agents/#{agent_slug}/state"},
      {username, :rwx, "agents/#{agent_slug}/workspace"}
    ]

    permission_entries =
      permissions
      |> Enum.flat_map(fn perm -> permission_to_acl(username, perm) end)

    (baseline ++ permission_entries)
    |> Enum.uniq()
    |> Enum.sort_by(fn {_, _, path} -> path end)
  end

  @doc """
  Generate ACL entries with a company path available for wildcard expansion.

  POSIX ACLs do not understand glob segments. `tasks:read:*` and
  `tasks:update:*` are therefore expanded to the existing project task
  directories before the ordinary deterministic mapping is applied.
  """
  @spec acl_entries(String.t(), [permission()], String.t()) :: [acl_entry()]
  def acl_entries(username, permissions, company_path)
      when is_binary(username) and is_list(permissions) and is_binary(company_path) do
    expanded = Enum.flat_map(permissions, &expand_wildcard_task_permission(&1, company_path))
    acl_entries(username, expanded)
  end

  # Extract agent slug from username "glorbo-<company>-<agent>" -> "<agent>"
  defp extract_agent_slug(username) do
    case String.split(username, "-", parts: 3) do
      [_glorbo, _company, agent] -> agent
      _ -> username
    end
  end

  defp expand_wildcard_task_permission({"tasks", action, "*"}, company_path)
       when action in ["read", "update"] do
    projects_dir = Path.join(company_path, "projects")

    case File.lstat(projects_dir) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, entries} = File.ls(projects_dir)

        entries
        |> Enum.filter(fn project ->
          project_dir = Path.join(projects_dir, project)
          tasks_dir = Path.join(project_dir, "tasks")

          Glorbo.Slug.valid?(project) and directory?(project_dir) and directory?(tasks_dir)
        end)
        |> Enum.sort()
        |> Enum.map(&{"tasks", action, &1})

      {:error, :enoent} ->
        []

      other ->
        raise ArgumentError,
              "cannot expand wildcard task ACLs from #{projects_dir}: #{inspect(other)}"
    end
  end

  defp expand_wildcard_task_permission(permission, _company_path), do: [permission]

  defp validate_permission!(permission) do
    case Capability.validate(permission) do
      {:ok, _enforcement} ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "unsupported ACL permission #{inspect(permission)}: #{reason}"
    end
  end

  defp directory?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  # Map a permission tuple to zero or more ACL entries.
  # D-06 mapping table + D-08 channel ACLs.
  defp permission_to_acl(username, {"projects", "write", "*"}),
    do: [{username, :rwx, "projects"}]

  defp permission_to_acl(username, {"projects", "write", scope}),
    do: [{username, :rwx, "projects/#{scope}"}]

  defp permission_to_acl(username, {"projects", "read", "*"}),
    do: [{username, :rx, "projects"}]

  defp permission_to_acl(username, {"projects", "read", scope}),
    do: [{username, :rx, "projects/#{scope}"}]

  defp permission_to_acl(username, {"chat", "read", "*"}),
    do: [{username, :r, "channels"}]

  defp permission_to_acl(username, {"chat", "read", channel}),
    do: [{username, :r, "channels/#{channel}.md"}]

  # chat:write produces NO ACL entry — Elixir is sole writer (D-08)
  defp permission_to_acl(_username, {"chat", "write", _scope}), do: []

  # agents:message — no ACL entry needed (Router mediates)
  defp permission_to_acl(_username, {"agents", "message", _scope}), do: []

  defp permission_to_acl(_username, {"tasks", _action, "*"}) do
    raise ArgumentError,
          "wildcard task ACLs require company-path expansion; use acl_entries/3"
  end

  defp permission_to_acl(username, {"tasks", "read", scope}),
    do: [{username, :rx, "projects/#{scope}/tasks"}]

  defp permission_to_acl(username, {"tasks", "update", scope}),
    do: [{username, :rwx, "projects/#{scope}/tasks"}]

  # tasks:create is Router-mediated through the agent's own outbox.
  defp permission_to_acl(_username, {"tasks", "create", _scope}), do: []

  # proposals:read:* — RO access to the company's proposal tree
  defp permission_to_acl(username, {"proposals", "read", "*"}),
    do: [{username, :rx, "proposals"}]

  # proposals:propose:* / decide:* — Router-gated via outbox (GEP-28 D7);
  # no ACL entry needed. The agent's own outbox is already :rwx via the
  # D-07 baseline, so they can drop `agents/<slug>/outbox/proposals/<id>.md`
  # into place; the Router handles the move to `proposals/<id>.md`.
  defp permission_to_acl(_username, {"proposals", "propose", _scope}), do: []
  defp permission_to_acl(_username, {"proposals", "decide", _scope}), do: []

  # Parsed permissions are closed by Capability. Reaching this clause means a
  # caller bypassed parse_permission/1, so fail loudly instead of weakening the
  # policy with an unexplained empty ACL mapping.
  defp permission_to_acl(_username, permission) do
    raise ArgumentError, "unsupported ACL permission #{inspect(permission)}"
  end
end
