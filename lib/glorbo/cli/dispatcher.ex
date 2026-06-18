defmodule Glorbo.CLI.Dispatcher do
  @moduledoc """
  Template expansion + invocation orchestration for the provider
  registry (GEP-8 §7.4).

  The Dispatcher is a pure function module — it takes a Provider struct
  and an invocation context, expands templates, invokes the sandbox via
  a caller-supplied `run_fun` (default: `Sandbox.Bwrap.start/2`), reads
  the agent's reply file with a size cap, and parses usage telemetry.

  ## Template placeholders

  The following substitutions are applied to `args`, `env` values, and
  the reply-path templates before invocation:

    * `{model}` — from `ctx.model`
    * `{workspace}` — from `ctx.workspace`
    * `{prompt_path}` — path to the prompt file written at dispatch time
    * `{reply_path}` — the resolved full reply path (injected after the
      reply templates themselves are expanded — so reply templates
      cannot self-reference)
    * `{timestamp}` — compact timestamp for the reply filename
    * `{invocation_id}` — unique per-dispatch id
    * `{NAME}` — for each named transform in `provider.path_transforms`

  ## Reply contract (GEP-8 D1)

    * Dispatcher generates a unique reply path per invocation and exports
      `GLORBO_REPLY_PATH` in the CLI's env.
    * On exit, the reply file MUST exist and be non-empty and ≤
      `provider.reply_max_bytes`.
    * Missing/empty/too-large = invocation failure with structured
      reasons `:reply_file_missing`, `:reply_file_empty`, or
      `:reply_file_too_large`.

  The Dispatcher does NOT open ports or invoke bwrap directly — the
  `run_fun` opt is the seam. Tests pass a fake; production passes the
  real Bwrap wiring.
  """

  require Logger

  alias Glorbo.CLI.Audit
  alias Glorbo.CLI.Dispatcher.Acp.Client
  alias Glorbo.CLI.Dispatcher.Acp.PortIO
  alias Glorbo.CLI.Dispatcher.Acp.RpcError
  alias Glorbo.CLI.Lifecycle.Daemon
  alias Glorbo.CLI.Parsers
  alias Glorbo.CLI.PathTransforms
  alias Glorbo.CLI.Registry.Provider
  alias Glorbo.Filesystem.AgentWritableFile
  alias Glorbo.Sandbox.Bwrap

  @type ctx :: %{
          required(:model) => String.t(),
          required(:workspace) => String.t(),
          required(:prompt) => String.t(),
          required(:prompt_path) => String.t(),
          optional(:invocation_id) => String.t(),
          optional(:timestamp) => String.t(),
          optional(:bwrap_opts) => map()
        }

  @type result ::
          {:ok,
           %{
             exit_status: integer(),
             reply: binary(),
             reply_path: String.t(),
             usage: Parsers.usage() | nil,
             usage_error: term() | nil
           }}
          | {:error, term()}

  @doc """
  Run a single dispatch. `opts`:

    * `:run_fun` — `(argv, env, bwrap_opts, run_opts_map -> {:ok, map} | {:error, term})`
      where `run_opts_map` carries `cli_binary`, `cli_args`, `prompt`,
      `usage_dir`. Default delegates to `Glorbo.Sandbox.Bwrap.start/2`
      when `ctx.bwrap_opts` is supplied; the fallback raises, forcing
      tests to inject.
    * `:fs_fun` — map of filesystem operations (see defaults).
    * `:now_fun` — `(-> DateTime)` for deterministic timestamps.
    * `:rand_fun` — `(-> String.t)` for deterministic invocation_ids.
  """
  @spec invoke(Provider.t(), ctx(), keyword()) :: result()
  def invoke(provider, ctx, opts \\ [])

  def invoke(%Provider{prompt_mode: :acp} = provider, %{} = ctx, opts) do
    # GEP-45 Phase 1b sub-slice 1b.6: drive an ACP conversation through
    # the sandboxed binary. Reuses the same template-expansion + reply-
    # file scaffolding as the stdin path; only the run-loop differs.
    fs = fs_fun(opts)
    now = Keyword.get(opts, :now_fun, &DateTime.utc_now/0).()
    invocation_id = Map.get(ctx, :invocation_id) || gen_invocation_id(opts)
    timestamp = Map.get(ctx, :timestamp) || format_timestamp(now)

    substitutions =
      build_substitutions(provider, ctx, invocation_id, timestamp)

    reply_dir = expand(provider.reply_dir, substitutions)
    reply_filename = expand(provider.reply_filename_template, substitutions)
    reply_path = Path.join(reply_dir, reply_filename)
    substitutions = Map.put(substitutions, "reply_path", reply_path)

    # F6: ACP session resume. Read prior sessionId (if any) for this
    # task+provider combination so stado/Codex/Claude-Code attach to
    # the existing worktree instead of rebuilding context. Persist the
    # returned id after the dispatch succeeds.
    session_file = acp_session_file(ctx, reply_dir, provider)
    prior_session_id = read_acp_session_id(session_file)

    opts =
      if is_binary(prior_session_id) and prior_session_id != "",
        do: Keyword.put(opts, :resume_session_id, prior_session_id),
        else: opts

    # B9: provider-configured timeout wins unless the caller already set one.
    opts =
      case provider.phase_timeout_ms do
        nil -> opts
        ms -> Keyword.put_new(opts, :phase_timeout_ms, ms)
      end

    # C-049 / D-155 / D-156: bound the whole ACP conversation by the
    # agent's wall-clock `timeout_seconds` (carried in bwrap_opts on the
    # production path) and cap the assembled reply by the provider's
    # `reply_max_bytes` DURING streaming, not only after the run returns.
    opts =
      case acp_conversation_timeout_ms(ctx) do
        nil -> opts
        ms -> Keyword.put_new(opts, :conversation_timeout_ms, ms)
      end

    opts = Keyword.put_new(opts, :reply_max_bytes, provider.reply_max_bytes)

    with :ok <- prepare_reply_dir(reply_dir, reply_path, fs),
         args <- Enum.map(provider.args, &expand(&1, substitutions)),
         env <- build_env(provider, provider.env, substitutions, reply_path, invocation_id, ctx),
         enriched_ctx <- inject_env_into_bwrap_opts(ctx, env),
         {:ok, %{reply: reply_text} = acp_result} <- run_acp(provider, args, enriched_ctx, opts) do
      :ok = write_reply_file!(reply_path, reply_text, provider.reply_max_bytes, fs)
      :ok = write_acp_session_id(session_file, Map.get(acp_result, :session_id))

      acp_meta = %{
        session_id: Map.get(acp_result, :session_id),
        chunks: Map.get(acp_result, :chunks, 0),
        ignored_updates: Map.get(acp_result, :ignored_updates, 0)
      }

      {usage, usage_error} = parse_acp_usage(provider, acp_meta, ctx, opts)

      {:ok,
       %{
         exit_status: 0,
         reply: strip_ansi(reply_text),
         reply_path: reply_path,
         usage: usage,
         usage_error: usage_error,
         invocation_id: invocation_id,
         acp: acp_meta
       }}
    end
  end

  def invoke(%Provider{} = provider, %{} = ctx, opts) do
    fs = fs_fun(opts)
    now = Keyword.get(opts, :now_fun, &DateTime.utc_now/0).()
    invocation_id = Map.get(ctx, :invocation_id) || gen_invocation_id(opts)
    timestamp = Map.get(ctx, :timestamp) || format_timestamp(now)

    substitutions = %{
      "model" => ctx.model,
      "workspace" => ctx.workspace,
      "prompt_path" => ctx.prompt_path,
      "provider" => provider.name,
      "agent_slug" => Map.get(ctx, :agent_slug, ""),
      "company" => Map.get(ctx, :company, ""),
      "task_id" => Map.get(ctx, :task_id, ""),
      "timestamp" => timestamp,
      "invocation_id" => invocation_id
    }

    substitutions = add_transform_substitutions(substitutions, provider.path_transforms)

    reply_dir = expand(provider.reply_dir, substitutions)
    reply_filename = expand(provider.reply_filename_template, substitutions)
    reply_path = Path.join(reply_dir, reply_filename)
    substitutions = Map.put(substitutions, "reply_path", reply_path)

    with :ok <- prepare_reply_dir(reply_dir, reply_path, fs),
         args <- Enum.map(provider.args, &expand(&1, substitutions)),
         env <- build_env(provider, provider.env, substitutions, reply_path, invocation_id, ctx),
         {:ok, run_result} <- run(provider, args, env, ctx, opts),
         # D6: run the stdout fallback BEFORE the diagnostic log.
         # When a CLI writes its reply to stdout instead of the
         # GLORBO_REPLY_PATH file, the fallback materialises the
         # reply file — running the log AFTER means
         # `reply_exists?` reflects the post-fallback state and
         # we don't emit a misleading "reply_exists?=false"
         # warning for what's actually a successful dispatch.
         :ok <- maybe_stdout_to_reply(run_result, reply_path, provider.reply_max_bytes, fs),
         :ok <- maybe_log_run_output(provider, run_result, reply_path, fs),
         {:ok, reply} <- read_reply(reply_path, provider.reply_max_bytes, fs) do
      {usage, usage_error} =
        parse_usage(provider, run_result, ctx, substitutions)

      {:ok,
       %{
         exit_status: Map.get(run_result, :exit_status, 0),
         reply: reply,
         reply_path: reply_path,
         usage: usage,
         usage_error: usage_error,
         invocation_id: invocation_id
       }}
    end
  end

  # Fallback reply capture: if the CLI exited cleanly but didn't write
  # to $GLORBO_REPLY_PATH, AND stdout has content, treat stdout as the
  # effective reply. This lets CLIs like `claude --print` — which write
  # their response to stdout rather than following the GLORBO_REPLY_PATH
  # contract — integrate without the agent needing a shell-redirect
  # wrapper. Does nothing if stdout is empty or exit != 0; the existing
  # :reply_file_missing/:reply_file_empty errors still surface then.
  defp maybe_stdout_to_reply(run_result, reply_path, max_bytes, fs) do
    exit_status = Map.get(run_result, :exit_status, 0)
    stdout = Map.get(run_result, :stdout, "") |> to_string()
    trimmed = String.trim(stdout)

    cond do
      exit_status != 0 ->
        :ok

      trimmed == "" ->
        :ok

      fs.exists?.(reply_path) ->
        :ok

      byte_size(stdout) > max_bytes ->
        :ok

      true ->
        # threatmodel H12: the reply path lives inside the agent
        # workspace, so a malicious CLI can plant a (possibly
        # broken) symlink at the expected location. File.write
        # follows it, which can create or clobber arbitrary files
        # writable by the Glorbo user. lstat and refuse if anything
        # non-regular already exists.
        parent = Path.dirname(reply_path)
        fs.mkdir_p!.(parent)

        case File.lstat(reply_path) do
          {:ok, %File.Stat{type: :regular}} ->
            File.write!(reply_path, strip_ansi(stdout))
            :ok

          {:ok, %File.Stat{type: type}} ->
            require Logger
            Logger.warning("stdout→reply fallback refused: #{inspect(type)} at #{reply_path}")
            :ok

          {:error, :enoent} ->
            File.write!(reply_path, strip_ansi(stdout))
            :ok

          {:error, reason} ->
            require Logger
            Logger.warning("stdout→reply lstat failed: #{inspect(reason)}")
            :ok
        end
    end
  end

  # Surface CLI run failures to the Director-visible audit trail. If the
  # exit status is non-zero OR the reply file is missing, emit a warning
  # with the captured stdout/stderr (merged at the Bwrap layer). Without
  # this, `:reply_file_missing` is all the operator sees — no idea
  # whether auth failed, the CLI segfaulted, or the bwrap syscall was
  # denied.
  defp maybe_log_run_output(%Provider{} = provider, run_result, reply_path, fs) do
    exit_status = Map.get(run_result, :exit_status, 0)
    stdout = Map.get(run_result, :stdout, "")
    reply_exists? = fs.exists?.(reply_path)

    if exit_status != 0 or not reply_exists? do
      # Cap stdout so a flood doesn't drown the logs. Use byte-based
      # `binary_part/3` rather than `String.slice/3` because the bwrap
      # port produces raw bytes and stdout is attacker-controlled —
      # `String.slice/3` raises on invalid UTF-8. `inspect/1` escapes
      # non-printable bytes safely.
      raw = stdout |> to_string()
      snippet = binary_part(raw, 0, min(byte_size(raw), 2_000))

      Logger.warning(
        "cli #{provider.name} exit=#{exit_status} reply_exists?=#{reply_exists?} stdout=#{inspect(snippet)}"
      )
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # GEP-45 Phase 1b — ACP run loop
  # ---------------------------------------------------------------------------

  # Run the ACP conversation. Defaults to spawning a sandboxed Port via
  # `Glorbo.Sandbox.Bwrap.start_acp/2` and wrapping it in a
  # `Glorbo.CLI.Dispatcher.Acp.Client.IO`. Tests inject `:acp_run_fun`
  # to replace the entire run loop with a stub.
  defp run_acp(provider, args, ctx, opts) do
    acp_run_fun = Keyword.get(opts, :acp_run_fun, &default_acp_run_fun/3)

    cli_binary = Map.get(ctx, :cli_binary) || provider.resolved_path || provider.binary
    bwrap_opts = Map.get(ctx, :bwrap_opts, %{})

    run_opts_map = %{
      cli_binary: cli_binary,
      cli_args: args,
      prompt: Map.get(ctx, :prompt, "")
    }

    case acp_run_fun.(bwrap_opts, run_opts_map, opts) do
      {:ok, %{reply: _} = result} ->
        {:ok, result}

      {:error, {:provider_returned_error, %RpcError{} = err}} ->
        {:error, {:provider_returned_error, %{code: err.code, message: err.message}}}

      {:error, {:provider_protocol_error, _} = err} ->
        {:error, err}

      {:error, {:provider_timeout, _phase} = err} ->
        {:error, err}

      {:error, _} = err ->
        err

      other ->
        {:error, {:acp_run_fun_bad_return, other}}
    end
  end

  # C-049: the agent's wall-clock `timeout_seconds` rides in
  # `ctx.bwrap_opts` on the production path (set by
  # `Glorbo.Agent.Dispatch`). Convert to ms for the ACP client's
  # absolute conversation deadline. nil → client falls back to its own
  # default (30 min).
  defp acp_conversation_timeout_ms(ctx) do
    case Map.get(ctx, :bwrap_opts, %{}) |> Map.get(:timeout_seconds) do
      s when is_integer(s) and s > 0 -> s * 1_000
      _ -> nil
    end
  end

  defp default_acp_run_fun(bwrap_opts, run_opts_map, opts) do
    case Bwrap.start_acp(bwrap_opts, Map.to_list(run_opts_map)) do
      {:ok, port} ->
        io = PortIO.wrap(port)
        prompt = Map.get(run_opts_map, :prompt, "")

        client_opts =
          opts
          |> Keyword.take([
            :phase_timeout_ms,
            :protocol_version,
            :client_info,
            :resume_session_id,
            :conversation_timeout_ms,
            :reply_max_bytes,
            :max_line_bytes,
            :audit_frames_max
          ])
          |> Keyword.put(:audit_fun, audit_fun_for_acp(opts))

        try do
          Client.run(io, prompt, client_opts)
        after
          # Best-effort: drain the lingering exit-status message so
          # the BEAM mailbox doesn't keep dispatch-stale ports.
          _ = PortIO.drain(port, 100)
        end

      {:error, _} = err ->
        err
    end
  end

  # The stdin run path passes provider [env] vars as a separate arg
  # to its run_fun, which `Glorbo.Agent.Dispatch.default_run_fun/4`
  # merges into bwrap_opts.cli_env (with host-workspace → /workspace
  # rewriting). The ACP run path doesn't have that seam — start_acp/2
  # only reads cli_env from bwrap_opts. Without this merge, every
  # `[env]` entry in a provider TOML is silently dropped on ACP
  # dispatches, which broke stado until a wrapper script worked
  # around it (TODO B4).
  defp inject_env_into_bwrap_opts(ctx, env) when is_map(env) do
    bwrap_opts = Map.get(ctx, :bwrap_opts, %{})

    host_workspace =
      Map.get(bwrap_opts, :agent_workspace) ||
        Map.get(ctx, :workspace) || ""

    sandbox_env = rewrite_env_for_sandbox(env, host_workspace)
    base_cli_env = Map.get(bwrap_opts, :cli_env, %{})
    merged = Map.merge(base_cli_env, sandbox_env)

    Map.put(ctx, :bwrap_opts, Map.put(bwrap_opts, :cli_env, merged))
  end

  defp rewrite_env_for_sandbox(env, "") when is_map(env), do: env

  defp rewrite_env_for_sandbox(env, host) when is_map(env) and is_binary(host) do
    Map.new(env, fn
      {k, v} when is_binary(v) -> {k, String.replace(v, host, "/workspace")}
      kv -> kv
    end)
  end

  # ACP usage parsing — runs after the dispatch returns. The `stado_acp`
  # parser shells out to the host's stado binary (`stado stats --session
  # <sid> --json`) to extract token + cost.
  #
  # A-001 / B-006 hardening: stado's session/audit trace no longer lives
  # in shared host XDG dirs — `priv/providers/stado.toml` relocates
  # XDG_DATA_HOME / XDG_STATE_HOME into the per-agent, per-company rw
  # workspace (`<workspace>/.local/{share,state}`). So the stats walker
  # runs against THAT per-agent state, never the host's shared
  # `~/.local/{share,state}/stado`. We pass the same XDG env (pointed at
  # the host side of the workspace bind) to the stats subprocess so it
  # reads the trace the dispatch just wrote, and we bound it with a hard
  # timeout so a hung stats can't block the dispatch pipeline. Tests
  # inject `:command_fun` to bypass the real subprocess.
  defp parse_acp_usage(%Provider{usage_parser: name}, acp_meta, ctx, opts)
       when name in [nil, "", "none"] do
    _ = {acp_meta, ctx, opts}
    {nil, nil}
  end

  defp parse_acp_usage(%Provider{usage_parser: "stado_acp"} = provider, acp_meta, ctx, opts) do
    source = {
      :stado_session,
      %{
        session_id: Map.get(acp_meta, :session_id) || "",
        host_binary: stado_host_binary(provider, ctx),
        stats_env: stado_stats_env(ctx),
        command_fun: Keyword.get(opts, :command_fun, &System.cmd/3)
      }
    }

    # module_for/1 is total in practice — the loader hard-fails unknown
    # parser names at boot (Parsers moduledoc) — but it is typed module() | nil,
    # so handle nil fail-closed rather than dispatching on nil.
    run_usage_parser(Parsers.module_for("stado_acp"), source, "stado_acp")
  end

  defp parse_acp_usage(%Provider{}, _acp_meta, _ctx, _opts) do
    {nil, {:unsupported_acp_usage_parser, "non-stado_acp parsers don't apply to ACP dispatches"}}
  end

  # Where to find the stado binary on the host (NOT the sandbox path).
  # `host_cli_binary` from ctx wins; falls back to the provider's
  # resolved path; finally to `stado` on PATH.
  defp stado_host_binary(provider, ctx) do
    Map.get(ctx, :host_cli_binary) ||
      provider.resolved_path ||
      provider.binary ||
      "stado"
  end

  # XDG env for the host-side `stado stats` call, pointed at the HOST
  # side of the per-agent workspace bind so the stats walker reads the
  # relocated session trace (and never the host's shared
  # `~/.local/{share,state}/stado`). Mirrors the sandbox XDG env from
  # stado.toml: inside bwrap the workspace is `/workspace`; on the host
  # it's `ctx.workspace`. Returns `nil` when no workspace is known so
  # the parser falls back to a bare `System.cmd` (test path).
  defp stado_stats_env(ctx) do
    case Map.get(ctx, :workspace) do
      ws when is_binary(ws) and ws != "" ->
        [
          {"XDG_CONFIG_HOME", Path.join(ws, ".config")},
          {"XDG_DATA_HOME", Path.join(ws, ".local/share")},
          {"XDG_STATE_HOME", Path.join(ws, ".local/state")}
        ]

      _ ->
        nil
    end
  end

  # Bind the per-frame audit emission to `Glorbo.CLI.Audit.emit/3` with
  # a stable verb prefix (`acp`) and the role/kind merged into the
  # audit phase so operators can grep one line per frame from
  # `audit/_system/YYYY-MM.jsonl`. Tests can inject `:audit_fun`
  # directly to bypass the AuditLog GenServer.
  defp audit_fun_for_acp(opts) do
    case Keyword.fetch(opts, :audit_fun) do
      {:ok, fun} when is_function(fun, 3) ->
        fun

      :error ->
        fn role, kind, detail ->
          Audit.emit("acp", "#{role}.#{kind}", detail)
        end
    end
  end

  # Reuse the existing reply-file safety regime (lstat, refuse symlinks,
  # cap size). The ACP path bypasses `read_reply/3` because the bytes
  # came from the JSON-RPC stream rather than a CLI-written file, but
  # we still write atomically to the reply path so downstream readers
  # (audit, dashboard) see the same contract.
  defp write_reply_file!(reply_path, reply_text, max_bytes, fs)
       when is_binary(reply_text) do
    if byte_size(reply_text) > max_bytes do
      # Truncating silently would lie to the agent; surface the cap
      # breach inline so dispatcher result shape stays consistent.
      raise "ACP reply exceeds reply_max_bytes (#{byte_size(reply_text)} > #{max_bytes})"
    end

    parent = Path.dirname(reply_path)
    fs.mkdir_p!.(parent)

    case File.lstat(reply_path) do
      {:ok, %File.Stat{type: :regular}} ->
        File.write!(reply_path, reply_text)
        :ok

      {:ok, %File.Stat{type: type}} ->
        raise "ACP reply path is not a regular file (#{inspect(type)}): #{reply_path}"

      {:error, :enoent} ->
        File.write!(reply_path, reply_text)
        :ok

      {:error, reason} ->
        raise "ACP reply lstat failed: #{inspect(reason)}"
    end
  end

  # Assemble the template-expansion substitution map used by both the
  # stdin and ACP branches. Extracted so the two branches stay in sync.
  defp build_substitutions(provider, ctx, invocation_id, timestamp) do
    base = %{
      "model" => Map.get(ctx, :model, ""),
      "workspace" => Map.get(ctx, :workspace, ""),
      "prompt_path" => Map.get(ctx, :prompt_path, ""),
      "provider" => provider.name,
      "agent_slug" => Map.get(ctx, :agent_slug, ""),
      "company" => Map.get(ctx, :company, ""),
      "task_id" => Map.get(ctx, :task_id, ""),
      "timestamp" => timestamp,
      "invocation_id" => invocation_id
    }

    add_transform_substitutions(base, provider.path_transforms)
  end

  # ---------------------------------------------------------------------------
  # Template expansion
  # ---------------------------------------------------------------------------

  @doc false
  def expand(template, substitutions) when is_binary(template) do
    Enum.reduce(substitutions, template, fn {key, value}, acc ->
      String.replace(acc, "{#{key}}", to_string(value))
    end)
  end

  defp add_transform_substitutions(subs, transforms) do
    Enum.reduce(transforms, subs, fn %{name: name, from: from, transform: transform}, acc ->
      expanded_from = expand(from, acc)
      value = PathTransforms.apply!(transform, expanded_from)
      Map.put(acc, name, value)
    end)
  end

  # ---------------------------------------------------------------------------
  # Reply-file contract
  # ---------------------------------------------------------------------------

  # Public-but-`@doc false` so the symlink-ancestor defense can be
  # unit-tested without standing up a full ACP dispatch.
  @doc false
  def prepare_reply_dir(dir, reply_path, fs) do
    # Codex round-2 finding: the ACP CLI runs concurrently in the
    # workspace and can replace `.glorbo/outbox` (or any ancestor of
    # the reply path) with a symlink BEFORE the host runs `mkdir_p!`.
    # `mkdir_p!` is happy to follow that symlink, and the subsequent
    # `write_reply_file!` would then land OUTSIDE the workspace. The
    # leaf `lstat` check on `reply_path` happens later but only
    # protects against a symlinked LEAF — not a symlinked ancestor.
    # Refuse here, before any I/O, so the host can never be used as a
    # confused-deputy writer.
    if Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(dir) do
      raise "prepare_reply_dir: refusing to write under symlinked ancestor: #{dir}"
    end

    fs.mkdir_p!.(dir)
    if fs.exists?.(reply_path), do: fs.rm!.(reply_path)
    :ok
  end

  defp read_reply(path, max_bytes, fs) do
    # Threatmodel H1/H2 (wave 4): lstat first. The reply path lives inside
    # the agent workspace, so an untrusted CLI can pre-create it as a
    # symlink to a host file (e.g. `~/.glorbo/config.md`). `File.stat`
    # follows the link; `File.lstat` sees the symlink itself. Use the
    # `lstat` size for the cap check too — a second `File.stat` call
    # before `File.read` would re-follow the link and re-open a TOCTOU
    # window. Opencode round-3 flagged this.
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} -> do_read_reply(path, size, max_bytes, fs)
      {:ok, %{type: other}} -> {:error, {:reply_file_not_regular, other}}
      {:error, :enoent} -> {:error, :reply_file_missing}
      {:error, reason} -> {:error, {:reply_file_stat_error, reason}}
    end
  end

  defp do_read_reply(_path, 0, _max_bytes, _fs), do: {:error, :reply_file_empty}

  defp do_read_reply(_path, size, max_bytes, _fs) when size > max_bytes,
    do: {:error, {:reply_file_too_large, size, max_bytes}}

  defp do_read_reply(path, _size, _max_bytes, fs) do
    case fs.read.(path) do
      {:ok, contents} -> {:ok, strip_ansi(contents)}
      {:error, reason} -> {:error, {:reply_file_read_error, reason}}
    end
  end

  # opencode (and claude-code's interactive mode) prefix every output
  # line with SGR/CSI escapes for colour, cursor moves, and clear-line.
  # Those sequences survive into the reply file when we stdout → reply
  # fall back, and also leak through when the CLI echoes ANSI into the
  # reply path directly. Strip them at the dispatcher seam so the
  # Director-visible reply + audit log both carry clean text.
  #
  # Uses `Glorbo.Terminal.Sanitizer` (linear scan) — not a backtracking
  # regex — so unbounded agent stdout cannot trigger O(n²) on unterminated
  # OSC sequences (codex L78).
  @doc false
  def strip_ansi(text) when is_binary(text) do
    # Threatmodel: agent stdout is attacker-controlled and may contain
    # invalid UTF-8. Coerce to printable UTF-8 first — `:unicode.characters_to_binary/3`
    # with `:latin1` → `:utf8` substitutes U+FFFD for invalid bytes.
    safe =
      if String.valid?(text) do
        text
      else
        case :unicode.characters_to_binary(text, :latin1, :utf8) do
          bin when is_binary(bin) -> bin
          _ -> for <<b <- text>>, do: if(b < 128, do: <<b>>, else: "?"), into: ""
        end
      end

    Glorbo.Terminal.Sanitizer.strip(safe)
  end

  def strip_ansi(other), do: other

  # ---------------------------------------------------------------------------
  # Env composition
  # ---------------------------------------------------------------------------

  defp build_env(provider, provider_env, substitutions, reply_path, invocation_id, ctx) do
    expanded =
      Map.new(provider_env, fn {k, v} -> {k, expand(v, substitutions)} end)

    base_env = %{
      "GLORBO_TASK_ID" => Map.get(ctx, :task_id, ""),
      "GLORBO_INVOCATION_ID" => invocation_id,
      "GLORBO_PROVIDER" => provider.name,
      "GLORBO_REPLY_PATH" => reply_path,
      "GLORBO_WORKSPACE" => ctx.workspace,
      "GLORBO_INBOX" => "/inbox",
      "GLORBO_OUTBOX" => "/outbox",
      # Agents need these to self-identify and to datestamp their
      # outputs. The `glorbo` skill documents them as guaranteed
      # present; Dispatcher was silently dropping them before today.
      "GLORBO_AGENT" => Map.get(ctx, :agent_slug, ""),
      "GLORBO_COMPANY" => Map.get(ctx, :company, ""),
      "GLORBO_TIMESTAMP" => Map.get(substitutions, "timestamp", "")
    }

    usage_env =
      case provider.usage_path do
        %{kind: :json_file, path: path} ->
          %{
            "GLORBO_USAGE_PATH" => expand(path, Map.merge(base_substitutions(ctx), substitutions))
          }

        _ ->
          %{}
      end

    native_env =
      if provider.kind == :native do
        %{
          "GLORBO_NATIVE_ENDPOINT" => native_endpoint(provider, ctx),
          "GLORBO_NATIVE_AUTH" => to_string(provider.auth || ""),
          "GLORBO_NATIVE_CREDENTIALS_PATH" => native_credentials_path_env(provider),
          "GLORBO_NATIVE_HTTP_TIMEOUT_S" => to_string(Map.get(ctx, :http_timeout_s, 120)),
          "GLORBO_NATIVE_HTTP_MAX_RETRIES" => to_string(Map.get(ctx, :http_max_retries, 3)),
          "GLORBO_NATIVE_WEB_FETCH_TIMEOUT_S" =>
            to_string(Map.get(ctx, :web_fetch_timeout_s, 30)),
          "GLORBO_NATIVE_MAX_TOOL_CALLS_PER_TURN" =>
            to_string(Map.get(ctx, :max_tool_calls_per_turn, 50))
        }
      else
        %{}
      end

    expanded
    |> Map.merge(base_env)
    |> Map.merge(usage_env)
    |> Map.merge(native_env)
  end

  # GEP-0055: under `via_proxy` the harness's endpoint is the
  # in-process proxy's loopback URL, never the upstream. Dispatch
  # placed that URL in `bwrap_opts.cli_env["GLORBO_PROXY_BASE_URL"]`
  # (proxy_cli_env); read it back here so GLORBO_NATIVE_ENDPOINT
  # agrees with OPENAI_BASE_URL. Falling back to provider.endpoint
  # would dial the upstream directly from inside the netns — wrong
  # listener AND no auth — so prefer an empty endpoint (clean
  # `:missing_endpoint` from the harness) over a misleading one.
  defp native_endpoint(%{auth: :via_proxy}, ctx) do
    ctx
    |> Map.get(:bwrap_opts, %{})
    |> Map.get(:cli_env, %{})
    |> Map.get("GLORBO_PROXY_BASE_URL", "")
  end

  defp native_endpoint(provider, _ctx), do: provider.endpoint || ""

  # GEP-0055: no `/creds` mount exists under `via_proxy` (that is
  # the point of the proxy). An empty path keeps the harness's
  # credentials loader on its `{:ok, %{}}` no-file path instead of
  # advertising a mount that isn't there.
  defp native_credentials_path_env(%{auth: :via_proxy}), do: ""
  defp native_credentials_path_env(_provider), do: "/creds/provider.toml"

  # ---------------------------------------------------------------------------
  # Invocation (via injected run_fun)
  # ---------------------------------------------------------------------------

  defp run(provider, args, env, ctx, opts) do
    run_fun = Keyword.get(opts, :run_fun, &default_run_fun/4)

    run_opts_map =
      case provider.kind do
        :native ->
          %{
            cli_binary:
              Map.get(ctx, :cli_binary) || Map.get(ctx, :native_binary) || Daemon.self_binary(),
            host_cli_binary:
              Map.get(ctx, :host_cli_binary) || Map.get(ctx, :native_binary) ||
                Daemon.self_binary(),
            cli_args: native_args(provider, ctx),
            prompt: Map.get(ctx, :prompt, ""),
            usage_dir: usage_dir_for(provider, ctx)
          }

        _ ->
          %{
            cli_binary: Map.get(ctx, :cli_binary) || provider.resolved_path || provider.binary,
            host_cli_binary:
              Map.get(ctx, :host_cli_binary) || provider.resolved_path || provider.binary,
            cli_args: args,
            prompt: Map.get(ctx, :prompt, ""),
            usage_dir: usage_dir_for(provider, ctx)
          }
      end

    case run_fun.(args, env, Map.get(ctx, :bwrap_opts, %{}), run_opts_map) do
      {:ok, m} when is_map(m) -> {:ok, m}
      {:error, _} = err -> err
      other -> {:error, {:run_fun_bad_return, other}}
    end
  end

  defp native_args(provider, ctx) do
    [
      "harness",
      "--provider",
      provider.name,
      "--agent",
      Map.get(ctx, :agent_slug, ""),
      "--task",
      Map.get(ctx, :task_id, ""),
      "--model",
      Map.get(ctx, :model, "")
    ]
  end

  defp usage_dir_for(%Provider{usage_path: nil}, _ctx), do: nil

  defp usage_dir_for(%Provider{usage_path: %{kind: :jsonl_latest_in_dir, path: path}}, ctx) do
    expand(path, base_substitutions(ctx))
  end

  defp usage_dir_for(%Provider{usage_path: %{kind: :jsonl_file, path: path}}, ctx) do
    path |> expand(base_substitutions(ctx)) |> Path.dirname()
  end

  defp usage_dir_for(%Provider{usage_path: %{kind: :json_file, path: path}}, ctx) do
    path |> expand(base_substitutions(ctx)) |> Path.dirname()
  end

  defp usage_dir_for(%Provider{usage_path: %{kind: :stdout}}, _ctx), do: nil

  defp base_substitutions(ctx) do
    %{
      "model" => Map.get(ctx, :model, ""),
      "workspace" => ctx.workspace,
      "prompt_path" => Map.get(ctx, :prompt_path, ""),
      "provider" => Map.get(ctx, :provider, ""),
      "agent_slug" => Map.get(ctx, :agent_slug, ""),
      "company" => Map.get(ctx, :company, ""),
      "task_id" => Map.get(ctx, :task_id, "")
    }
  end

  defp default_run_fun(_args, _env, _bwrap_opts, _run_opts_map) do
    {:error, :no_run_fun_configured}
  end

  # ---------------------------------------------------------------------------
  # Usage parsing
  # ---------------------------------------------------------------------------

  defp parse_usage(%Provider{usage_parser: "none"}, _run_result, _ctx, _subs) do
    {nil, nil}
  end

  defp parse_usage(
         %Provider{usage_parser: name, usage_path: usage_path} = provider,
         run_result,
         ctx,
         subs
       ) do
    source = resolve_source(usage_path, run_result, ctx, subs, provider)
    run_usage_parser(Parsers.module_for(name), source, name)
  end

  # Dispatch to a named usage parser, failing closed if the registry has no
  # module for `name`. module_for/1 is total in practice (the loader rejects
  # unknown parser names at boot) but is typed module() | nil; matching the nil
  # head keeps the compiler from inferring a nil.parse/1 call and turns a
  # would-be runtime crash into the {usage, reason} error contract callers expect.
  defp run_usage_parser(nil, _source, name), do: {nil, {:unknown_usage_parser, name}}

  defp run_usage_parser(module, source, _name) when is_atom(module) do
    case module.parse(source) do
      {:ok, usage} -> {usage, nil}
      {:error, reason} -> {nil, reason}
    end
  end

  defp resolve_source(%{kind: :stdout}, run_result, _ctx, _subs, _provider) do
    {:stdout, Map.get(run_result, :stdout, "")}
  end

  defp resolve_source(%{kind: :jsonl_file, path: path}, _run_result, ctx, subs, _provider) do
    {:jsonl_file, expand(path, Map.merge(base_substitutions(ctx), subs))}
  end

  defp resolve_source(%{kind: :json_file, path: path}, _run_result, ctx, subs, _provider) do
    {:json_file, expand(path, Map.merge(base_substitutions(ctx), subs))}
  end

  defp resolve_source(
         %{kind: :jsonl_latest_in_dir, path: path},
         _run_result,
         ctx,
         subs,
         _provider
       ) do
    dir = expand(path, Map.merge(base_substitutions(ctx), subs))

    case latest_jsonl(dir) do
      nil -> {:jsonl_file, "/nonexistent/no-jsonl-found"}
      found -> {:jsonl_file, found}
    end
  end

  defp latest_jsonl(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(fn p ->
          case File.stat(p) do
            {:ok, s} -> [{p, s.mtime}]
            {:error, _} -> []
          end
        end)
        |> Enum.sort_by(fn {_p, m} -> m end, :desc)
        |> case do
          [] -> nil
          [{p, _} | _] -> p
        end

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Defaults
  # ---------------------------------------------------------------------------

  defp fs_fun(opts) do
    Keyword.get(opts, :fs_fun, %{
      mkdir_p!: &File.mkdir_p!/1,
      exists?: &File.exists?/1,
      rm!: &File.rm!/1,
      stat: &File.stat/1,
      read: &File.read/1
    })
  end

  defp gen_invocation_id(opts) do
    case Keyword.get(opts, :rand_fun) do
      nil ->
        16
        |> :crypto.strong_rand_bytes()
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 16)

      fun ->
        fun.()
    end
  end

  defp format_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.to_iso8601(:basic)
    |> String.replace(["-", ":", "T", "Z"], "")
    |> binary_part(0, 14)
  end

  # ---------- F6: ACP session-id persistence ----------
  #
  # Sessions live next to the reply outbox at `<workspace>/.glorbo/
  # sessions/<provider>__<task_id>.txt`. Keyed by (provider, task_id)
  # so the same task across multiple dispatches reuses one stado /
  # Codex / Claude-Code session, but two different providers running
  # the same task each get their own. When `task_id` is missing from
  # ctx, we skip persistence entirely — there's no sound key to use,
  # and silently inventing one (e.g. invocation_id) defeats the
  # purpose of resume.

  defp acp_session_file(ctx, reply_dir, provider) do
    task_id = Map.get(ctx, :task_id, "")
    provider_name = provider.name || ""

    cond do
      not is_binary(task_id) or task_id == "" ->
        nil

      not is_binary(provider_name) or provider_name == "" ->
        nil

      true ->
        sessions_dir = Path.expand(Path.join(reply_dir, "../sessions"))
        Path.join(sessions_dir, "#{provider_name}__#{task_id}.txt")
    end
  end

  defp read_acp_session_id(nil), do: nil

  defp read_acp_session_id(path) do
    # B-024: the session file lives in the agent-writable workspace, so
    # an untrusted ACP CLI can replace it with a symlink to an arbitrary
    # host file (e.g. `~/.glorbo/config.md`). A bare `File.read` follows
    # the link. lstat-and-refuse non-regular shapes first — mirrors the
    # reply-path guard in `write_reply_file!/4` and the shared helper
    # every other agent-writable read site uses.
    #
    # D8: then validate the on-disk content as a canonical UUID before
    # handing it back to the caller. Files written by older Glorbo
    # versions, or by a peer that returned a non-UUID `sessionId`
    # (e.g. a description / project slug — stado's `--resume`
    # CLI flag accepts those, but the `resumeSession` ACP param
    # rejects with `code: -32602, "invalid UUID length: N"` and
    # wedges the dispatch). Treat any non-UUID content as "no
    # prior session" and let the dispatch proceed fresh.
    case AgentWritableFile.read(path) do
      {:ok, content} ->
        case String.trim(content) do
          "" ->
            nil

          trimmed ->
            if uuid_shape?(trimmed) do
              trimmed
            else
              # Best-effort cleanup: drop the bad file so the next
              # dispatch starts clean and the operator's directory
              # listing reflects what's actually usable. `File.rm`
              # unlinks the entry itself (a symlink, if any), never
              # the target — safe.
              _ = File.rm(path)
              nil
            end
        end

      {:error, {:not_regular_file, type}} ->
        # Refuse a planted symlink/dir/device. Drop the rogue entry so
        # the next dispatch starts clean; `File.rm` unlinks the symlink,
        # not its target.
        Logger.warning(
          "[dispatcher] refusing non-regular ACP session file (#{inspect(type)}): #{path}"
        )

        _ = File.rm(path)
        nil

      _ ->
        nil
    end
  end

  defp write_acp_session_id(nil, _), do: :ok
  defp write_acp_session_id(_, nil), do: :ok
  defp write_acp_session_id(_, ""), do: :ok

  defp write_acp_session_id(path, session_id) when is_binary(session_id) do
    cond do
      not uuid_shape?(session_id) ->
        # D8: refuse to persist a non-UUID sessionId. A future
        # dispatch trying to `resumeSession` against it would be
        # rejected by stado / any other ACP peer that validates
        # input strictly. Better to start fresh next call than to
        # wedge the agent on a bad token.
        Logger.warning(
          "[dispatcher] dropping non-UUID ACP sessionId from persistence: " <>
            "#{inspect(session_id)} — next dispatch will start a fresh session"
        )

        :ok

      AgentWritableFile.any_symlink_in_path?(Path.dirname(path)) ->
        # Codex round-2 finding: refuse if any ancestor of the session
        # file is a symlink BEFORE the host calls `mkdir_p!` (which
        # follows ancestor symlinks). Agents control the workspace and
        # can replace `.glorbo/sessions/` with a symlink to a host path
        # between dispatch start and ACP completion; without this check,
        # the host writes the session-id file at the redirected
        # location. The `ensure_writable(path)` leaf-check below stays
        # as a second layer (B-024).
        Logger.warning(
          "[dispatcher] refusing to write ACP session id under symlinked ancestor: " <>
            "#{Path.dirname(path)}"
        )

        :ok

      true ->
        File.mkdir_p!(Path.dirname(path))

        case AgentWritableFile.ensure_writable(path) do
          :ok ->
            File.write!(path, session_id)
            :ok

          {:error, {:not_regular_file, type}} ->
            Logger.warning(
              "[dispatcher] refusing to write ACP session id through non-regular path " <>
                "(#{inspect(type)}): #{path}"
            )

            :ok

          {:error, reason} ->
            Logger.warning(
              "[dispatcher] ACP session file lstat failed (#{inspect(reason)}): #{path}"
            )

            :ok
        end
    end
  end

  # Canonical UUID regex (8-4-4-4-12 hex, case-insensitive). Used as
  # a defensive shape check on both sides of the F6 session-resume
  # round-trip — see D8 in TODO for the wedge mode this prevents.
  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  defp uuid_shape?(s) when is_binary(s), do: Regex.match?(@uuid_regex, s)
  defp uuid_shape?(_), do: false
end
