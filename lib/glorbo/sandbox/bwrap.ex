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
  uts, user and cgroup namespaces:

      --die-with-parent --unshare-user-try --unshare-ipc
      --unshare-pid --unshare-uts --unshare-cgroup-try
      --new-session --cap-drop ALL

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

  ## Network policy (D-15, D-17)

    * `:none` → `--unshare-net` (kernel-enforced egress block).
    * `:api_only` → inherits host netns, but `HTTPS_PROXY` and `HTTP_PROXY`
      env vars point at a `Glorbo.Network.Proxy` listener with a hostname
      allowlist. Advisory-only (RESEARCH Pitfall 7) — motivated agents can
      bypass by ignoring the env.
    * `:open` → inherits host netns; no proxy.

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
    bwrap_bin = Keyword.get(run_opts, :bwrap_binary, default_binary())
    cli_bin = Keyword.fetch!(run_opts, :cli_binary)
    cli_args = Keyword.get(run_opts, :cli_args, [])
    prompt = Keyword.get(run_opts, :prompt, "")
    usage_dir = Keyword.get(run_opts, :usage_dir)
    timeout_s = Map.get(opts, :timeout_seconds, @default_timeout_seconds)

    argv = build_argv(opts) ++ ["--", cli_bin] ++ cli_args

    run_via_port(bwrap_bin, argv, prompt, timeout_s, usage_dir)
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
  defp run_via_port(bwrap_bin, argv, prompt, timeout_s, usage_dir) do
    case write_prompt_tempfile(prompt) do
      {:ok, prompt_file} ->
        try do
          do_run_via_port(bwrap_bin, argv, prompt_file, timeout_s, usage_dir)
        after
          _ = File.rm(prompt_file)
        end

      {:error, reason} ->
        {:error, {:prompt_tempfile_failed, reason}}
    end
  end

  defp write_prompt_tempfile(prompt) when is_binary(prompt) do
    # Use a unique per-invocation path under the system tmp dir. The
    # filename contains no user input and cannot collide across parallel
    # dispatches thanks to the monotonic unique_integer.
    path =
      Path.join(
        System.tmp_dir!(),
        "glorbo_bwrap_prompt_#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.write(path, prompt) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_run_via_port(bwrap_bin, argv, prompt_file, timeout_s, usage_dir) do
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

    port_args = [sh_script, "glorbo-bwrap-launcher", bwrap_bin, prompt_file | argv]

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      {:args, ["-c" | port_args]}
    ]

    port = Port.open({:spawn_executable, sh_path}, port_opts)

    case drain_port(port, timeout_s, <<>>) do
      {:ok, exit_status, output} ->
        {:ok, %{exit_status: exit_status, stdout: output, usage_dir: usage_dir}}

      {:error, :timeout} ->
        Logger.warning("bwrap invocation exceeded #{timeout_s}s — brutal_kill issued")
        safe_port_close(port)
        {:error, :timeout}

      {:error, reason} ->
        safe_port_close(port)
        {:error, reason}
    end
  end

  # Cap accumulated stdout/stderr at 16 MiB. A runaway CLI writing GBs
  # to stdout/stderr would otherwise balloon BEAM heap during the drain
  # loop — once the cap is hit, subsequent chunks are discarded but the
  # port is allowed to run to completion so the CLI's exit code still
  # surfaces (TODO.md Minor #5).
  @stdout_cap 16 * 1024 * 1024

  # Receive-loop over the port: accumulate stdout/stderr data until the
  # `{port, {:exit_status, status}}` message arrives OR the timeout fires.
  defp drain_port(port, timeout_s, acc) do
    deadline_ms = timeout_s * 1_000

    receive do
      {^port, {:data, chunk}} ->
        new_acc =
          if byte_size(acc) >= @stdout_cap, do: acc, else: acc <> chunk

        drain_port(port, timeout_s, new_acc)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc}
    after
      deadline_ms ->
        {:error, :timeout}
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
