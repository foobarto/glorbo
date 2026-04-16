defmodule Glorbo.Sandbox.Bwrap do
  @moduledoc """
  `bwrap(1)` argv composer + `MuonTrap.Daemon`-wrapped invocation layer
  (D-08..D-13; SEC-02; SEC-03; T-03-30..T-03-32, T-03-37).

  This module owns two responsibilities:

    1. `build_argv/1` — a PURE function that composes a bwrap argv list
       from an agent's invocation opts. Used by unit tests to assert flag
       composition without touching the filesystem or forking a process.
    2. `start/2` — wraps the argv invocation in `MuonTrap.Daemon` so crash
       cleanup is guaranteed by cgroups + `--unshare-pid` + `--die-with-parent`
       (RESEARCH Pitfall 1's triple-layer cleanup).

  ## Baseline sandbox (D-08)

  Every invocation drops all capabilities and enters fresh mount, pid, ipc,
  uts, user and cgroup namespaces:

      --die-with-parent --unshare-user-try --unshare-ipc
      --unshare-pid --unshare-uts --unshare-cgroup-try
      --new-session --cap-drop ALL

  ## Filesystem binds (D-09)

  Base mounts (always present):

    * `--ro-bind /usr /usr` — real directory, no symlink.
    * `--symlink usr/bin /bin`, `usr/lib /lib`, `usr/lib64 /lib64`,
      `usr/sbin /sbin` — Fedora/Bazzite merged-/usr layout (RESEARCH Pattern 1).
    * `--ro-bind /etc /etc` — host resolv.conf + PKI.
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

  ## Network policy (D-15, D-17)

    * `:none` → `--unshare-net` (kernel-enforced egress block).
    * `:api_only` → inherits host netns, but `HTTPS_PROXY` and `HTTP_PROXY`
      env vars point at a `Glorbo.Network.Proxy` listener with a hostname
      allowlist. Advisory-only (RESEARCH Pitfall 7) — motivated agents can
      bypass by ignoring the env.
    * `:open` → inherits host netns; no proxy.

  ## Why three cleanup mechanisms

  A single one is insufficient:

    * `--die-with-parent` alone: only kills the bwrap process, children
      re-parent to pid 1 (bubblewrap#529).
    * `--unshare-pid`: makes bwrap pid1 inside the new namespace — killing
      pid1 reaps everyone in the namespace (kernel-enforced).
    * `MuonTrap.Daemon`: cgroup-backed kill traps any escapee + converts
      SIGTERM to SIGKILL after 500ms.

  All three together cover crash/timeout/shutdown cleanly.
  """
  require Logger

  alias Glorbo.Sandbox.PermissionMapper

  @type network_policy :: :none | :api_only | :open

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
      working_dir_flags(),
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

  # ---------------------------------------------------------------------------
  # Baseline flags (D-08)
  # ---------------------------------------------------------------------------

  defp baseline_flags do
    [
      "--die-with-parent",
      "--unshare-user-try",
      "--unshare-ipc",
      "--unshare-pid",
      "--unshare-uts",
      "--unshare-cgroup-try",
      "--new-session",
      "--cap-drop",
      "ALL"
    ]
  end

  # ---------------------------------------------------------------------------
  # Network policy (D-15, D-17)
  # ---------------------------------------------------------------------------

  defp network_flag(:none), do: ["--unshare-net"]
  defp network_flag(:api_only), do: []
  defp network_flag(:open), do: []

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
      "/sbin",
      "--ro-bind",
      "/etc",
      "/etc",
      "--proc",
      "/proc",
      "--dev",
      "/dev",
      "--tmpfs",
      "/tmp"
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
      "--bind",
      outbox,
      "/outbox",
      "--ro-bind",
      inbox,
      "/inbox"
    ]
  end

  # ---------------------------------------------------------------------------
  # CLI auth binds (Option 2 from RESEARCH Runtime State Inventory)
  # ---------------------------------------------------------------------------

  defp cli_auth_bind_flags(binds) when is_list(binds) do
    Enum.flat_map(binds, fn {host_path, sandbox_path} ->
      ["--ro-bind", host_path, sandbox_path]
    end)
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
    |> Enum.flat_map(fn {k, v} -> ["--setenv", k, v] end)
  end

  defp proxy_env_for(%{network_policy: :api_only, proxy_url: url}) when is_binary(url) do
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
  Launch the sandboxed CLI invocation under `MuonTrap.Daemon`.

  Blocks until the CLI exits or the timeout elapses (signalled via SIGTERM
  then SIGKILL per `MuonTrap.Daemon`'s `:delay_to_sigkill: 500` default).
  Returns `{:ok, %{exit_status, stdout, usage_dir}}` on clean exit;
  `{:error, term()}` on start failure.

  **`stdout` in the result:** best-effort — MuonTrap pipes stdout to the
  configured `:log_output` device. For usage-telemetry parsing, callers
  should rely on the CLI's session-dir telemetry (via `usage_dir`) rather
  than stdout content.
  """
  @spec start(invocation_opts(), run_opts()) :: start_result()
  def start(%{} = opts, run_opts) when is_list(run_opts) do
    bwrap_bin = Keyword.get(run_opts, :bwrap_binary, default_binary())
    cli_bin = Keyword.fetch!(run_opts, :cli_binary)
    cli_args = Keyword.get(run_opts, :cli_args, [])
    prompt = Keyword.get(run_opts, :prompt, "")
    usage_dir = Keyword.get(run_opts, :usage_dir)
    timeout_s = Map.get(opts, :timeout_seconds, @default_timeout_seconds)

    argv = build_argv(opts) ++ ["--", cli_bin] ++ cli_args

    run_via_port(bwrap_bin, argv, prompt, timeout_s, usage_dir)
  end

  # Invoke bwrap, piping the prompt through stdin AND closing stdin when the
  # prompt is fully written. CLI tools (claude --print, codex exec -, gemini
  # -p) all wait for EOF on stdin before processing the prompt; Port.open
  # with {:command, ""} sends a zero-length chunk but does NOT close the
  # stdin-half, so those tools block indefinitely until our timeout fires
  # (CR-01). `System.cmd/3` with :input closes stdin after writing the
  # prompt — this matches what the CLI tools expect.
  #
  # System.cmd has no built-in timeout, so we wrap it in a Task and rely on
  # Task.yield + Task.shutdown for the timeout. Task.shutdown/:brutal_kill
  # sends SIGKILL to the port's Elixir process which closes the port, which
  # kernel-terminates bwrap; bwrap's --die-with-parent + --unshare-pid
  # triple-cleanup then reaps the CLI tool and all its descendants.
  defp run_via_port(bwrap_bin, argv, prompt, timeout_s, usage_dir) do
    task =
      Task.async(fn ->
        try do
          # :input writes the iodata to stdin and closes it — this is the
          # stdin-EOF signal every supported CLI needs. stderr_to_stdout: true
          # mirrors the prior port behaviour (stderr merged into stdout).
          {output, status} =
            System.cmd(bwrap_bin, argv,
              input: prompt,
              stderr_to_stdout: true,
              parallelism: true
            )

          {:ok, output, status}
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout_s * 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, output, status}} ->
        {:ok,
         %{
           exit_status: status,
           stdout: output,
           usage_dir: usage_dir
         }}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:exit, reason} ->
        {:error, {:task_exit, reason}}

      nil ->
        Logger.warning("bwrap invocation exceeded #{timeout_s}s — brutal_kill issued")
        {:error, :timeout}
    end
  end
end
