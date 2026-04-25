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

  alias Glorbo.CLI.Lifecycle.Daemon
  alias Glorbo.CLI.Parsers
  alias Glorbo.CLI.PathTransforms
  alias Glorbo.CLI.Registry.Provider

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
  def invoke(%Provider{} = provider, %{} = ctx, opts \\ []) do
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
         :ok <- maybe_log_run_output(provider, run_result, reply_path, fs),
         :ok <- maybe_stdout_to_reply(run_result, reply_path, provider.reply_max_bytes, fs),
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

  defp prepare_reply_dir(dir, reply_path, fs) do
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
  # Matches the pattern used by StdoutStreamer (`/\x1B\[.../`); adding
  # OSC (window-title) and standalone CR/BEL suppression too.
  @ansi_re ~r/\x1B\[[0-9;?]*[A-Za-z]|\x1B\][^\x07]*\x07|[\r\x07]/

  @doc false
  def strip_ansi(text) when is_binary(text) do
    # Threatmodel: agent stdout is attacker-controlled and may contain
    # invalid UTF-8. `String.replace/3` raises ArgumentError on
    # non-UTF-8 binaries, which would propagate out of the dispatcher
    # and surface as a 500 in the LV that's reading replies. Coerce to
    # printable UTF-8 first — `:unicode.characters_to_binary/3` with
    # `:utf8 / :utf8` and the `:replace` fallback strategy substitutes
    # the U+FFFD replacement character for invalid bytes.
    safe =
      if String.valid?(text) do
        text
      else
        case :unicode.characters_to_binary(text, :latin1, :utf8) do
          bin when is_binary(bin) -> bin
          _ -> for <<b <- text>>, do: if(b < 128, do: <<b>>, else: "?"), into: ""
        end
      end

    String.replace(safe, @ansi_re, "")
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
          "GLORBO_NATIVE_ENDPOINT" => provider.endpoint || "",
          "GLORBO_NATIVE_AUTH" => to_string(provider.auth || ""),
          "GLORBO_NATIVE_CREDENTIALS_PATH" => "/creds/provider.toml",
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
    module = Parsers.module_for(name)
    source = resolve_source(usage_path, run_result, ctx, subs, provider)

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
end
