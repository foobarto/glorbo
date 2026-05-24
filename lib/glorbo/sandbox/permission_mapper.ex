defmodule Glorbo.Sandbox.PermissionMapper do
  @moduledoc """
  Maps per-agent permission tuples to `bwrap(1)` argv flags (D-11, SEC-02).

  This is the kernel-layer counterpart to `Glorbo.Security.ACLMapper`
  (Plan 03-01): where ACLMapper emits POSIX ACL tuples for the deferred
  container runtime, this module emits `--ro-bind` / `--bind` flags for
  the CLI-first v0.0.1 bwrap sandbox.

  ## D-11 mapping table

  | Permission                    | Effect in sandbox                                   |
  |-------------------------------|-----------------------------------------------------|
  | `projects:read:*`             | `--ro-bind <co>/projects /projects`                 |
  | `projects:read:<name>`        | `--ro-bind <co>/projects/<name> /projects/<name>`   |
  | `projects:write:*`            | `--bind <co>/projects /projects`                    |
  | `projects:write:<name>`       | `--bind <co>/projects/<name> /projects/<name>`      |
  | `chat:read:*`                 | `--ro-bind <co>/channels /channels`                 |
  | `chat:read:<channel>`         | `--ro-bind <co>/channels/<channel>.md /channels/... |
  | `chat:write:*`                | `[]` (Router mediates all channel writes)           |
  | `agents:message:*`            | `[]` (Router mediates all agent messages)           |
  | `agents:create:*`             | `[]` (never granted in v0.0.1; AGT-05)              |
  | `agents:list:*`               | REJECTED at parse time (`ACLMapper.parse_permission`) |
  | `tasks:update:<project>`      | `--bind <co>/projects/<project>/tasks /projects/... |

  **Sibling invisibility (D-10):** when only a scoped permission is granted
  (e.g. `projects:write:website`), the parent `projects/` directory is NOT
  mounted. Sibling projects are absent from the sandbox VFS — the kernel
  returns ENOENT on any open attempt. No `ls /projects` reveals other
  companies' or sibling projects' existence.

  **`agents:list:*` is rejected at parse time.** The permission never
  had a kernel-layer implementation (staging-tmpfs filtering of
  `agents/*/` was the D-12 design but was never shipped). Accepting a
  permission the runtime cannot enforce is a silent lie, so
  `Glorbo.Security.ACLMapper.parse_permission/1` now returns
  `{:error, :not_implemented}` for it and the agent's AGENT.md fails to
  load. Inter-agent discovery is via the Router's
  `agents:message:<target>` permission family.
  """

  @type permission :: {resource :: String.t(), action :: String.t(), scope :: String.t()}

  @doc """
  Translate a list of permissions into a flat bwrap argv list.

  Takes the list of permissions (as parsed by `Glorbo.Security.ACLMapper.parse_permission/1`)
  and the company's absolute base directory (e.g.
  `~/.glorbo/companies/acme`). Returns a flat list of strings suitable for
  splicing into `Glorbo.Sandbox.Bwrap.build_argv/1`'s output.

  Does NOT emit baseline workspace/inbox/outbox mounts — those are the
  caller's responsibility (Bwrap composes them alongside the per-permission
  flags).
  """
  @spec to_argv([permission()], company_path :: String.t()) :: [String.t()]
  def to_argv(permissions, company_path) when is_list(permissions) and is_binary(company_path) do
    Enum.flat_map(permissions, &permission_to_flags(&1, company_path))
  end

  # ---------------------------------------------------------------------------
  # Per-permission flag emission
  # ---------------------------------------------------------------------------

  # projects:write:* → rw-bind whole projects tree
  defp permission_to_flags({"projects", "write", "*"}, co) do
    mount(:write, Path.join(co, "projects"), "/projects")
  end

  # projects:write:<name> → rw-bind just that project (sibling projects invisible)
  defp permission_to_flags({"projects", "write", name}, co) when name != "*" do
    name = assert_safe_scope!(name)
    mount(:write, Path.join([co, "projects", name]), "/projects/#{name}")
  end

  # projects:read:* → ro-bind whole projects tree
  defp permission_to_flags({"projects", "read", "*"}, co) do
    mount(:read, Path.join(co, "projects"), "/projects")
  end

  # projects:read:<name>
  defp permission_to_flags({"projects", "read", name}, co) when name != "*" do
    name = assert_safe_scope!(name)
    mount(:read, Path.join([co, "projects", name]), "/projects/#{name}")
  end

  # chat:read:* → ro-bind whole channels tree
  defp permission_to_flags({"chat", "read", "*"}, co) do
    mount(:read, Path.join(co, "channels"), "/channels")
  end

  # chat:read:<channel> → ro-bind single channel file
  defp permission_to_flags({"chat", "read", channel}, co) when channel != "*" do
    channel = assert_safe_scope!(channel)
    mount(:read, Path.join([co, "channels", "#{channel}.md"]), "/channels/#{channel}.md")
  end

  # chat:write:* → empty (Router mediates; no direct write)
  defp permission_to_flags({"chat", "write", _scope}, _co), do: []

  # agents:message:* → empty (Router mediates; no direct inbox write)
  defp permission_to_flags({"agents", "message", _scope}, _co), do: []

  # agents:create:* → empty (categorically denied; AGT-05)
  defp permission_to_flags({"agents", "create", _scope}, _co), do: []

  # `agents:list:*` is now rejected at parse time by
  # `Glorbo.Security.ACLMapper.parse_permission/1` (returns
  # `{:error, :not_implemented}`), so this module never sees it in
  # a parsed permission list. The clause was removed in the
  # round-3 sweep — dead code that promised a capability the
  # runtime never enforced.

  # tasks:update:<project> → rw-bind the project's tasks/ subdir
  defp permission_to_flags({"tasks", "update", project}, co) when project != "*" do
    project = assert_safe_scope!(project)
    mount(:write, Path.join([co, "projects", project, "tasks"]), "/projects/#{project}/tasks")
  end

  # proposals:read:* → ro-bind whole proposals tree
  defp permission_to_flags({"proposals", "read", "*"}, co) do
    mount(:read, Path.join(co, "proposals"), "/proposals")
  end

  # proposals:propose:* / proposals:decide:* → no kernel mount.
  # GEP-28 D7: agent-sourced proposal writes go through the Router via
  # `agents/<sender>/outbox/proposals/<id>.md` (outbox is already RW via
  # the D-07 ACL baseline). The Router validates and writes to
  # `proposals/<id>.md` from the host side; the agent never holds RW on
  # the proposals tree.
  defp permission_to_flags({"proposals", "propose", _scope}, _co), do: []
  defp permission_to_flags({"proposals", "decide", _scope}, _co), do: []

  # Unknown permission family → empty (no kernel mount)
  defp permission_to_flags({_resource, _action, _scope}, _co), do: []

  # Build the `--bind`/`--ro-bind` flag triple AFTER walking the host
  # path's ancestor segments to refuse any symlink.
  #
  # Codex round-3 finding (PR #35): the previous shape interpolated
  # `Path.join` straight into the argv list, trusting that scope-slug
  # validation kept the path safe. But the LEAF segment of a scope-
  # built mount source (e.g. `<co>/projects/foo/tasks`) is on a writable
  # tree if a sibling permission (e.g. `projects:write:foo`) is granted
  # — the writer could replace `tasks` with a symlink to `~/.ssh`, and
  # a subsequent dispatch holding only `tasks:update:foo` would have
  # bwrap mount `~/.ssh` rw inside the new namespace. Walk the host
  # path here so the check applies at the argv-emission boundary —
  # whether the bind is granted to the same agent or a sibling, the
  # next dispatch's argv gets refused.
  defp mount(mode, host, sandbox) when mode in [:read, :write] do
    :ok =
      Glorbo.Sandbox.SymlinkGuard.assert_no_symlink_segment!(
        host,
        "permission_mapper: mount source"
      )

    flag = if mode == :write, do: "--bind", else: "--ro-bind"
    [flag, host, sandbox]
  end

  # Defense-in-depth assertion: every scope string that reaches
  # `Path.join` here is supposed to already be slug-validated by
  # `Glorbo.Security.ACLMapper.parse_permission/1`. If it isn't —
  # because a future regression lets `projects:read:../../etc`
  # through the parser — refuse loudly rather than emit a
  # `--bind ../../etc` argv slot. Opencode + codex round-3 flagged
  # this as the class that would have caught a parser drift.
  defp assert_safe_scope!(scope) when is_binary(scope) do
    if Glorbo.Slug.valid?(scope) do
      scope
    else
      raise ArgumentError,
            "permission_mapper: refusing unsafe scope #{inspect(scope)} — " <>
              "ACLMapper.parse_permission/1 should have rejected it upstream"
    end
  end
end
