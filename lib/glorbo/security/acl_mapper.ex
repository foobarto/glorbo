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

  @whitelisted_resources ~w(projects chat agents tasks proposals)

  @type permission :: {resource :: String.t(), action :: String.t(), scope :: String.t()}
  @type acl_mode :: :rwx | :rx | :r
  @type acl_entry :: {username :: String.t(), acl_mode(), path :: String.t()}

  @doc """
  Parse a `"resource:action:scope"` string into a permission tuple.

  Returns `{:ok, {resource, action, scope}}` on success,
  `{:error, :malformed}` if the string doesn't split into 3 non-empty parts,
  or `{:error, :unknown_resource}` if the resource isn't in the whitelist.
  """
  @spec parse_permission(String.t()) ::
          {:ok, permission()} | {:error, :unknown_resource | :malformed}
  def parse_permission(string) when is_binary(string) do
    case String.split(string, ":", parts: 3) do
      [resource, action, scope]
      when resource != "" and action != "" and scope != "" ->
        if resource in @whitelisted_resources do
          {:ok, {resource, action, scope}}
        else
          {:error, :unknown_resource}
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

  # Extract agent slug from username "glorbo-<company>-<agent>" -> "<agent>"
  defp extract_agent_slug(username) do
    case String.split(username, "-", parts: 3) do
      [_glorbo, _company, agent] -> agent
      _ -> username
    end
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

  # agents:create — no ACL entry (no agent has this in v1)
  defp permission_to_acl(_username, {"agents", "create", _scope}), do: []

  defp permission_to_acl(username, {"tasks", "update", scope}),
    do: [{username, :rwx, "projects/#{scope}/tasks"}]

  defp permission_to_acl(username, {"proposals", "write", "*"}),
    do: [{username, :rwx, "proposals"}]

  defp permission_to_acl(username, {"proposals", "read", "*"}),
    do: [{username, :rx, "proposals"}]

  # Catch-all for any other permission — no ACL entry
  defp permission_to_acl(_username, _perm), do: []
end
