defmodule Glorbo.CLI.Harness do
  @moduledoc """
  First-party native-provider harness (GEP-32 phase 1).

  Invoked inside the agent sandbox as:

      glorbo harness --provider <alias> --agent <slug> --task <id> --model <model>

  The prompt is read from stdin, the final assistant reply is written to
  `$GLORBO_REPLY_PATH`, and usage telemetry is written to
  `$GLORBO_USAGE_PATH`.
  """

  alias Glorbo.CLI.Registry.Loader
  alias Glorbo.CLI.Registry.Provider

  @switches [
    provider: :string,
    agent: :string,
    task: :string,
    model: :string,
    help: :boolean
  ]

  @http_profile :glorbo_harness
  @max_tool_calls 50
  @default_http_timeout_ms 120_000
  @default_workspace "/workspace"

  @type runtime_config :: %{
          provider: String.t(),
          agent: String.t(),
          task: String.t(),
          model: String.t(),
          workspace: String.t(),
          endpoint: String.t(),
          auth: Provider.auth_mode() | nil,
          reply_path: String.t(),
          usage_path: String.t()
        }

  @spec run([String.t()], keyword()) :: Glorbo.CLI.result()
  def run(argv, opts \\ []) do
    {parsed, _positional, _invalid} = OptionParser.parse(argv, strict: @switches)

    if parsed[:help], do: {:harness, 0, help_text()}, else: do_run(parsed, opts)
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo harness — internal OpenAI-compatible provider harness (GEP-32).

    USAGE
      glorbo harness --provider <alias> --agent <slug> --task <id> --model <model>

    BEHAVIOR
      Reads the dispatch prompt from stdin, calls the provider's
      /v1/chat/completions endpoint, writes the final reply to
      $GLORBO_REPLY_PATH, and writes usage telemetry to
      $GLORBO_USAGE_PATH.
    """
  end

  defp do_run(parsed, opts) do
    with {:ok, args} <- parse_args(parsed),
         {:ok, prompt} <- read_prompt(opts),
         {:ok, provider} <- resolve_provider(args.provider, opts),
         {:ok, config} <- build_runtime_config(args, provider, opts),
         {:ok, result} <- converse(prompt, config, opts),
         :ok <- safe_write(config.reply_path, result.reply),
         :ok <- safe_write(config.usage_path, Jason.encode!(result.usage)) do
      {:harness, 0, ""}
    else
      {:error, reason} ->
        {:harness, 2, "glorbo harness failed: #{format_error(reason)}\n"}
    end
  end

  defp parse_args(parsed) do
    args = %{
      provider: parsed[:provider],
      agent: parsed[:agent],
      task: parsed[:task],
      model: parsed[:model]
    }

    missing =
      args
      |> Enum.flat_map(fn
        {key, nil} -> [key]
        {key, ""} -> [key]
        _ -> []
      end)

    if missing == [] do
      {:ok, Map.new(args, fn {k, v} -> {k, to_string(v)} end)}
    else
      {:error, {:missing_args, missing}}
    end
  end

  defp read_prompt(opts) do
    case Keyword.get(opts, :prompt_fun, fn -> IO.read(:stdio, :all) end).() do
      data when is_binary(data) -> {:ok, data}
      :eof -> {:ok, ""}
      other -> {:error, {:invalid_prompt, other}}
    end
  end

  defp resolve_provider(name, opts) when is_binary(name) do
    provider_fun =
      Keyword.get(opts, :provider_fun, fn provider_name ->
        Loader.load_all!(user_file: nil) |> Enum.find(&(&1.name == provider_name))
      end)

    case provider_fun.(name) do
      %Provider{kind: :native} = provider -> {:ok, provider}
      %Provider{} -> {:error, {:provider_not_native, name}}
      nil -> runtime_provider_from_env(name, opts)
    end
  end

  defp runtime_provider_from_env(name, opts) do
    env = env_fun(opts)

    case {blank_to_nil(env.("GLORBO_NATIVE_ENDPOINT")), blank_to_nil(env.("GLORBO_NATIVE_AUTH"))} do
      {endpoint, auth} when is_binary(endpoint) and is_binary(auth) ->
        with {:ok, parsed_auth} <- parse_auth(auth) do
          {:ok,
           %Provider{
             name: name,
             kind: :native,
             endpoint: endpoint,
             auth: parsed_auth,
             source: :user,
             source_file: "<runtime>"
           }}
        end

      _ ->
        {:error, {:unknown_provider, name}}
    end
  end

  defp build_runtime_config(args, provider, opts) do
    env = env_fun(opts)

    with {:ok, reply_path} <- require_env(env, "GLORBO_REPLY_PATH"),
         {:ok, usage_path} <- require_env(env, "GLORBO_USAGE_PATH"),
         {:ok, auth} <- parse_auth(blank_to_nil(env.("GLORBO_NATIVE_AUTH")) || provider.auth),
         {:ok, credentials} <- load_credentials(args.provider, opts),
         {:ok, endpoint} <-
           resolve_endpoint(
             blank_to_nil(env.("GLORBO_NATIVE_ENDPOINT")) || provider.endpoint,
             credentials
           ),
         :ok <- validate_auth(auth, args.provider, credentials) do
      {:ok,
       %{
         provider: args.provider,
         agent: args.agent,
         task: args.task,
         model: args.model,
         workspace: env.("GLORBO_WORKSPACE") || @default_workspace,
         endpoint: endpoint,
         auth: auth,
         reply_path: reply_path,
         usage_path: usage_path,
         credentials: credentials
       }}
    end
  end

  defp converse(prompt, config, opts) do
    started_at = monotonic_ms(opts)
    initial_messages = [%{"role" => "user", "content" => prompt}]
    initial_usage = %{tracked?: true, prompt_tokens: 0, completion_tokens: 0, model: nil}

    with {:ok, %{reply: reply, usage: usage}} <-
           loop(initial_messages, config, initial_usage, %{}, 0, opts) do
      duration_ms = max(monotonic_ms(opts) - started_at, 0)

      {:ok,
       %{
         reply: reply,
         usage:
           Map.put(
             usage,
             :duration_ms,
             duration_ms
           )
       }}
    end
  end

  defp loop(messages, config, usage_acc, tool_counts, total_tool_calls, opts) do
    with {:ok, response} <- chat_completion(messages, config, opts),
         {:ok, message, next_usage_acc} <- extract_message(response, usage_acc) do
      tool_calls = Map.get(message, "tool_calls") || []

      case tool_calls do
        [] ->
          case normalize_content(Map.get(message, "content")) do
            "" ->
              {:error, :empty_reply}

            reply ->
              {:ok, %{reply: reply, usage: build_usage(next_usage_acc, tool_counts, config)}}
          end

        calls when is_list(calls) ->
          next_total = total_tool_calls + length(calls)

          if next_total > @max_tool_calls do
            {:error, {:tool_call_limit_exceeded, next_total}}
          else
            assistant_message = %{
              "role" => "assistant",
              "content" => Map.get(message, "content"),
              "tool_calls" => calls
            }

            {tool_messages, next_counts} = execute_tool_calls(calls, tool_counts, config, opts)

            loop(
              messages ++ [assistant_message] ++ tool_messages,
              config,
              next_usage_acc,
              next_counts,
              next_total,
              opts
            )
          end
      end
    end
  end

  defp chat_completion(messages, config, opts) do
    request = %{
      url: chat_url(config.endpoint),
      headers: auth_headers(config),
      body: %{
        "model" => config.model,
        "messages" => messages,
        "tools" => [read_file_tool()],
        "tool_choice" => "auto",
        "stream" => false
      },
      timeout_ms: Keyword.get(opts, :http_timeout_ms, @default_http_timeout_ms)
    }

    chat_fun = Keyword.get(opts, :chat_fun, &default_chat_fun/1)

    case chat_fun.(request) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} when status in [401, 403] ->
        {:error, {:auth, status, error_detail(body)}}

      {:ok, %{status: 429, body: body}} ->
        {:error, {:rate_limited, error_detail(body)}}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        {:error, {:upstream, status, error_detail(body)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, error_detail(body)}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}

      other ->
        {:error, {:bad_chat_return, other}}
    end
  end

  defp default_chat_fun(request) do
    result =
      with {:ok, _} <- ensure_started(:inets),
           {:ok, _} <- ensure_started(:ssl),
           {:ok, _pid} <- start_http_profile(),
           :ok <- configure_proxy(request.url) do
        do_http_request(request)
      end

    stop_http_profile()
    result
  end

  defp ensure_started(app) do
    case Application.ensure_all_started(app) do
      {:ok, started} -> {:ok, started}
      other -> other
    end
  end

  defp start_http_profile do
    case :inets.start(:httpc, [{:profile, @http_profile}]) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp stop_http_profile do
    _ = :inets.stop(:httpc, @http_profile)
    :ok
  end

  defp configure_proxy(url) do
    scheme = URI.parse(url).scheme || "https"
    env_key = if scheme == "https", do: "HTTPS_PROXY", else: "HTTP_PROXY"

    case blank_to_nil(System.get_env(env_key) || System.get_env(String.downcase(env_key))) do
      nil ->
        :ok

      proxy_url ->
        case proxy_option(scheme, proxy_url) do
          {:ok, option} -> :httpc.set_options([option], @http_profile)
          {:error, _} = err -> err
        end
    end
  end

  defp proxy_option("https", proxy_url) do
    with {:ok, host, port} <- parse_proxy_url(proxy_url) do
      {:ok, {:https_proxy, {{String.to_charlist(host), port}, []}}}
    end
  end

  defp proxy_option(_scheme, proxy_url) do
    with {:ok, host, port} <- parse_proxy_url(proxy_url) do
      {:ok, {:proxy, {{String.to_charlist(host), port}, []}}}
    end
  end

  defp parse_proxy_url(proxy_url) when is_binary(proxy_url) do
    uri = URI.parse(proxy_url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, {:invalid_proxy_url, proxy_url}}

      is_nil(uri.host) or is_nil(uri.port) ->
        {:error, {:invalid_proxy_url, proxy_url}}

      true ->
        {:ok, uri.host, uri.port}
    end
  end

  defp do_http_request(request) do
    headers =
      Enum.map(request.headers, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    body = Jason.encode!(request.body)
    http_options = http_options(request.url, request.timeout_ms)

    case :httpc.request(
           :post,
           {String.to_charlist(request.url), headers, ~c"application/json", body},
           http_options,
           [body_format: :binary],
           @http_profile
         ) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:ok, %{status: status, body: decode_response_body(response_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_options(url, timeout_ms) do
    base = [timeout: timeout_ms, connect_timeout: timeout_ms]

    if String.starts_with?(url, "https://") do
      Keyword.put(base, :ssl, :httpc.ssl_verify_host_options(true))
    else
      base
    end
  end

  defp decode_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp extract_message(response, usage_acc) do
    with [%{"message" => message} | _] <- Map.get(response, "choices"),
         true <- is_map(message) do
      {:ok, message, merge_usage(usage_acc, response)}
    else
      _ -> {:error, :invalid_chat_response}
    end
  end

  defp merge_usage(%{tracked?: false} = acc, response) do
    %{acc | model: Map.get(response, "model") || acc.model}
  end

  defp merge_usage(acc, response) do
    case Map.get(response, "usage") do
      %{"prompt_tokens" => prompt, "completion_tokens" => completion}
      when is_integer(prompt) and prompt >= 0 and is_integer(completion) and completion >= 0 ->
        %{
          acc
          | prompt_tokens: acc.prompt_tokens + prompt,
            completion_tokens: acc.completion_tokens + completion,
            model: Map.get(response, "model") || acc.model
        }

      _ ->
        %{acc | tracked?: false, model: Map.get(response, "model") || acc.model}
    end
  end

  defp build_usage(%{tracked?: false, model: model}, tool_counts, config) do
    %{
      tracked: false,
      prompt_tokens: 0,
      completion_tokens: 0,
      model: model || config.model,
      tool_calls: tool_counts
    }
  end

  defp build_usage(acc, tool_counts, config) do
    %{
      tracked: true,
      prompt_tokens: acc.prompt_tokens,
      completion_tokens: acc.completion_tokens,
      model: acc.model || config.model,
      tool_calls: tool_counts
    }
  end

  defp execute_tool_calls(calls, tool_counts, config, opts) do
    Enum.map_reduce(calls, tool_counts, fn call, acc ->
      {tool_result(call, config, opts), count_tool_call(acc, tool_name(call))}
    end)
  end

  defp tool_result(%{"id" => id} = call, config, opts) do
    payload = execute_tool(call, config, opts)

    %{
      "role" => "tool",
      "tool_call_id" => id,
      "content" => Jason.encode!(payload)
    }
  end

  defp tool_result(call, _config, _opts) do
    %{
      "role" => "tool",
      "tool_call_id" => Map.get(call, "id", "missing"),
      "content" => Jason.encode!(%{"ok" => false, "error" => "invalid_tool_call"})
    }
  end

  defp execute_tool(
         %{"function" => %{"name" => "read_file", "arguments" => arguments}},
         config,
         opts
       ) do
    case Jason.decode(arguments) do
      {:ok, %{"path" => raw_path}} when is_binary(raw_path) and raw_path != "" ->
        path = resolve_tool_path(raw_path, config.workspace)
        read_fun = Keyword.get(opts, :file_read_fun, &File.read/1)

        case read_fun.(path) do
          {:ok, contents} -> %{"ok" => true, "path" => path, "contents" => contents}
          {:error, reason} -> %{"ok" => false, "path" => path, "error" => inspect(reason)}
        end

      {:ok, _bad_args} ->
        %{"ok" => false, "error" => "missing_path"}

      {:error, _reason} ->
        %{"ok" => false, "error" => "invalid_arguments"}
    end
  end

  defp execute_tool(%{"function" => %{"name" => name}}, _config, _opts) do
    %{"ok" => false, "error" => "unknown_tool:#{name}"}
  end

  defp execute_tool(_call, _config, _opts), do: %{"ok" => false, "error" => "invalid_tool_call"}

  defp tool_name(%{"function" => %{"name" => name}}) when is_binary(name), do: name
  defp tool_name(_), do: "unknown"

  defp count_tool_call(counts, name) do
    Map.update(counts, name, 1, &(&1 + 1))
  end

  defp resolve_tool_path(path, workspace) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path, workspace)
    end
  end

  defp read_file_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "read_file",
        "description" => "Read a file visible inside the current sandbox.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Absolute sandbox path or path relative to the workspace."
            }
          },
          "required" => ["path"],
          "additionalProperties" => false
        }
      }
    }
  end

  defp auth_headers(config) do
    [{"content-type", "application/json"}, {"accept", "application/json"}] ++
      auth_headers_for(config.auth, Map.get(config, :credentials, %{}))
  end

  defp auth_headers_for(:none, _credentials), do: []

  defp auth_headers_for(:bearer, credentials) do
    key = Map.get(credentials, "api_key")
    extras = Map.get(credentials, "extras", %{})

    [{"authorization", "Bearer " <> key}] ++
      maybe_extra_header("openai-organization", extras["organization"]) ++
      maybe_extra_header("openai-project", extras["project"])
  end

  defp auth_headers_for(:api_key, credentials) do
    [{"api-key", Map.fetch!(credentials, "api_key")}]
  end

  defp maybe_extra_header(_header, nil), do: []
  defp maybe_extra_header(_header, ""), do: []
  defp maybe_extra_header(header, value), do: [{header, to_string(value)}]

  defp resolve_endpoint(nil, _credentials), do: {:error, :missing_endpoint}
  defp resolve_endpoint("", _credentials), do: {:error, :missing_endpoint}

  defp resolve_endpoint(endpoint, credentials) when is_binary(endpoint) do
    {:ok, Map.get(credentials, "endpoint") || endpoint}
  end

  defp validate_auth(:none, _provider, _credentials), do: :ok

  defp validate_auth(_auth, provider, credentials) do
    case Map.get(credentials, "api_key") do
      key when is_binary(key) and key != "" -> :ok
      _ -> {:error, {:missing_api_key, provider}}
    end
  end

  defp load_credentials(provider, opts) do
    read_fun = Keyword.get(opts, :credentials_read_fun, &File.read/1)
    path = credentials_path(provider, opts)

    case path do
      nil ->
        {:ok, %{}}

      _ ->
        case read_fun.(path) do
          {:ok, raw} ->
            case Toml.decode(raw) do
              {:ok, map} when is_map(map) -> {:ok, map}
              {:error, reason} -> {:error, {:invalid_credentials_toml, reason}}
            end

          {:error, :enoent} ->
            {:ok, %{}}

          {:error, reason} ->
            {:error, {:credentials_read_failed, reason}}
        end
    end
  end

  defp credentials_path(provider, opts) do
    env = env_fun(opts)

    blank_to_nil(env.("GLORBO_NATIVE_CREDENTIALS_PATH")) ||
      Path.join(credentials_dir(env), "#{provider}.toml")
  end

  defp credentials_dir(env_fun) do
    env_fun.("GLORBO_CREDENTIALS_DIR") || Glorbo.Filesystem.Hierarchy.native_credentials_dir()
  end

  defp require_env(env_fun, key) do
    case blank_to_nil(env_fun.(key)) do
      nil -> {:error, {:missing_env, key}}
      value -> {:ok, value}
    end
  end

  defp env_fun(opts) do
    Keyword.get(opts, :env_fun, &System.get_env/1)
  end

  defp parse_auth(nil), do: {:ok, nil}
  defp parse_auth(:none), do: {:ok, :none}
  defp parse_auth(:bearer), do: {:ok, :bearer}
  defp parse_auth(:api_key), do: {:ok, :api_key}
  defp parse_auth("none"), do: {:ok, :none}
  defp parse_auth("bearer"), do: {:ok, :bearer}
  defp parse_auth("api_key"), do: {:ok, :api_key}
  defp parse_auth("api-key"), do: {:ok, :api_key}
  defp parse_auth(other), do: {:error, {:invalid_auth, other}}

  defp normalize_content(nil), do: ""
  defp normalize_content(content) when is_binary(content), do: String.trim(content)

  defp normalize_content(content) when is_list(content) do
    content
    |> Enum.map_join(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> String.trim()
  end

  defp normalize_content(other), do: to_string(other) |> String.trim()

  defp chat_url(endpoint) do
    endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>("/chat/completions")
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(other), do: other

  defp monotonic_ms(opts) do
    Keyword.get(opts, :clock_fun, fn -> System.monotonic_time(:millisecond) end).()
  end

  defp error_detail(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_detail(%{"error" => message}) when is_binary(message), do: message
  defp error_detail(body) when is_binary(body), do: body
  defp error_detail(_body), do: nil

  defp format_error({:missing_args, keys}) do
    "missing required args: " <> Enum.map_join(keys, ", ", &to_string/1)
  end

  defp format_error({:missing_env, key}), do: "missing #{key}"
  defp format_error({:unknown_provider, name}), do: "unknown native provider #{name}"
  defp format_error({:provider_not_native, name}), do: "#{name} is not a native provider"
  defp format_error({:invalid_auth, auth}), do: "invalid native auth #{inspect(auth)}"
  defp format_error({:missing_api_key, provider}), do: "missing api_key for #{provider}"
  defp format_error(:missing_endpoint), do: "missing native endpoint"

  defp format_error({:auth, status, detail}),
    do: "provider auth failed (HTTP #{status})#{maybe_suffix(detail)}"

  defp format_error({:rate_limited, detail}),
    do: "provider rate-limited#{maybe_suffix(detail)}"

  defp format_error({:upstream, status, detail}),
    do: "provider upstream failed (HTTP #{status})#{maybe_suffix(detail)}"

  defp format_error({:http_status, status, detail}),
    do: "provider returned HTTP #{status}#{maybe_suffix(detail)}"

  defp format_error({:http_request_failed, reason}),
    do: "request failed: #{inspect(reason)}"

  defp format_error({:credentials_read_failed, reason}),
    do: "could not read credentials: #{inspect(reason)}"

  defp format_error({:invalid_credentials_toml, reason}),
    do: "invalid credentials TOML: #{inspect(reason)}"

  defp format_error({:tool_call_limit_exceeded, total}),
    do: "tool-call limit exceeded (#{total} > #{@max_tool_calls})"

  defp format_error(:invalid_chat_response), do: "provider returned an invalid chat response"
  defp format_error(:empty_reply), do: "provider returned an empty reply"
  defp format_error({:bad_chat_return, other}), do: "bad chat_fun return: #{inspect(other)}"
  defp format_error({:invalid_prompt, other}), do: "invalid prompt input: #{inspect(other)}"
  defp format_error({:invalid_proxy_url, proxy_url}), do: "invalid proxy URL #{proxy_url}"
  defp format_error(other), do: inspect(other)

  defp maybe_suffix(nil), do: ""
  defp maybe_suffix(""), do: ""
  defp maybe_suffix(detail), do: ": #{detail}"

  defp safe_write(path, contents) when is_binary(path) and is_binary(contents) do
    File.mkdir_p!(Path.dirname(path))

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        File.write!(path, contents)
        :ok

      {:ok, %File.Stat{type: other}} ->
        {:error, {:write_target_not_regular, path, other}}

      {:error, :enoent} ->
        File.write!(path, contents)
        :ok

      {:error, reason} ->
        {:error, {:write_target_stat_failed, path, reason}}
    end
  end
end
