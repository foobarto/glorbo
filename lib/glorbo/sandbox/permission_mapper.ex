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
  | `agents:list:*`               | `[]` + Logger.warning (D-12 deferred to v0.0.2)     |
  | `tasks:update:<project>`      | `--bind <co>/projects/<project>/tasks /projects/... |

  **Sibling invisibility (D-10):** when only a scoped permission is granted
  (e.g. `projects:write:website`), the parent `projects/` directory is NOT
  mounted. Sibling projects are absent from the sandbox VFS — the kernel
  returns ENOENT on any open attempt. No `ls /projects` reveals other
  companies' or sibling projects' existence.

  **agents:list gap (D-12 deferred):** Full D-12 staging-tmpfs filtering
  of `agents/*/` to expose only sibling `agent.md` files (hiding private
  inbox/outbox/state subdirs) is not shipped in v0.0.1 — the complexity is
  not justified since the example company in v0.0.1 grants no agent the
  `agents:list` permission. If a user adds `agents:list` to an agent, a
  warning is logged and the permission translates to `[]` (no filesystem
  view). Inter-agent discovery in v0.0.1 is via the Router's
  `agents:message:<target>` permission family instead. Implementing
  sibling-view staging is tracked as a v0.0.2 follow-up.
  """
  require Logger

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
    ["--bind", Path.join(co, "projects"), "/projects"]
  end

  # projects:write:<name> → rw-bind just that project (sibling projects invisible)
  defp permission_to_flags({"projects", "write", name}, co) when name != "*" do
    ["--bind", Path.join([co, "projects", name]), "/projects/#{name}"]
  end

  # projects:read:* → ro-bind whole projects tree
  defp permission_to_flags({"projects", "read", "*"}, co) do
    ["--ro-bind", Path.join(co, "projects"), "/projects"]
  end

  # projects:read:<name>
  defp permission_to_flags({"projects", "read", name}, co) when name != "*" do
    ["--ro-bind", Path.join([co, "projects", name]), "/projects/#{name}"]
  end

  # chat:read:* → ro-bind whole channels tree
  defp permission_to_flags({"chat", "read", "*"}, co) do
    ["--ro-bind", Path.join(co, "channels"), "/channels"]
  end

  # chat:read:<channel> → ro-bind single channel file
  defp permission_to_flags({"chat", "read", channel}, co) when channel != "*" do
    ["--ro-bind", Path.join([co, "channels", "#{channel}.md"]), "/channels/#{channel}.md"]
  end

  # chat:write:* → empty (Router mediates; no direct write)
  defp permission_to_flags({"chat", "write", _scope}, _co), do: []

  # agents:message:* → empty (Router mediates; no direct inbox write)
  defp permission_to_flags({"agents", "message", _scope}, _co), do: []

  # agents:create:* → empty (categorically denied; AGT-05)
  defp permission_to_flags({"agents", "create", _scope}, _co), do: []

  # agents:list:* → empty + warning. The staging-tmpfs implementation
  # that would materialise an agent roster inside the sandbox is
  # deferred. Until it lands, this permission is a no-op at the
  # kernel layer — the agent can't `ls /agents/` — so the Router
  # remains the only path for inter-agent discovery (via
  # `agents:message:<slug>`).
  #
  # The warning fires every wake, which is noisy but unavoidable
  # until the Director takes action. Emitting a structured event
  # instead of a free-form log would be the right surface, but
  # requires plumbing a company-context audit seam through this
  # module — deferred as part of the next Router/audit refactor.
  # (TODO.md High #9.)
  defp permission_to_flags({"agents", "list", _scope}, _co) do
    Logger.warning(
      "permission_mapper: agents:list has no kernel-layer effect yet — " <>
        "use agents:message:<target> for inter-agent communication."
    )

    []
  end

  # tasks:update:<project> → rw-bind the project's tasks/ subdir
  defp permission_to_flags({"tasks", "update", project}, co) when project != "*" do
    ["--bind", Path.join([co, "projects", project, "tasks"]), "/projects/#{project}/tasks"]
  end

  # proposals:read:* → ro-bind whole proposals tree
  defp permission_to_flags({"proposals", "read", "*"}, co) do
    ["--ro-bind", Path.join(co, "proposals"), "/proposals"]
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
end
