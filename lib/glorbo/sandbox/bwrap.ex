defmodule Glorbo.Sandbox.Bwrap do
  @moduledoc """
  `bwrap(1)` argv composer + Port-wrapped invocation layer
  (D-08..D-13; SEC-02; SEC-03; T-03-30..T-03-32, T-03-37).

  This module owns two responsibilities:

    1. `build_argv/1` — a PURE function that composes a bwrap argv list
       from an agent's invocation opts. Used by unit tests to assert flag
       composition without touching the filesystem or forking a process.
    2. `start/2` — invokes bwrap via `Port.open/2` using a thin `/bin/sh`
       wrapper that redirects stdin from a prompt tempfile. Crash cleanup
       is kernel-guaranteed by `--unshare-pid` + `--die-with-parent`
       (RESEARCH Pitfall 1's triple-layer cleanup).

  ## Baseline sandbox (D-08)

  Every invocation drops all capabilities and enters fresh mount, pid, ipc,
  uts, user and cgroup namespaces, and wipes the inherited environment:

      --die-with-parent --unshare-user --unshare-ipc
      --unshare-pid --unshare-uts --unshare-cgroup
      --new-session --cap-drop ALL --clearenv

  `--clearenv` is load-bearing: without it the sandboxed CLI inherits the
  BEAM's env (PATH, `*_PROXY`, whatever the director's shell happened to
  export — potentially including unrelated provider tokens). The only
  env inside the sandbox is what Glorbo explicitly `--setenv`s after the
  clear — see `default_env_flags/0` for the minimal whitelist.

  ## Filesystem binds (D-09)

  Base mounts (always present):

    * `--ro-bind /usr /usr` — real directory, no symlink.
    * `--symlink usr/bin /bin`, `usr/lib /lib`, `usr/lib64 /lib64`,
      `usr/sbin /sbin` — Fedora/Bazzite merged-/usr layout (RESEARCH Pattern 1).
    * `/etc` — minimal selective mounts (`resolv.conf`, `hosts`, `passwd`,
      `group`, `nsswitch.conf`, `ssl/`, `pki/`, `ca-certificates/`) on top of
      a `--tmpfs /etc` baseline. Prevents leaking `/etc/shadow`, `/etc/sudoers`,
      `/etc/ssh/*`, `/etc/cron.*`, or any application configs into the sandbox
      (WR-04). Uses `--ro-bind-try` for distro-variant paths that may not
      exist on every host.
    * `--proc /proc`, `--dev /dev`, `--tmpfs /tmp`.

  Agent-owned:

    * `--bind <workspace> /workspace` — rw.
    * `--bind <outbox> /outbox` — rw (agent's own writes).
    * `--ro-bind <inbox> /inbox` — ro (Router-mediated, never agent-writable).

  Per-permission mounts (via `Glorbo.Sandbox.PermissionMapper`) are spliced in
  after agent-owned mounts.

  Per-agent CLI auth dirs (shared ro-bind from Director's home):

    * `cli_auth_binds :: [{host_path, sandbox_path}]` — each bound ro.

  Working dir + env:

    * `--chdir /workspace` — CLI tool runs with workspace as cwd.
    * `--setenv HOME /workspace` — isolates any HOME-relative writes.
    * `cli_env` map (from adapter) — per-provider session redirects
      (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) and optional proxy env.

  ## Network policy (D-15, D-17; GEP-23 D1 rename)

    * `:loopback` → `--unshare-net` (kernel-enforced egress block;
      bwrap creates a fresh netns with `lo` up inside it).
    * `:proxy` → launches bwrap under `pasta --splice-only -T <proxy_port>`
      so the child gets a private network namespace where only the
      Glorbo-managed proxy port is reachable on loopback. `HTTPS_PROXY`
      and `HTTP_PROXY` point at that loopback address. On Linux this is
      enforced-or-refused: if `pasta` is unavailable, the dispatch fails.
    * `:full` → inherits host netns; no proxy.

  ## Process cleanup

  Bwrap's in-kernel cleanup is sufficient for the CLI invocations we
  spawn: every invocation runs under `--unshare-pid --die-with-parent`,
  which makes bwrap pid1 inside a new pid namespace — killing pid1 reaps
  every descendant kernel-side.

    * `--die-with-parent` — if BEAM (our parent) goes away, bwrap dies.
    * `--unshare-pid` — when bwrap dies, every process in its pid
      namespace is reaped by the kernel (no re-parenting to host pid 1).

  We invoke bwrap via `Port.open({:spawn_executable, "/bin/sh"}, ...)`
  with a thin shell wrapper that reads the prompt from a tempfile
  (`exec bwrap "$@" < $prompt_file`). This closes stdin on the CLI tool
  side as soon as the file is fully consumed — every supported CLI
  (claude --print, codex exec -, gemini -p) waits for stdin EOF before
  processing the prompt (WR-05 / CR-01).

  Elixir 1.19.5's `System.cmd/3` does NOT accept an `:input` option (that
  option was never added upstream; the prior implementation raised
  `ArgumentError` at runtime). The tempfile-redirection approach is
  kernel-portable and adds no dependencies.

  Timeout enforcement: `receive` with `after timeout_s * 1_000` arms a
  one-shot guard. On timeout we send `SIGKILL` via `Port.close/1` which
  tears down the port owner; the shell wrapper's child (bwrap) gets
  `--die-with-parent` cleanup, which kernel-reaps the pid namespace.
  """
  require Logger

  alias Glorbo.Sandbox.PermissionMapper

  @type network_policy :: :loopback | :proxy | :full

  @type invocation_opts :: %{
          required(:agent_workspace) => String.t(),
          required(:inbox_path) => String.t(),
          required(:outbox_path) => String.t(),
          required(:company_path) => String.t(),
          required(:permissions) => [PermissionMapper.permission()],
          required(:network_policy) => network_policy(),
          optional(:cli_auth_binds) => [{String.t(), String.t()}],
          optional(:cli_env) => %{String.t() => String.t()},
          optional(:proxy_url) => String.t() | nil,
          optional(:proxy_port) => pos_integer(),
          optional(:timeout_seconds) => pos_integer()
        }

  @default_timeout_seconds 300

  # ---------------------------------------------------------------------------
  # Pure argv composition
  # ---------------------------------------------------------------------------

  @doc """
  Compose the full bwrap argv (WITHOUT the leading `bwrap` binary — caller
  prepends that) from the agent's invocation opts.

  Output is a flat list of strings; every list element is exactly one argv
  slot. No shell-escaping needed because `Port.open/2` with
  `{:spawn_executable, bwrap_path}` + `args:` goes through execve directly.
  """
  @spec build_argv(invocation_opts()) :: [String.t()]
  def build_argv(%{} = opts) do
    [
      baseline_flags(),
      network_flag(opts.network_policy),
      root_fs_flags(),
      agent_owned_flags(opts),
      cli_auth_bind_flags(Map.get(opts, :cli_auth_binds, [])),
      PermissionMapper.to_argv(opts.permissions, opts.company_path),
      approved_path_flags(Map.get(opts, :approved_paths, [])),
      working_dir_flags(),
      default_env_flags(),
      env_flags(opts)
    ]
    |> List.flatten()
  end

  @doc """
  Return the path to the `bwrap` binary or raise if not found.
  """
  @spec default_binary() :: String.t()
  def default_binary do
    System.find_executable("bwrap") ||
      raise "bwrap not found in PATH — install the `bubblewrap` package"
  end

  @doc """
  Non-raising probe for bwrap availability (R30).

  Returns `:ok` when bwrap is on PATH, `{:error, :unavailable}`
  otherwise. Callers that want to degrade gracefully (e.g. macOS
  hosts in pre-1.0) use this instead of `default_binary/0` — they
  run the command unsandboxed + emit a one-time warning audit.

  **This is a narrow escape hatch, not a general policy.** The
  CLAUDE.md invariant "the kernel is the policy engine" still
  holds on every host where bwrap *is* available. On macOS there
  is no kernel equivalent yet (see GEP-5 / GEP-17); unsandboxed
  execution is explicitly a pre-1.0 degradation, load-bearing on
  the warning audit so directors know.
  """
  @spec availability() :: :ok | {:error, :unavailable}
  def availability do
    if System.find_executable("bwrap"), do: :ok, else: {:error, :unavailable}
  end

  @doc """
  Non-raising probe for pasta availability.

  Linux `network: proxy` dispatches require `pasta` so the proxy path is
  enforced by a private network namespace rather than hinted by env vars.
  """
  @spec pasta_availability() :: :ok | {:error, :unavailable | :too_old}
  def pasta_availability do
    case System.find_executable("pasta") do
      nil ->
        {:error, :unavailable}

      path ->
        # GEP-31 depends on `pasta --splice-only`; older `passt` packages
        # on some distros don't know that flag. Scanning `pasta --help`
        # lets `glorbo doctor` flag the upgrade requirement cleanly
        # instead of failing at first proxy dispatch.
        try do
          case System.cmd(path, ["--help"], stderr_to_stdout: true) do
            {help, _} ->
              if String.contains?(help, "--splice-only"),
                do: :ok,
                else: {:error, :too_old}

            _ ->
              {:error, :too_old}
          end
        rescue
          _ -> {:error, :too_old}
        catch
          _, _ -> {:error, :too_old}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Baseline flags (D-08)
  # ---------------------------------------------------------------------------

  defp baseline_flags do
    [
      "--die-with-parent",
      "--unshare-user",
      "--unshare-ipc",
      "--unshare-pid",
      "--unshare-uts",
      "--unshare-cgroup",
      "--new-session",
      "--cap-drop",
      "ALL",
      "--clearenv"
    ]
  end

  # Minimum env a sandboxed CLI needs after --clearenv wipes everything.
  # `PATH` points at the root_fs_flags merged-/usr layout. `LANG`/`LC_ALL`
  # pin UTF-8 so CLI stdout round-trips through the port. `TERM=dumb`
  # suppresses ANSI escapes that would corrupt parsed replies.
  # `TMPDIR=/tmp` matches the `--tmpfs /tmp` baseline mount.
  # HOME is set separately by `working_dir_flags/0` to `/workspace`.
  defp default_env_flags do
    [
      "--setenv",
      "PATH",
      "/usr/bin:/bin",
      "--setenv",
      "LANG",
      "C.UTF-8",
      "--setenv",
      "LC_ALL",
      "C.UTF-8",
      "--setenv",
      "TERM",
      "dumb",
      "--setenv",
      "TMPDIR",
      "/tmp"
    ]
  end

  # ---------------------------------------------------------------------------
  # Network policy (D-15, D-17)
  # ---------------------------------------------------------------------------

  defp network_flag(:loopback), do: ["--unshare-net"]
  defp network_flag(:proxy), do: []
  defp network_flag(:full), do: []

  # ---------------------------------------------------------------------------
  # Root FS binds (D-09)
  # ---------------------------------------------------------------------------

  defp root_fs_flags do
    [
      "--ro-bind",
      "/usr",
      "/usr",
      "--symlink",
      "usr/bin",
      "/bin",
      "--symlink",
      "usr/lib",
      "/lib",
      "--symlink",
      "usr/lib64",
      "/lib64",
      "--symlink",
      "usr/sbin",
      "/sbin"
    ] ++
      etc_flags() ++
      [
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--tmpfs",
        "/tmp"
      ]
  end

  # WR-04: replace `--ro-bind /etc /etc` (which leaks /etc/shadow, /etc/sudoers,
  # /etc/ssh/*, /etc/cron.*, and every installed app config) with a tmpfs
  # baseline + selective mounts of only the files the CLI tools actually need
  # (TLS trust, DNS, user-group lookup). `--ro-bind-try` is used for paths
  # that are distro-variant (Fedora ships /etc/pki, Debian uses
  # /etc/ca-certificates) and silently skips when missing — no crash on a
  # host that only has one of the two.
  defp etc_flags do
    [
      "--tmpfs",
      "/etc",
      "--ro-bind",
      "/etc/resolv.conf",
      "/etc/resolv.conf",
      "--ro-bind",
      "/etc/hosts",
      "/etc/hosts",
      "--ro-bind",
      "/etc/nsswitch.conf",
      "/etc/nsswitch.conf",
      "--ro-bind",
      "/etc/passwd",
      "/etc/passwd",
      "--ro-bind",
      "/etc/group",
      "/etc/group",
      "--ro-bind-try",
      "/etc/ssl",
      "/etc/ssl",
      "--ro-bind-try",
      "/etc/pki",
      "/etc/pki",
      "--ro-bind-try",
      "/etc/ca-certificates",
      "/etc/ca-certificates",
      "--ro-bind-try",
      "/etc/ca-certificates.conf",
      "/etc/ca-certificates.conf"
    ]
  end

  # ---------------------------------------------------------------------------
  # Agent-owned dirs
  # ---------------------------------------------------------------------------

  defp agent_owned_flags(%{agent_workspace: ws, inbox_path: inbox, outbox_path: outbox}) do
    [
      "--bind",
      ws,
      "/workspace",
      # Canonical `/outbox` mount.
      "--bind",
      outbox,
      "/outbox",
      # Alias `/workspace/outbox` → same host outbox dir. Opencode's
      # Write tool is cwd-scoped and silently rewrites absolute
      # `/outbox/...` paths to cwd-relative `outbox/...`, which
      # lands in `<workspace>/outbox/` without this alias. With the
      # alias, writes to either path hit the real outbox and the
      # Router picks them up.
      "--bind",
      outbox,
      "/workspace/outbox",
      "--ro-bind",
      inbox,
      "/inbox"
    ]
  end

  # ---------------------------------------------------------------------------
  # CLI auth binds (Option 2 from RESEARCH Runtime State Inventory)
  # ---------------------------------------------------------------------------

  defp cli_auth_bind_flags(binds) when is_list(binds) do
    Enum.flat_map(binds, fn
      {host, sandbox, mode, :dir} ->
        :ok = assert_valid_auth_bind_paths!(host, sandbox)
        ["--dir", sandbox] ++ bind_flag(host, sandbox, mode)

      {host, sandbox, mode, _type} ->
        :ok = assert_valid_auth_bind_paths!(host, sandbox)
        bind_flag(host, sandbox, mode)

      {host, sandbox, mode} ->
        :ok = assert_valid_auth_bind_paths!(host, sandbox)
        bind_flag(host, sandbox, mode)

      {host, sandbox} ->
        :ok = assert_valid_auth_bind_paths!(host, sandbox)
        bind_flag(host, sandbox, :ro)
    end)
  end

  defp bind_flag(host, sandbox, :rw), do: ["--bind", host, sandbox]
  defp bind_flag(host, sandbox, _), do: ["--ro-bind", host, sandbox]

  # Defense-in-depth for the auth-bind argv slot (codex deep-dive F1).
  # Loader.parse_auth_binds only validates `mode`; `host` and `sandbox`
  # flow into argv unchecked. A config-influencer (untrusted provider
  # registry contribution, copy-paste from a 3rd-party config, etc.)
  # could mount `host="/"` at `sandbox="/workspace/.creds"`, exfiltrating
  # the entire host FS through the sandbox surface; or `sandbox="/etc"`
  # to shadow system mounts. Both paths are gated below: absolute, no
  # `..`, no NUL/control bytes, and neither EXACTLY matches a critical
  # mount point that a bind would shadow.
  defp assert_valid_auth_bind_paths!(host, sandbox) do
    :ok = assert_valid_auth_bind_host!(host)
    :ok = assert_valid_auth_bind_sandbox!(sandbox)
    :ok
  end

  # Hosts: mounting any of these as the bind SOURCE either drags
  # the entire host FS into the namespace (`/`) or pulls in dirs
  # that should never be agent-readable (root home, system
  # configs, kernel surfaces, etc.). Identified by Copilot review
  # on PR #27.
  @forbidden_host_exact ~w(
    / /root /etc /proc /sys /dev /boot /home /lib /lib64
  )

  defp assert_valid_auth_bind_host!(path) when is_binary(path) do
    cond do
      contains_control_char?(path) ->
        raise ArgumentError,
              "cli_auth_bind_flags: host must not contain control bytes " <>
                "(NUL, CR, LF, etc.), got #{inspect(path)}"

      not String.starts_with?(path, "/") ->
        raise ArgumentError,
              "cli_auth_bind_flags: host must be absolute (tilde-expanded), " <>
                "got #{inspect(path)}"

      String.contains?(path, "/../") or String.ends_with?(path, "/..") ->
        raise ArgumentError,
              "cli_auth_bind_flags: host must not contain `..`, got #{inspect(path)}"

      normalise_path(path) in @forbidden_host_exact ->
        raise ArgumentError,
              "cli_auth_bind_flags: host must not be a critical system root, " <>
                "got #{inspect(path)}"

      true ->
        :ok
    end
  end

  defp assert_valid_auth_bind_host!(other) do
    raise ArgumentError,
          "cli_auth_bind_flags: host must be a string, got #{inspect(other)}"
  end

  # Sandbox is the path INSIDE the bwrap namespace where the host
  # path gets mounted. Shape + critical-mount-point denylist.
  # `normalise_path/1` strips trailing slashes and `/.` so
  # `/workspace`, `/workspace/`, `/workspace/.` are all caught by
  # the same denylist entry. (Copilot review on PR #27.)
  @forbidden_sandbox_exact ~w(
    / /workspace /inbox /outbox /usr /etc /proc /sys /dev /run
    /bin /sbin /lib /lib64 /var /root /home /boot /tmp
  )

  defp assert_valid_auth_bind_sandbox!(path) when is_binary(path) do
    cond do
      contains_control_char?(path) ->
        raise ArgumentError,
              "cli_auth_bind_flags: sandbox must not contain control bytes " <>
                "(NUL, CR, LF, etc.), got #{inspect(path)}"

      not String.starts_with?(path, "/") ->
        raise ArgumentError,
              "cli_auth_bind_flags: sandbox must be absolute, got #{inspect(path)}"

      String.contains?(path, "/../") or String.ends_with?(path, "/..") ->
        raise ArgumentError,
              "cli_auth_bind_flags: sandbox must not contain `..`, got #{inspect(path)}"

      normalise_path(path) in @forbidden_sandbox_exact ->
        raise ArgumentError,
              "cli_auth_bind_flags: sandbox must not exactly shadow a critical " <>
                "mount point, got #{inspect(path)}"

      true ->
        :ok
    end
  end

  defp assert_valid_auth_bind_sandbox!(other) do
    raise ArgumentError,
          "cli_auth_bind_flags: sandbox must be a string, got #{inspect(other)}"
  end

  # Catch bypass variants like `/workspace/`, `/workspace/.`, that
  # the OS would resolve to the same mount as bare `/workspace`. Strip
  # trailing slashes and `/.` segments so the denylist check is
  # canonical. (Copilot review on PR #27.)
  defp normalise_path(path) do
    path
    |> String.replace_suffix("/.", "")
    |> String.trim_trailing("/")
    |> case do
      "" -> "/"
      normalised -> normalised
    end
  end

  # Reject NUL, all C0 control codes (0x00..0x1F), and DEL (0x7F).
  # Bare argv slots don't need CR/LF for header smuggling but they
  # corrupt logs + are never legitimate in filesystem paths. Mirrors
  # the validation surface advertised by the comment block above.
  defp contains_control_char?(s) when is_binary(s) do
    Enum.any?(0..0x1F, &String.contains?(s, <<&1>>)) or String.contains?(s, <<0x7F>>)
  end

  # ---------------------------------------------------------------------------
  # GEP-27: approved external path mounts
  # ---------------------------------------------------------------------------

  @doc """
  Generate bwrap mount flags for approved external paths (GEP-27).

  Each approved path is mounted under `/external/<basename>`:
    - read mode → `--ro-bind`
    - write mode → `--bind`

  Returns a flat list of strings for splicing into `build_argv/1`.
  """
  @spec approved_path_flags([map()]) :: [String.t()]
  def approved_path_flags(paths) when is_list(paths) do
    Enum.flat_map(paths, fn %{host_path: host, sandbox_path: sandbox, mode: mode} ->
      # Defense-in-depth: PathRequestGate already validates these on
      # approval + store, but the argv slot is load-bearing (a
      # `../` in sandbox_path would mount at an unintended location;
      # a non-absolute host_path would mean whatever pwd the bwrap
      # process happens to be in). Opencode round-3 flagged the
      # unchecked pass-through.
      :ok = assert_valid_grant_path!(host, :host_path)
      :ok = assert_valid_sandbox_path!(sandbox)

      flag = if mode == :write, do: "--bind", else: "--ro-bind"
      [flag, host, sandbox]
    end)
  end

  def approved_path_flags(_), do: []

  # host_path must be an absolute path with no `..` segments so
  # bwrap's `--bind` / `--ro-bind` can't accidentally resolve
  # somewhere unintended.
  defp assert_valid_grant_path!(path, kind) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") ->
        raise ArgumentError,
              "approved_path_flags: #{kind} must be absolute, got #{inspect(path)}"

      String.contains?(path, "/../") or String.ends_with?(path, "/..") ->
        raise ArgumentError,
              "approved_path_flags: #{kind} must not contain `..`, got #{inspect(path)}"

      true ->
        :ok
    end
  end

  defp assert_valid_grant_path!(_, kind) do
    raise ArgumentError, "approved_path_flags: #{kind} must be a string"
  end

  # sandbox_path is where bwrap mounts the grant INSIDE the namespace.
  # Must live under /external/ so it can't overlap a system mount
  # (`/usr`, `/etc`, `/workspace`) and can't traverse (`..`).
  defp assert_valid_sandbox_path!(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/external/") ->
        raise ArgumentError,
              "approved_path_flags: sandbox_path must live under /external/, got #{inspect(path)}"

      String.contains?(path, "/../") or String.ends_with?(path, "/..") ->
        raise ArgumentError,
              "approved_path_flags: sandbox_path must not contain `..`, got #{inspect(path)}"

      true ->
        :ok
    end
  end

  defp assert_valid_sandbox_path!(_) do
    raise ArgumentError, "approved_path_flags: sandbox_path must be a string"
  end

  # ---------------------------------------------------------------------------
  # Working dir + env
  # ---------------------------------------------------------------------------

  defp working_dir_flags do
    [
      "--chdir",
      "/workspace",
      "--setenv",
      "HOME",
      "/workspace"
    ]
  end

  defp env_flags(opts) do
    cli_env = Map.get(opts, :cli_env, %{})
    proxy_env = proxy_env_for(opts)

    (Map.to_list(cli_env) ++ proxy_env)
    |> Enum.flat_map(fn {k, v} ->
      unless safe_env?(k, v) do
        raise ArgumentError,
              "unsafe env var (control chars / reserved bytes): #{inspect({k, v})}"
      end

      ["--setenv", k, v]
    end)
  end

  # WR-07: refuse env vars whose keys or values contain execve-hostile bytes.
  # `\0` truncates silently in execve; `\n` and `\r` would persist through to
  # any future shell consumer of the var (e.g. `echo "$HTTPS_PROXY"`); `=` in
  # a key is ambiguous under bwrap's --setenv parsing. Keys must also match
  # POSIX env-var name shape (no leading digit, alphanum + underscore only)
  # so a future adapter cannot feed in something like `PATH\tinjected`.
  defp safe_env?(k, v) when is_binary(k) and is_binary(v) do
    valid_key?(k) and not String.contains?(v, ["\0", "\n", "\r"])
  end

  defp safe_env?(_, _), do: false

  defp valid_key?(""), do: false

  defp valid_key?(k) do
    Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, k)
  end

  defp proxy_env_for(%{network_policy: :proxy, proxy_url: url}) when is_binary(url) do
    [{"HTTPS_PROXY", url}, {"HTTP_PROXY", url}]
  end

  defp proxy_env_for(_opts), do: []

  # ---------------------------------------------------------------------------
  # start/2 — MuonTrap-wrapped invocation
  # ---------------------------------------------------------------------------

  @type run_opts :: [
          cli_binary: String.t(),
          cli_args: [String.t()],
          prompt: String.t(),
          stdout_log: String.t() | nil,
          bwrap_binary: String.t(),
          usage_dir: String.t() | nil
        ]

  @type start_result ::
          {:ok, %{exit_status: integer(), stdout: binary(), usage_dir: String.t() | nil}}
          | {:error, term()}

  @doc """
  Spawn a sandboxed ACP-mode CLI as a long-running Port.

  Differs from `start/2` in two ways (GEP-45 Phase 1b sub-slice 1b.5):

    * No prompt tempfile, no `< $prompt_file` redirect — ACP carries the
      prompt as a JSON-RPC `session/prompt` request over the child's
      stdin, so stdin must remain open and writable.
    * Returns the live `Port` instead of waiting on exit. The caller
      (the ACP client state machine, wrapped via
      `Glorbo.CLI.Dispatcher.Acp.PortIO.wrap/1`) drives the conversation
      via `Port.command/2` + receive, then closes the port when done.

  stderr is currently routed to `/dev/null` inside the launcher so it
  cannot corrupt the JSON-RPC stream on stdout. Open question 1 in
  GEP-45 covers a future polish: drain stderr concurrently into the
  agent's stdout-tail file.

  Required `run_opts`:

    * `:cli_binary` — absolute path to the ACP-capable binary (e.g.
      `/tmp/glorbo-cli-stado-stado` after the auth-bind hop).
    * `:cli_args` — argv after the binary; for stado typically
      `["acp", "--tools"]`.
    * `:bwrap_binary` (optional) — overrides PATH lookup, used by
      tests injecting a fake bwrap.
  """
  @spec start_acp(invocation_opts(), run_opts()) :: {:ok, port()} | {:error, term()}
  def start_acp(%{} = opts, run_opts) when is_list(run_opts) do
    with {:ok, normalized_opts} <- normalize_proxy_opts(opts) do
      bwrap_bin = Keyword.get(run_opts, :bwrap_binary, default_binary())
      cli_bin = Keyword.fetch!(run_opts, :cli_binary)
      cli_args = Keyword.get(run_opts, :cli_args, [])

      argv = build_argv(normalized_opts) ++ ["--", cli_bin] ++ cli_args

      open_acp_port(bwrap_bin, argv, normalized_opts)
    end
  end

  defp open_acp_port(bwrap_bin, argv, opts) do
    sh_path = System.find_executable("sh") || "/bin/sh"

    # Symmetric to `do_run_via_port/7`'s shell wrapper but without the
    # stdin redirect: bwrap inherits the port's stdin (so JSON-RPC
    # frames written via Port.command/2 reach the ACP server), stdout
    # is piped back through the port, stderr is dropped to /dev/null so
    # the JSON-RPC stream cannot be corrupted by status lines.
    sh_script = ~s|b="$1"; shift; exec "$b" "$@" 2>/dev/null|
    sh_args = ["-c", sh_script, "glorbo-bwrap-acp", bwrap_bin | argv]

    with {:ok, launcher_bin, launcher_args} <- launcher_spec(opts, sh_path, sh_args) do
      port_opts = [
        :binary,
        :exit_status,
        :hide,
        # Default for `Port.open/2` is to attach stdin/stdout to the
        # spawned process via the BEAM's socket pair — exactly what we
        # want for ACP. Do NOT set `:stderr_to_stdout`; the launcher
        # already redirects stderr to /dev/null.
        {:args, launcher_args}
      ]

      port = Port.open({:spawn_executable, launcher_bin}, port_opts)
      {:ok, port}
    end
  end

  @doc """
  Launch the sandboxed CLI invocation via `Port.open/2` + `/bin/sh` wrapper.

  Blocks until the CLI exits or the timeout elapses. Returns
  `{:ok, %{exit_status, stdout, usage_dir}}` on clean exit;
  `{:error, term()}` on start failure.

  The prompt is written to a tempfile, then `/bin/sh -c 'exec bwrap "$@" <
  $prompt_file'` is spawned. The stdin redirection ensures bwrap's child
  CLI sees a finite stream that EOFs after the prompt is fully consumed.

  **`stdout` in the result:** stderr is merged into stdout via
  `:stderr_to_stdout`. For usage-telemetry parsing, callers should rely
  on the CLI's session-dir telemetry (via `usage_dir`) rather than stdout
  content.
  """
  @spec start(invocation_opts(), run_opts()) :: start_result()
  def start(%{} = opts, run_opts) when is_list(run_opts) do
    with {:ok, normalized_opts} <- normalize_proxy_opts(opts) do
      bwrap_bin = Keyword.get(run_opts, :bwrap_binary, default_binary())
      cli_bin = Keyword.fetch!(run_opts, :cli_binary)
      cli_args = Keyword.get(run_opts, :cli_args, [])
      prompt = Keyword.get(run_opts, :prompt, "")
      usage_dir = Keyword.get(run_opts, :usage_dir)
      stdout_log = Keyword.get(run_opts, :stdout_log)
      timeout_s = Map.get(normalized_opts, :timeout_seconds, @default_timeout_seconds)

      argv = build_argv(normalized_opts) ++ ["--", cli_bin] ++ cli_args

      run_via_port(bwrap_bin, argv, prompt, timeout_s, usage_dir, stdout_log, normalized_opts)
    end
  end

  # Invoke bwrap via a `/bin/sh -c 'exec bwrap "$@" < prompt_file'` wrapper.
  #
  # Why this shape:
  #   * `Port.open` sends `Port.command/2` data to the child's stdin but
  #     `Port.close/1` closes BOTH halves of the port simultaneously — there
  #     is no clean way in pure Elixir/Erlang to signal EOF on the child's
  #     stdin without also tearing down stdout.
  #   * The CLI tools we dispatch (claude --print, codex exec -, gemini -p)
  #     block until stdin EOFs (CR-01).
  #   * Tempfile + shell redirection (`< $prompt_file`) gives us kernel-level
  #     stdin EOF as soon as the file's end is reached, while keeping the
  #     port's stdout channel open for us to drain.
  #
  # Cleanup guarantees:
  #   * `--die-with-parent` in the bwrap baseline (D-08) causes bwrap to
  #     self-terminate when its parent (the sh wrapper) dies.
  #   * `--unshare-pid` makes bwrap pid1 of its own namespace; when bwrap
  #     exits, the kernel reaps every descendant in the namespace.
  #   * On timeout we close the port; the sh wrapper dies; bwrap follows.
  #
  # The prompt tempfile is deleted via `File.rm/1` in an after-clause so the
  # cleanup runs on both normal exit and exception paths.
  defp run_via_port(bwrap_bin, argv, prompt, timeout_s, usage_dir, stdout_log, opts) do
    case write_prompt_tempfile(prompt) do
      {:ok, prompt_file} ->
        try do
          do_run_via_port(bwrap_bin, argv, prompt_file, timeout_s, usage_dir, stdout_log, opts)
        after
          _ = File.rm(prompt_file)
        end

      {:error, reason} ->
        {:error, {:prompt_tempfile_failed, reason}}
    end
  end

  defp write_prompt_tempfile(prompt) when is_binary(prompt) do
    # Threatmodel: previous implementation used
    # `glorbo_bwrap_prompt_<monotonic_integer>` which is predictable
    # — an attacker watching `/tmp` could pre-plant a symlink at the
    # next-integer name and redirect File.write to clobber an
    # arbitrary file. Two layers of defence:
    #
    #   1. Add a per-call random suffix so the path can't be predicted
    #      from one BEAM-process observation.
    #   2. Open with `[:exclusive]` so :file.open returns {:error,
    #      :eexist} if the path already exists (refuses to follow a
    #      pre-planted symlink, even if the random suffix collided).
    #
    # The exclusive-create + 8-byte random suffix together turn the
    # vector from "race attacker against monotonic counter" into
    # "guess 2^64 random bytes between mktemp and open" — well past
    # exploitable.
    rand_suffix =
      :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    path =
      Path.join(
        System.tmp_dir!(),
        "glorbo_bwrap_prompt_#{System.unique_integer([:positive, :monotonic])}_#{rand_suffix}"
      )

    case :file.open(path, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} ->
        try do
          case :file.write(fd, prompt) do
            :ok ->
              :ok = :file.close(fd)
              # Set 0600 so other local users can't read the prompt
              # while it's on disk.
              _ = File.chmod(path, 0o600)
              {:ok, path}

            {:error, reason} ->
              :ok = :file.close(fd)
              _ = File.rm(path)
              {:error, reason}
          end
        rescue
          _ ->
            _ = File.rm(path)
            {:error, :write_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_run_via_port(bwrap_bin, argv, prompt_file, timeout_s, usage_dir, stdout_log, opts) do
    sh_path = System.find_executable("sh") || "/bin/sh"

    # The shell script:
    #   bwrap_bin="$1"; prompt_file="$2"; shift 2; exec "$bwrap_bin" "$@" < "$prompt_file"
    # - positional arg 1 = bwrap binary
    # - positional arg 2 = prompt file
    # - positional args 3+ = bwrap argv
    # Using `exec` makes sh replace itself with bwrap (tighter parent/child
    # relationship for --die-with-parent). POSIX-only — `${@:3}` is a
    # bash-ism that dash (Ubuntu's /bin/sh) rejects with "Bad substitution".
    sh_script = ~s|b="$1"; p="$2"; shift 2; exec "$b" "$@" < "$p"|

    sh_args = ["-c", sh_script, "glorbo-bwrap-launcher", bwrap_bin, prompt_file | argv]

    with {:ok, launcher_bin, launcher_args} <- launcher_spec(opts, sh_path, sh_args) do
      port_opts = [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, launcher_args}
      ]

      port = Port.open({:spawn_executable, launcher_bin}, port_opts)

      tee_io = open_stdout_tee(stdout_log)
      write_tee_header(tee_io)

      try do
        case drain_port(port, timeout_s, <<>>, tee_io) do
          {:ok, exit_status, output} ->
            write_tee_footer(tee_io, exit_status)
            {:ok, %{exit_status: exit_status, stdout: output, usage_dir: usage_dir}}

          {:error, :timeout} ->
            Logger.warning("bwrap invocation exceeded #{timeout_s}s — brutal_kill issued")
            safe_port_close(port)
            {:error, :timeout}

          {:error, reason} ->
            safe_port_close(port)
            {:error, reason}
        end
      after
        close_stdout_tee(tee_io)
      end
    end
  end

  defp launcher_spec(%{network_policy: :proxy, proxy_port: proxy_port}, sh_path, sh_args)
       when is_integer(proxy_port) and proxy_port > 0 do
    with :ok <- pasta_availability(),
         {:ok, pasta_bin} <- fetch_pasta_binary(),
         {:ok, runas} <- current_uid_gid() do
      {:ok, pasta_bin,
       [
         "-q",
         "-f",
         "--runas",
         runas,
         "--splice-only",
         "-t",
         "none",
         "-u",
         "none",
         "-T",
         Integer.to_string(proxy_port),
         "-U",
         "none",
         "--",
         sh_path
         | sh_args
       ]}
    end
  end

  defp launcher_spec(_opts, sh_path, sh_args), do: {:ok, sh_path, sh_args}

  defp fetch_pasta_binary do
    case System.find_executable("pasta") do
      nil -> {:error, :unavailable}
      path -> {:ok, path}
    end
  end

  defp current_uid_gid do
    with {:ok, uid} <- current_id_value("-u"),
         {:ok, gid} <- current_id_value("-g") do
      {:ok, "#{uid}:#{gid}"}
    end
  end

  defp current_id_value(flag) do
    case System.cmd("id", [flag], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, code} ->
        {:error, {:id_lookup_failed, "#{flag} exit #{code}: #{String.trim(output)}"}}
    end
  rescue
    e -> {:error, {:id_lookup_failed, Exception.message(e)}}
  end

  defp normalize_proxy_opts(%{network_policy: :proxy, proxy_url: url} = opts)
       when is_binary(url) do
    case parse_proxy_url(url) do
      {:ok, canonical_url, port} ->
        {:ok, opts |> Map.put(:proxy_url, canonical_url) |> Map.put(:proxy_port, port)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_proxy_opts(%{network_policy: :proxy}), do: {:error, :proxy_url_missing}
  defp normalize_proxy_opts(opts), do: {:ok, opts}

  defp parse_proxy_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "http" ->
        {:error, {:invalid_proxy_url, url}}

      uri.host not in ["127.0.0.1", "localhost"] ->
        {:error, {:invalid_proxy_url, url}}

      not is_integer(uri.port) or uri.port <= 0 ->
        {:error, {:invalid_proxy_url, url}}

      uri.query not in [nil, ""] ->
        {:error, {:invalid_proxy_url, url}}

      uri.fragment not in [nil, ""] ->
        {:error, {:invalid_proxy_url, url}}

      uri.path not in [nil, "", "/"] ->
        {:error, {:invalid_proxy_url, url}}

      true ->
        # GEP-23 Phase 5 embeds a per-dispatch auth token in the proxy
        # URL's userinfo (`http://<token>@127.0.0.1:<port>`); the
        # sandboxed CLI must carry it through to `HTTPS_PROXY` so its
        # CONNECT sends `Proxy-Authorization`. Preserve the userinfo
        # (host normalised to 127.0.0.1); only the bare `:proxy_port`
        # is used for the network-namespace egress rule.
        {:ok, canonical_proxy_url(uri), uri.port}
    end
  end

  defp canonical_proxy_url(%URI{userinfo: info, port: port}) when is_binary(info) and info != "",
    do: "http://#{info}@127.0.0.1:#{port}"

  defp canonical_proxy_url(%URI{port: port}), do: "http://127.0.0.1:#{port}"

  # Open an append-mode file handle for the agent's stdout.log. nil
  # stdout_log → nil IO (drain_port skips writes). Directory
  # mkdir_p!'d just in case (e.g. fresh-scaffolded agent whose
  # workspace sibling dirs exist but the slot has been deleted).
  defp open_stdout_tee(nil), do: nil

  defp open_stdout_tee(path) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))

    # Codex deep-dive F7: `File.open(path, [:append, ...])` follows
    # symlinks. The agent has write access to its own workspace + stdout
    # slot (`agents/<slug>/stdout.log`), so a pre-planted symlink there
    # could redirect host-side appends to any path the BEAM process can
    # write (e.g. `/tmp/glorbo.pid`, `~/.bashrc`, the operator's audit
    # log). Reuse `AgentWritableFile.ensure_writable/1` (refuses non-
    # regular existing files; permits `:enoent` so the open below
    # creates the file). Residual TOCTOU between lstat and open is
    # acceptably narrow given that (a) the primary defense is the
    # workspace bind layout — the agent can't redirect the LOG slot
    # from inside the sandboxed namespace, only from a prior dispatch
    # — and (b) Erlang doesn't expose `O_NOFOLLOW` for an O_APPEND
    # open. (Copilot review on PR #30.)
    case Glorbo.Filesystem.AgentWritableFile.ensure_writable(path) do
      :ok ->
        do_open_stdout_tee(path)

      {:error, {:not_regular_file, type}} ->
        Logger.warning(
          "stdout_log refused path=#{path} type=#{inspect(type)} " <>
            "(only regular files / nonexistent paths are tee'd)"
        )

        nil

      {:error, reason} ->
        Logger.warning("stdout_log refused path=#{path} reason=#{inspect(reason)}")
        nil
    end
  end

  defp do_open_stdout_tee(path) do
    case File.open(path, [:append, :binary]) do
      {:ok, io} ->
        io

      {:error, reason} ->
        Logger.warning("stdout_log open failed path=#{path} reason=#{inspect(reason)}")
        nil
    end
  end

  defp write_tee_header(nil), do: :ok

  defp write_tee_header(io) do
    IO.binwrite(io, "\n=== glorbo dispatch #{DateTime.utc_now() |> DateTime.to_iso8601()} ===\n")
  end

  defp write_tee_footer(nil, _status), do: :ok

  defp write_tee_footer(io, status) do
    IO.binwrite(io, "\n=== exit #{status} ===\n")
  end

  defp close_stdout_tee(nil), do: :ok
  defp close_stdout_tee(io), do: File.close(io)

  # Cap accumulated stdout/stderr at 16 MiB. A runaway CLI writing GBs
  # to stdout/stderr would otherwise balloon BEAM heap during the drain
  # loop — once the cap is hit, subsequent chunks are discarded but the
  # port is allowed to run to completion so the CLI's exit code still
  # surfaces (TODO.md Minor #5).
  @stdout_cap 16 * 1024 * 1024

  # C-103: per-dispatch ceiling on bytes written to the agent's
  # `stdout.log` tee. The in-memory `@stdout_cap` only bounds the BEAM
  # return value; without a disk cap a malicious/runaway agent could
  # append unbounded output (append mode, persists across dispatches)
  # and fill the host filesystem. Mirror the 16 MiB in-memory cap on
  # disk: once hit, stop teeing and write a single truncation marker
  # while the port runs to completion.
  @tee_cap 16 * 1024 * 1024

  # Receive-loop over the port: accumulate stdout/stderr data until the
  # `{port, {:exit_status, status}}` message arrives OR the timeout fires.
  # When `tee_io` is non-nil (task #131), every chunk also appends to the
  # agent's `stdout.log` so the dashboard STDOUT tab + `glorbo logs` CLI
  # see live output, not just the post-exit capture.
  #
  # C-103: the receive deadline is an ABSOLUTE monotonic deadline
  # computed once at loop entry, not an `after timeout_s*1000` that
  # resets on every chunk. A continuously-chatty process is therefore
  # bounded by the agent's `timeout_seconds` rather than able to refresh
  # the timer indefinitely. `tee_written` tracks bytes appended to the
  # tee file so we can cap it per dispatch.
  defp drain_port(port, timeout_s, acc, tee_io) do
    deadline_mono = System.monotonic_time(:millisecond) + timeout_s * 1_000
    drain_port_loop(port, deadline_mono, acc, tee_io, 0)
  end

  defp drain_port_loop(port, deadline_mono, acc, tee_io, tee_written) do
    remaining_ms = max(deadline_mono - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        tee_written = tee_write(tee_io, chunk, tee_written)

        new_acc =
          if byte_size(acc) >= @stdout_cap, do: acc, else: acc <> chunk

        drain_port_loop(port, deadline_mono, new_acc, tee_io, tee_written)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc}
    after
      remaining_ms ->
        {:error, :timeout}
    end
  end

  # C-103: cap total bytes written to the tee file per dispatch. Returns
  # the updated written-byte count. Once the cap is reached, append a
  # one-shot truncation marker (the first time only) and stop writing;
  # subsequent chunks are dropped from the file but still drained from
  # the port so the exit code surfaces.
  defp tee_write(nil, _chunk, written), do: written

  defp tee_write(_io, _chunk, written) when written >= @tee_cap, do: written

  defp tee_write(io, chunk, written) do
    remaining = @tee_cap - written

    # NOTE: use `<` (not `<=`) so a chunk that lands EXACTLY on the cap
    # boundary still takes the truncation branch and emits the marker.
    # The BEAM port delivers stdout in power-of-2-sized chunks, so a
    # 16 MiB cap is frequently hit exactly on a chunk boundary; with `<=`
    # the marker was never written in that case (the next chunk hit the
    # `>= @tee_cap` guard and was dropped silently) — a CI-only flake.
    if byte_size(chunk) < remaining do
      IO.binwrite(io, chunk)
      written + byte_size(chunk)
    else
      # Write what fits, then a one-shot truncation marker, then go silent.
      IO.binwrite(io, binary_part(chunk, 0, remaining))

      IO.binwrite(
        io,
        "\n=== stdout.log truncated: per-dispatch #{@tee_cap}-byte cap reached ===\n"
      )

      @tee_cap
    end
  end

  defp safe_port_close(port) do
    try do
      true = Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end
end
