defmodule Glorbo.CLI.Harness do
  @moduledoc """
  First-party native-provider harness (GEP-32 phase 1).

  Invoked inside the agent sandbox as:

      glorbo harness --provider <alias> --agent <slug> --task <id> --model <model>

  The prompt is read from stdin, the final assistant reply is written to
  `$GLORBO_REPLY_PATH`, and usage telemetry is written to
  `$GLORBO_USAGE_PATH`.
  """

  alias Glorbo.CLI.Harness.Tools
  alias Glorbo.CLI.Harness.HTTP
  alias Glorbo.CLI.Registry.Loader
  alias Glorbo.CLI.Registry.Provider
  alias Glorbo.Providers.NativeConfig

  @switches [
    provider: :string,
    agent: :string,
    task: :string,
    model: :string,
    help: :boolean
  ]

  @default_http_timeout_ms 120_000
  @default_http_max_retries 3
  @default_web_fetch_timeout_ms 30_000
  @default_max_tool_calls_per_turn 50
  @default_workspace "/workspace"

  @type runtime_config :: %{
          provider: String.t(),
          agent: String.t(),
          task: String.t(),
          model: String.t(),
          workspace: String.t(),
          endpoint: String.t(),
          auth: Provider.auth_mode() | nil,
          http_timeout_ms: pos_integer(),
          http_max_retries: non_neg_integer(),
          web_fetch_timeout_ms: pos_integer(),
          max_tool_calls_per_turn: pos_integer(),
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
        with {:ok, parsed_auth} <- NativeConfig.parse_auth(auth) do
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
         {:ok, auth} <-
           NativeConfig.parse_auth(blank_to_nil(env.("GLORBO_NATIVE_AUTH")) || provider.auth),
         {:ok, credentials} <- load_credentials(args.provider, opts),
         {:ok, endpoint} <-
           NativeConfig.resolve_endpoint(
             blank_to_nil(env.("GLORBO_NATIVE_ENDPOINT")) || provider.endpoint,
             credentials
           ),
         http_timeout_ms <-
           parse_positive_seconds(env, "GLORBO_NATIVE_HTTP_TIMEOUT_S", @default_http_timeout_ms),
         http_max_retries <-
           parse_non_negative_integer(
             env,
             "GLORBO_NATIVE_HTTP_MAX_RETRIES",
             @default_http_max_retries
           ),
         web_fetch_timeout_ms <-
           parse_positive_seconds(
             env,
             "GLORBO_NATIVE_WEB_FETCH_TIMEOUT_S",
             @default_web_fetch_timeout_ms
           ),
         max_tool_calls_per_turn <-
           parse_positive_integer(
             env,
             "GLORBO_NATIVE_MAX_TOOL_CALLS_PER_TURN",
             @default_max_tool_calls_per_turn
           ),
         :ok <- NativeConfig.validate_auth(auth, args.provider, credentials) do
      {:ok,
       %{
         provider: args.provider,
         agent: args.agent,
         task: args.task,
         model: args.model,
         workspace: env.("GLORBO_WORKSPACE") || @default_workspace,
         endpoint: endpoint,
         auth: auth,
         http_timeout_ms: http_timeout_ms,
         http_max_retries: http_max_retries,
         web_fetch_timeout_ms: web_fetch_timeout_ms,
         max_tool_calls_per_turn: max_tool_calls_per_turn,
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
           loop(initial_messages, config, initial_usage, %{}, [], 0, opts) do
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

  defp loop(messages, config, usage_acc, tool_counts, audit_events, total_tool_calls, opts) do
    with {:ok, response} <- chat_completion(messages, config, opts),
         {:ok, message, next_usage_acc} <- extract_message(response, usage_acc) do
      tool_calls = Map.get(message, "tool_calls") || []

      case tool_calls do
        [] ->
          case normalize_content(Map.get(message, "content")) do
            "" ->
              {:error, :empty_reply}

            reply ->
              {:ok,
               %{
                 reply: reply,
                 usage: build_usage(next_usage_acc, tool_counts, audit_events, config)
               }}
          end

        calls when is_list(calls) ->
          next_total = total_tool_calls + length(calls)

          if next_total > config.max_tool_calls_per_turn do
            {:error, {:tool_call_limit_exceeded, next_total}}
          else
            assistant_message = %{
              "role" => "assistant",
              "content" => Map.get(message, "content"),
              "tool_calls" => calls
            }

            {tool_messages, next_counts, next_events} =
              execute_tool_calls(calls, tool_counts, config, opts)

            loop(
              messages ++ [assistant_message] ++ tool_messages,
              config,
              next_usage_acc,
              next_counts,
              audit_events ++ next_events,
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
        "tools" => Tools.tool_specs(),
        "tool_choice" => "auto",
        "stream" => false
      },
      timeout_ms: config.http_timeout_ms
    }

    request_opts = [
      request_fun: Keyword.get(opts, :chat_fun, &HTTP.request/1),
      max_retries: config.http_max_retries,
      sleep_fun: Keyword.get(opts, :http_sleep_fun, &Process.sleep/1),
      jitter_fun: Keyword.get(opts, :http_jitter_fun, &default_http_jitter/1)
    ]

    case HTTP.request_with_retries(request, request_opts) do
      {:ok, %{status: 200, body: body}} ->
        case decode_response_body(body) do
          decoded when is_map(decoded) -> {:ok, decoded}
          _ -> {:error, :invalid_chat_response}
        end

      {:ok, %{status: status, body: body}} when status in [401, 403] ->
        {:error, {:auth, status, error_detail(decode_response_body(body))}}

      {:ok, %{status: 429, body: body}} ->
        {:error, {:rate_limited, error_detail(decode_response_body(body))}}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        {:error, {:upstream, status, error_detail(decode_response_body(body))}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, error_detail(decode_response_body(body))}}

      {:error, {:bad_request_fun_return, other}} ->
        {:error, {:bad_chat_return, other}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  end

  defp decode_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode_response_body(body), do: body

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

  defp build_usage(%{tracked?: false, model: model}, tool_counts, audit_events, config) do
    %{
      tracked: false,
      prompt_tokens: 0,
      completion_tokens: 0,
      model: model || config.model,
      tool_calls: tool_counts
    }
    |> maybe_put_audit_events(audit_events)
  end

  defp build_usage(acc, tool_counts, audit_events, config) do
    %{
      tracked: true,
      prompt_tokens: acc.prompt_tokens,
      completion_tokens: acc.completion_tokens,
      model: acc.model || config.model,
      tool_calls: tool_counts
    }
    |> maybe_put_audit_events(audit_events)
  end

  defp execute_tool_calls(calls, tool_counts, config, opts) do
    {messages, {counts, audit_events}} =
      Enum.map_reduce(calls, {tool_counts, []}, fn call, {counts, audit_events} ->
        result = Tools.execute(call, config, opts)

        {
          tool_result(call, result.payload),
          {count_tool_call(counts, result.tool_name),
           maybe_append_event(audit_events, Map.get(result, :audit_event))}
        }
      end)

    {messages, counts, audit_events}
  end

  defp tool_result(%{"id" => id}, payload) do
    %{
      "role" => "tool",
      "tool_call_id" => id,
      "content" => Jason.encode!(payload)
    }
  end

  defp tool_result(call, _payload) do
    %{
      "role" => "tool",
      "tool_call_id" => Map.get(call, "id", "missing"),
      "content" => Jason.encode!(%{"ok" => false, "error" => "invalid_tool_call"})
    }
  end

  defp count_tool_call(counts, name) do
    Map.update(counts, name, 1, &(&1 + 1))
  end

  defp maybe_append_event(events, nil), do: events
  defp maybe_append_event(events, event), do: events ++ [event]

  defp maybe_put_audit_events(usage, []), do: usage

  defp maybe_put_audit_events(usage, audit_events),
    do: Map.put(usage, :audit_events, audit_events)

  defp auth_headers(config) do
    [{"content-type", "application/json"}, {"accept", "application/json"}] ++
      NativeConfig.auth_headers(config.auth, Map.get(config, :credentials, %{}))
  end

  defp load_credentials(provider, opts) do
    read_fun = Keyword.get(opts, :credentials_read_fun, &File.read/1)
    path = credentials_path(provider, opts)
    NativeConfig.load_credentials_from_path(path, read_fun: read_fun)
  end

  defp credentials_path(provider, opts) do
    env = env_fun(opts)

    blank_to_nil(env.("GLORBO_NATIVE_CREDENTIALS_PATH")) ||
      NativeConfig.default_credentials_path(provider, env_fun: env)
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

  defp parse_positive_seconds(env_fun, key, default_ms) do
    default_s = div(default_ms, 1_000)

    case blank_to_nil(env_fun.(key)) do
      nil ->
        default_ms

      raw ->
        case Integer.parse(raw) do
          {seconds, ""} when seconds > 0 -> seconds * 1_000
          _ -> default_s * 1_000
        end
    end
  end

  defp parse_non_negative_integer(env_fun, key, default) do
    case blank_to_nil(env_fun.(key)) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {value, ""} when value >= 0 -> value
          _ -> default
        end
    end
  end

  defp parse_positive_integer(env_fun, key, default) do
    case blank_to_nil(env_fun.(key)) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {value, ""} when value > 0 -> value
          _ -> default
        end
    end
  end

  defp default_http_jitter(_attempt), do: 0

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
    do: "tool-call limit exceeded (#{total})"

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
