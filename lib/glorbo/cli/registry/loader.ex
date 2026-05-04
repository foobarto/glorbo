defmodule Glorbo.CLI.Registry.Loader do
  @moduledoc """
  Loads provider definitions from TOML (GEP-8 §6, §7.1).

  Two populations:

    * **Built-ins** — one file per provider under `priv/providers/*.toml`,
      tagged `source: :builtin`.
    * **User** — optional `~/.glorbo/providers.toml` with an optional
      `[[providers]]` array-of-tables, tagged `source: :user`.

  Both files use the same schema (`Glorbo.CLI.Registry.Provider`).
  Validation is strict and hard-fails at load (GEP-8 D9): a malformed
  registry is worse than a loud crash.

  User entries default `allow_version_probe = false` (GEP-8 D13). Built-in
  entries default `allow_version_probe = true`. Either can override via
  TOML.
  """

  alias Glorbo.CLI.Parsers
  alias Glorbo.CLI.PathTransforms
  alias Glorbo.CLI.Registry.Provider

  @common_required_fields ~w(name)
  @cli_required_fields ~w(binary args reply_dir reply_filename_template)
  @native_required_fields ~w(endpoint auth usage_parser)

  @type load_result :: {:ok, [Provider.t()]} | {:error, term()}

  @doc """
  Load all providers from built-in and user locations. Raises on any
  validation error.

  Options:

    * `:builtin_dir` — directory containing `priv/providers/*.toml`
      (default: `:glorbo` app's `priv/providers`).
    * `:user_file` — path to the optional user TOML
      (default: `~/.glorbo/providers.toml`).
  """
  @spec load_all!(keyword()) :: [Provider.t()]
  def load_all!(opts \\ []) do
    case load_all(opts) do
      {:ok, providers} -> providers
      {:error, reason} -> raise ArgumentError, format_error(reason)
    end
  end

  @doc """
  Load all providers; returns `{:ok, list}` or `{:error, reason}` rather
  than raising. Preferred for tests.
  """
  @spec load_all(keyword()) :: load_result()
  def load_all(opts \\ []) do
    builtin_dir = Keyword.get(opts, :builtin_dir, default_builtin_dir())
    user_file = Keyword.get(opts, :user_file, default_user_file())

    with {:ok, builtins} <- load_dir(builtin_dir, :builtin),
         {:ok, users} <- load_user_file(user_file) do
      check_duplicates(builtins ++ users)
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in directory
  # ---------------------------------------------------------------------------

  defp load_dir(dir, source) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".toml"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> load_files(source)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:builtin_dir_unreadable, dir, reason}}
    end
  end

  defp load_files(paths, source) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case load_file(path, source) do
        {:ok, provider} -> {:cont, {:ok, [provider | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp load_file(path, source) do
    with {:ok, raw} <- File.read(path) |> wrap_read(path),
         {:ok, parsed} <- parse_toml(raw, path) do
      build_provider(parsed, path, source)
    end
  end

  defp wrap_read({:ok, raw}, _path), do: {:ok, raw}
  defp wrap_read({:error, reason}, path), do: {:error, {:read_error, path, reason}}

  defp parse_toml(raw, path) do
    case Toml.decode(raw) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, {:toml_parse_error, path, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # User file
  # ---------------------------------------------------------------------------

  defp load_user_file(nil), do: {:ok, []}

  defp load_user_file(path) do
    case File.read(path) do
      {:ok, raw} ->
        with {:ok, parsed} <- parse_toml(raw, path) do
          extract_user_providers(parsed, path)
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:read_error, path, reason}}
    end
  end

  defp extract_user_providers(%{"providers" => list}, path) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn raw, {:ok, acc} ->
      case build_provider(raw, path, :user) do
        {:ok, provider} -> {:cont, {:ok, [provider | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp extract_user_providers(%{"providers" => _other}, path) do
    {:error, {:invalid_shape, path, "`providers` must be an array of tables"}}
  end

  defp extract_user_providers(%{}, _path), do: {:ok, []}

  # ---------------------------------------------------------------------------
  # Provider construction
  # ---------------------------------------------------------------------------

  defp build_provider(raw, path, source) when is_map(raw) do
    with {:ok, kind} <- parse_kind(raw, path),
         :ok <- check_required(raw, path, kind),
         {:ok, binary} <- parse_binary(raw, path, kind),
         {:ok, prompt_mode} <- parse_prompt_mode(raw, path),
         {:ok, args} <- parse_args(raw, path, kind),
         {:ok, env} <- parse_env(raw, path),
         {:ok, reply_dir} <- parse_reply_dir(raw, path, kind),
         {:ok, reply_filename_template} <- parse_reply_filename_template(raw, path, kind),
         {:ok, reply_max_bytes} <- parse_reply_max_bytes(raw, path),
         {:ok, endpoint} <- parse_endpoint(raw, path, kind),
         {:ok, auth} <- parse_auth(raw, path, kind),
         {:ok, model_list} <- parse_model_list(raw, path),
         {:ok, version_regex} <- parse_version_regex(raw, path),
         {:ok, usage_parser} <- parse_usage_parser(raw, path, kind),
         {:ok, usage_path} <- parse_usage_path(raw, path),
         {:ok, path_transforms} <- parse_path_transforms(raw, path),
         {:ok, auth_binds} <- parse_auth_binds(raw, path),
         {:ok, fallback_paths} <- parse_fallback_paths(raw, path) do
      provider = %Provider{
        name: raw["name"],
        kind: kind,
        binary: binary,
        args: args,
        prompt_mode: prompt_mode,
        env: env,
        reply_dir: reply_dir,
        reply_filename_template: reply_filename_template,
        reply_max_bytes: reply_max_bytes,
        endpoint: endpoint,
        auth: auth,
        model_list: model_list,
        version_flag: raw["version_flag"] || "",
        version_regex: version_regex,
        allow_version_probe: parse_allow_probe(raw, source),
        usage_parser: usage_parser,
        usage_path: usage_path,
        path_transforms: path_transforms,
        auth_binds: auth_binds,
        fallback_paths: fallback_paths,
        source: source,
        source_file: path
      }

      {:ok, provider}
    end
  end

  defp parse_kind(raw, path) do
    value = Map.get(raw, "kind", "cli")

    case provider_kind_from_string(value) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, {:invalid_kind, path, value}}
    end
  end

  defp provider_kind_from_string("cli"), do: {:ok, :cli}
  defp provider_kind_from_string("native"), do: {:ok, :native}
  defp provider_kind_from_string(_), do: :error

  defp check_required(raw, path, kind) do
    missing =
      kind
      |> required_fields_for()
      |> Enum.reject(&Map.has_key?(raw, &1))

    case missing do
      [] -> :ok
      [field | _] -> {:error, {:missing_field, path, field}}
    end
  end

  defp required_fields_for(:cli), do: @common_required_fields ++ @cli_required_fields
  defp required_fields_for(:native), do: @common_required_fields ++ @native_required_fields

  defp parse_binary(%{"binary" => value}, _path, _kind) when is_binary(value), do: {:ok, value}

  defp parse_binary(%{"binary" => _}, path, _kind) do
    {:error, {:invalid_binary, path, "`binary` must be a string"}}
  end

  defp parse_binary(_raw, _path, :native), do: {:ok, nil}

  defp parse_binary(_raw, path, :cli) do
    {:error, {:missing_field, path, "binary"}}
  end

  # GEP-12 compliance: map TOML strings to atoms via a closed set, never
  # String.to_atom on user input. `acp` lands here as part of GEP-45
  # Phase 1a: provider TOML accepts the mode + the dispatcher recognises
  # it as unimplemented. Phase 1b replaces the dispatcher stub with the
  # actual JSON-RPC client.
  @prompt_mode_map %{
    "stdin" => :stdin,
    "stdin_dash" => :stdin_dash,
    "argv" => :argv,
    "tmpfile_argv" => :tmpfile_argv,
    "acp" => :acp
  }

  defp parse_prompt_mode(raw, path) do
    value = Map.get(raw, "prompt_mode", "stdin")

    case Map.fetch(@prompt_mode_map, value) do
      {:ok, mode} -> {:ok, mode}
      :error -> {:error, {:invalid_prompt_mode, path, value}}
    end
  end

  defp parse_args(%{"args" => list}, path, _kind) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      {:ok, list}
    else
      {:error, {:invalid_args, path, "all `args` entries must be strings"}}
    end
  end

  defp parse_args(%{"args" => _other}, path, _kind) do
    {:error, {:invalid_args, path, "`args` must be a list"}}
  end

  defp parse_args(_raw, _path, :native), do: {:ok, []}

  defp parse_args(_raw, path, :cli) do
    {:error, {:missing_field, path, "args"}}
  end

  defp parse_env(%{"env" => map}, path) when is_map(map) do
    if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, map}
    else
      {:error, {:invalid_env, path, "all `env` values must be strings"}}
    end
  end

  defp parse_env(%{"env" => _other}, path) do
    {:error, {:invalid_env, path, "`env` must be a table"}}
  end

  defp parse_env(_raw, _path), do: {:ok, %{}}

  defp parse_reply_dir(%{"reply_dir" => value}, _path, _kind) when is_binary(value),
    do: {:ok, value}

  defp parse_reply_dir(%{"reply_dir" => _}, path, _kind) do
    {:error, {:invalid_reply_dir, path, "`reply_dir` must be a string"}}
  end

  defp parse_reply_dir(_raw, _path, :native), do: {:ok, "{workspace}/.glorbo/outbox"}

  defp parse_reply_dir(_raw, path, :cli) do
    {:error, {:missing_field, path, "reply_dir"}}
  end

  defp parse_reply_filename_template(%{"reply_filename_template" => value}, _path, _kind)
       when is_binary(value),
       do: {:ok, value}

  defp parse_reply_filename_template(%{"reply_filename_template" => _}, path, _kind) do
    {:error,
     {:invalid_reply_filename_template, path, "`reply_filename_template` must be a string"}}
  end

  defp parse_reply_filename_template(_raw, _path, :native),
    do: {:ok, "{timestamp}-{invocation_id}.md"}

  defp parse_reply_filename_template(_raw, path, :cli) do
    {:error, {:missing_field, path, "reply_filename_template"}}
  end

  defp parse_reply_max_bytes(%{"reply_max_bytes" => n}, _path)
       when is_integer(n) and n > 0 do
    {:ok, n}
  end

  defp parse_reply_max_bytes(%{"reply_max_bytes" => _}, path) do
    {:error, {:invalid_reply_max_bytes, path, "must be a positive integer"}}
  end

  defp parse_reply_max_bytes(_raw, _path), do: {:ok, 1_048_576}

  defp parse_endpoint(%{"endpoint" => value}, _path, _kind) when is_binary(value),
    do: {:ok, value}

  defp parse_endpoint(%{"endpoint" => _}, path, _kind) do
    {:error, {:invalid_endpoint, path, "`endpoint` must be a string"}}
  end

  defp parse_endpoint(_raw, _path, :cli), do: {:ok, nil}

  defp parse_endpoint(_raw, path, :native) do
    {:error, {:missing_field, path, "endpoint"}}
  end

  @auth_map %{"none" => :none, "bearer" => :bearer, "api-key" => :api_key}

  defp parse_auth(%{"auth" => value}, path, _kind) when is_binary(value) do
    case Map.fetch(@auth_map, value) do
      {:ok, auth} -> {:ok, auth}
      :error -> {:error, {:invalid_auth, path, value}}
    end
  end

  defp parse_auth(%{"auth" => _}, path, _kind) do
    {:error, {:invalid_auth, path, "must be a string"}}
  end

  defp parse_auth(_raw, _path, :cli), do: {:ok, nil}

  defp parse_auth(_raw, path, :native) do
    {:error, {:missing_field, path, "auth"}}
  end

  @model_list_shapes %{"openai" => :openai, "ollama" => :ollama, "none" => :none}

  defp parse_model_list(%{"model_list" => map}, path) when is_map(map) do
    shape_raw = Map.get(map, "shape", "none")
    path_raw = Map.get(map, "path")

    with {:ok, shape} <- parse_model_list_shape(shape_raw, path),
         :ok <- validate_model_list_path(shape, path_raw, path) do
      {:ok, %{shape: shape, path: path_raw}}
    end
  end

  defp parse_model_list(%{"model_list" => _}, path) do
    {:error, {:invalid_model_list, path, "`model_list` must be a table"}}
  end

  defp parse_model_list(_raw, _path), do: {:ok, nil}

  defp parse_model_list_shape(raw, path) do
    case Map.fetch(@model_list_shapes, raw) do
      {:ok, shape} -> {:ok, shape}
      :error -> {:error, {:invalid_model_list, path, "shape #{inspect(raw)} not supported"}}
    end
  end

  defp validate_model_list_path(shape, nil, _path) when shape in [:none], do: :ok

  defp validate_model_list_path(shape, value, _path)
       when shape in [:openai, :ollama] and is_binary(value),
       do: :ok

  defp validate_model_list_path(_shape, value, _path) when is_binary(value), do: :ok

  defp validate_model_list_path(shape, nil, path) when shape in [:openai, :ollama] do
    {:error, {:invalid_model_list, path, "path is required when shape != \"none\""}}
  end

  defp validate_model_list_path(_shape, _value, path) do
    {:error, {:invalid_model_list, path, "`model_list.path` must be a string"}}
  end

  defp parse_version_regex(%{"version_regex" => pattern}, path) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, _} -> {:ok, pattern}
      {:error, reason} -> {:error, {:invalid_version_regex, path, reason}}
    end
  end

  defp parse_version_regex(%{"version_regex" => _}, path) do
    {:error, {:invalid_version_regex, path, "must be a string"}}
  end

  defp parse_version_regex(_raw, _path), do: {:ok, nil}

  defp parse_usage_parser(raw, path, kind) do
    name = Map.get(raw, "usage_parser", "none")

    cond do
      not is_binary(name) ->
        {:error, {:unknown_usage_parser, path, name}}

      not Parsers.known?(name) ->
        {:error, {:unknown_usage_parser, path, name}}

      kind == :native and name == "none" ->
        {:error, {:invalid_native_usage_parser, path}}

      true ->
        {:ok, name}
    end
  end

  defp parse_usage_path(%{"usage_path" => map}, path) when is_map(map) do
    kind_str = Map.get(map, "kind")

    case usage_path_kind_from_string(kind_str) do
      {:ok, kind} ->
        {:ok, %{kind: kind, path: Map.get(map, "path")}}

      :error ->
        {:error, {:invalid_usage_path, path, "unknown kind: #{inspect(kind_str)}"}}
    end
  end

  defp parse_usage_path(_raw, _path), do: {:ok, nil}

  defp usage_path_kind_from_string("jsonl_latest_in_dir"), do: {:ok, :jsonl_latest_in_dir}
  defp usage_path_kind_from_string("jsonl_file"), do: {:ok, :jsonl_file}
  defp usage_path_kind_from_string("json_file"), do: {:ok, :json_file}
  defp usage_path_kind_from_string("stdout"), do: {:ok, :stdout}
  defp usage_path_kind_from_string(_), do: :error

  defp parse_path_transforms(%{"path_transforms" => map}, path) when is_map(map) do
    Enum.reduce_while(map, {:ok, []}, fn {name, spec}, {:ok, acc} ->
      case build_transform(name, spec, path) do
        {:ok, t} -> {:cont, {:ok, [t | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp parse_path_transforms(%{"path_transforms" => _}, path) do
    {:error, {:invalid_path_transforms, path, "must be a table"}}
  end

  defp parse_path_transforms(_raw, _path), do: {:ok, []}

  # GEP-8 auth_binds (TOML):
  #
  #     [[auth_binds]]
  #     host = "~/.claude"
  #     sandbox = "/workspace/.glorbo-claude"
  #     mode = "ro"
  #
  # Each entry declares a read-only or read-write bind-mount of a host
  # directory into the bwrap sandbox. Dispatch reads these, expands
  # `~`/`$HOME`, filters to entries whose host path exists, and passes
  # them through to `Glorbo.Sandbox.Bwrap.start/2` via `cli_auth_binds`.
  defp parse_auth_binds(%{"auth_binds" => list}, path) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case build_auth_bind(entry, path) do
        {:ok, bind} -> {:cont, {:ok, [bind | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp parse_auth_binds(%{"auth_binds" => _}, path) do
    {:error, {:invalid_auth_binds, path, "must be an array of tables"}}
  end

  defp parse_auth_binds(_raw, _path), do: {:ok, []}

  defp build_auth_bind(%{"host" => host, "sandbox" => sandbox} = entry, path)
       when is_binary(host) and is_binary(sandbox) do
    # Closed mapping — never String.to_atom on user input (GEP-12 / T-03-15).
    case Map.get(entry, "mode", "ro") do
      "ro" ->
        {:ok, %{host: host, sandbox: sandbox, mode: :ro}}

      "rw" ->
        {:ok, %{host: host, sandbox: sandbox, mode: :rw}}

      other ->
        {:error,
         {:invalid_auth_binds, path, "unknown mode #{inspect(other)} (use \"ro\" or \"rw\")"}}
    end
  end

  defp build_auth_bind(_entry, path) do
    {:error, {:invalid_auth_binds, path, "each entry needs host + sandbox fields"}}
  end

  # `fallback_paths` — well-known absolute paths to try when the PATH
  # lookup for `binary` misses. Useful for CLIs whose official installer
  # drops the binary outside a `$PATH`-standard directory (opencode's
  # `~/.opencode/bin/opencode`). `~` / `$HOME` expand in Detection, not
  # here, so the TOML stays user-agnostic. Validation is shape-only;
  # non-existent paths are a runtime concern.
  defp parse_fallback_paths(%{"fallback_paths" => list}, path) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      {:ok, list}
    else
      {:error, {:invalid_fallback_paths, path, "entries must be strings"}}
    end
  end

  defp parse_fallback_paths(%{"fallback_paths" => _non_list}, path) do
    {:error, {:invalid_fallback_paths, path, "must be a list of strings"}}
  end

  defp parse_fallback_paths(_raw, _path), do: {:ok, []}

  defp build_transform(name, %{"from" => from, "transform" => transform}, path)
       when is_binary(name) and is_binary(from) and is_binary(transform) do
    if PathTransforms.known?(transform) do
      {:ok, %{name: name, from: from, transform: transform}}
    else
      {:error, {:unknown_path_transform, path, transform}}
    end
  end

  defp build_transform(name, _spec, path) do
    {:error, {:invalid_path_transforms, path, "entry #{inspect(name)} missing from/transform"}}
  end

  defp parse_allow_probe(raw, source) do
    case Map.get(raw, "allow_version_probe") do
      nil -> source == :builtin
      bool when is_boolean(bool) -> bool
      _ -> source == :builtin
    end
  end

  # ---------------------------------------------------------------------------
  # Duplicate check
  # ---------------------------------------------------------------------------

  defp check_duplicates(providers) do
    grouped = Enum.group_by(providers, & &1.name)

    case Enum.find(grouped, fn {_name, list} -> length(list) > 1 end) do
      nil ->
        {:ok, providers}

      {name, [a, b | _]} ->
        {:error, {:duplicate_provider, name, a.source_file, b.source_file}}
    end
  end

  # ---------------------------------------------------------------------------
  # Defaults + error formatting
  # ---------------------------------------------------------------------------

  defp default_builtin_dir do
    Application.app_dir(:glorbo, "priv/providers")
  end

  defp default_user_file do
    path = Path.join(Glorbo.Filesystem.Hierarchy.default_root(), "providers.toml")
    if File.exists?(path), do: path, else: nil
  end

  @doc false
  def format_error({:toml_parse_error, path, reason}),
    do: "providers config error: #{path} #{inspect(reason)}"

  def format_error({:read_error, path, reason}),
    do: "providers config error: #{path} could not be read (#{inspect(reason)})"

  def format_error({:builtin_dir_unreadable, dir, reason}),
    do: "providers config error: built-in dir #{dir} (#{inspect(reason)})"

  def format_error({:missing_field, path, field}),
    do: "providers config error: #{path} missing required field `#{field}`"

  def format_error({:invalid_kind, path, value}),
    do:
      "providers config error: #{path} kind #{inspect(value)} not in #{inspect(Provider.kinds())}"

  def format_error({:invalid_binary, path, detail}),
    do: "providers config error: #{path} #{detail}"

  def format_error({:invalid_prompt_mode, path, value}),
    do:
      "providers config error: #{path} prompt_mode #{inspect(value)} not in #{inspect(Provider.prompt_modes())}"

  def format_error({:invalid_args, path, detail}),
    do: "providers config error: #{path} #{detail}"

  def format_error({:invalid_env, path, detail}),
    do: "providers config error: #{path} #{detail}"

  def format_error({:invalid_reply_dir, path, detail}),
    do: "providers config error: #{path} #{detail}"

  def format_error({:invalid_reply_filename_template, path, detail}),
    do: "providers config error: #{path} #{detail}"

  def format_error({:invalid_reply_max_bytes, path, detail}),
    do: "providers config error: #{path} reply_max_bytes #{detail}"

  def format_error({:invalid_endpoint, path, detail}),
    do: "providers config error: #{path} endpoint #{detail}"

  def format_error({:invalid_auth, path, value}),
    do:
      "providers config error: #{path} auth #{inspect(value)} not in #{inspect(Provider.auth_modes())}"

  def format_error({:invalid_model_list, path, detail}),
    do: "providers config error: #{path} model_list: #{detail}"

  def format_error({:invalid_version_regex, path, reason}),
    do: "providers config error: #{path} invalid version_regex: #{inspect(reason)}"

  def format_error({:unknown_usage_parser, path, name}),
    do: "providers config error: #{path} unknown usage_parser #{inspect(name)}"

  def format_error({:invalid_native_usage_parser, path}),
    do: "providers config error: #{path} native providers must declare a tracked usage_parser"

  def format_error({:invalid_usage_path, path, detail}),
    do: "providers config error: #{path} usage_path: #{detail}"

  def format_error({:invalid_path_transforms, path, detail}),
    do: "providers config error: #{path} path_transforms: #{detail}"

  def format_error({:unknown_path_transform, path, transform}),
    do: "providers config error: #{path} unknown path_transform #{inspect(transform)}"

  def format_error({:invalid_auth_binds, path, detail}),
    do: "providers config error: #{path} auth_binds: #{detail}"

  def format_error({:invalid_fallback_paths, path, detail}),
    do: "providers config error: #{path} fallback_paths: #{detail}"

  def format_error({:invalid_shape, path, detail}),
    do: "providers config error: #{path} #{detail}"

  def format_error({:duplicate_provider, name, file1, file2}),
    do: "duplicate provider \"#{name}\" declared in #{file1} and #{file2}"

  def format_error(other), do: "providers config error: #{inspect(other)}"
end
