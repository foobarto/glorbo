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
         env <- build_env(provider.env, substitutions, reply_path, invocation_id, ctx),
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
        parent = Path.dirname(reply_path)
        fs.mkdir_p!.(parent)
        File.write!(reply_path, strip_ansi(stdout))
        :ok
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
      # Cap stdout so a flood doesn't drown the logs.
      snippet = stdout |> to_string() |> String.slice(0, 2_000)

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
    case fs.stat.(path) do
      {:ok, %{size: 0}} ->
        {:error, :reply_file_empty}

      {:ok, %{size: size}} when size > max_bytes ->
        {:error, {:reply_file_too_large, size, max_bytes}}

      {:ok, %{size: size}} when size <= max_bytes ->
        case fs.read.(path) do
          {:ok, contents} -> {:ok, strip_ansi(contents)}
          {:error, reason} -> {:error, {:reply_file_read_error, reason}}
        end

      {:error, :enoent} ->
        {:error, :reply_file_missing}

      {:error, reason} ->
        {:error, {:reply_file_stat_error, reason}}
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
  def strip_ansi(text) when is_binary(text), do: String.replace(text, @ansi_re, "")
  def strip_ansi(other), do: other

  # ---------------------------------------------------------------------------
  # Env composition
  # ---------------------------------------------------------------------------

  defp build_env(provider_env, substitutions, reply_path, invocation_id, ctx) do
    expanded =
      Map.new(provider_env, fn {k, v} -> {k, expand(v, substitutions)} end)

    Map.merge(expanded, %{
      "GLORBO_TASK_ID" => Map.get(ctx, :task_id, ""),
      "GLORBO_INVOCATION_ID" => invocation_id,
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
    })
  end

  # ---------------------------------------------------------------------------
  # Invocation (via injected run_fun)
  # ---------------------------------------------------------------------------

  defp run(provider, args, env, ctx, opts) do
    run_fun = Keyword.get(opts, :run_fun, &default_run_fun/4)

    run_opts_map = %{
      cli_binary: provider.resolved_path || provider.binary,
      cli_args: args,
      prompt: Map.get(ctx, :prompt, ""),
      usage_dir: usage_dir_for(provider, ctx)
    }

    case run_fun.(args, env, Map.get(ctx, :bwrap_opts, %{}), run_opts_map) do
      {:ok, m} when is_map(m) -> {:ok, m}
      {:error, _} = err -> err
      other -> {:error, {:run_fun_bad_return, other}}
    end
  end

  defp usage_dir_for(%Provider{usage_path: nil}, _ctx), do: nil

  defp usage_dir_for(%Provider{usage_path: %{kind: :jsonl_latest_in_dir, path: path}}, ctx) do
    expand(path, base_substitutions(ctx))
  end

  defp usage_dir_for(%Provider{usage_path: %{kind: :jsonl_file, path: path}}, ctx) do
    path |> expand(base_substitutions(ctx)) |> Path.dirname()
  end

  defp usage_dir_for(%Provider{usage_path: %{kind: :stdout}}, _ctx), do: nil

  defp base_substitutions(ctx) do
    %{
      "model" => Map.get(ctx, :model, ""),
      "workspace" => ctx.workspace,
      "prompt_path" => Map.get(ctx, :prompt_path, "")
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
