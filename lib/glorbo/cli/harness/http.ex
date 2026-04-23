defmodule Glorbo.CLI.Harness.HTTP do
  @moduledoc false

  @http_profile :glorbo_harness
  @base_retry_delay_ms 200

  @type request :: %{
          required(:method) => :get | :post,
          required(:url) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:body) => map() | binary() | nil,
          optional(:timeout_ms) => pos_integer()
        }

  @type response :: %{
          required(:status) => non_neg_integer(),
          required(:headers) => map(),
          required(:body) => binary()
        }

  @spec request(request()) :: {:ok, response()} | {:error, term()}
  def request(%{} = request) do
    result =
      with {:ok, _} <- ensure_started(:inets),
           {:ok, _} <- ensure_started(:ssl),
           {:ok, _pid} <- start_http_profile(),
           :ok <- configure_proxy(request.url) do
        do_request(request)
      end

    stop_http_profile()
    result
  end

  @spec request_with_retries(request(), keyword()) :: {:ok, response()} | {:error, term()}
  def request_with_retries(%{} = request, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &request/1)
    max_retries = Keyword.get(opts, :max_retries, 0)
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    jitter_fun = Keyword.get(opts, :jitter_fun, &default_jitter/1)

    attempt_request(request, request_fun, max_retries, 0, sleep_fun, jitter_fun)
  end

  defp attempt_request(request, request_fun, max_retries, attempt, sleep_fun, jitter_fun) do
    case request_fun.(request) do
      {:ok, %{status: status} = response} = ok ->
        if retryable_status?(status) and attempt < max_retries do
          sleep_fun.(retry_delay_ms(response, attempt, jitter_fun))
          attempt_request(request, request_fun, max_retries, attempt + 1, sleep_fun, jitter_fun)
        else
          ok
        end

      {:error, reason} = error ->
        if retryable_error?(reason) and attempt < max_retries do
          sleep_fun.(retry_delay_ms(nil, attempt, jitter_fun))
          attempt_request(request, request_fun, max_retries, attempt + 1, sleep_fun, jitter_fun)
        else
          error
        end

      other ->
        {:error, {:bad_request_fun_return, other}}
    end
  end

  defp retryable_status?(429), do: true
  defp retryable_status?(status) when status >= 500, do: true
  defp retryable_status?(_), do: false

  defp retryable_error?({:invalid_proxy_url, _}), do: false
  defp retryable_error?({:unsupported_http_method, _}), do: false
  defp retryable_error?(_), do: true

  defp retry_delay_ms(%{status: 429} = response, attempt, jitter_fun) do
    headers = Map.get(response, :headers, %{})
    retry_after_ms(headers) || base_retry_delay_ms(attempt, jitter_fun)
  end

  defp retry_delay_ms(_response, attempt, jitter_fun),
    do: base_retry_delay_ms(attempt, jitter_fun)

  defp base_retry_delay_ms(attempt, jitter_fun) do
    round(@base_retry_delay_ms * :math.pow(2, attempt)) + jitter_fun.(attempt)
  end

  defp retry_after_ms(headers) do
    case Map.get(headers, "retry-after") do
      nil ->
        nil

      value ->
        case Integer.parse(String.trim(value)) do
          {seconds, ""} when seconds >= 0 -> seconds * 1_000
          _ -> nil
        end
    end
  end

  defp default_jitter(_attempt), do: :rand.uniform(50) - 1

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

  defp do_request(%{method: :get, url: url} = request) do
    headers = request_headers(request)
    http_options = http_options(url, request.timeout_ms)

    case :httpc.request(
           :get,
           {String.to_charlist(url), headers},
           http_options,
           [body_format: :binary],
           @http_profile
         ) do
      {:ok, {{_version, status, _reason}, response_headers, body}} ->
        {:ok, %{status: status, headers: normalize_headers(response_headers), body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_request(%{method: :post, url: url} = request) do
    headers = request_headers(request)
    body = request_body(request)
    content_type = request_content_type(request)
    http_options = http_options(url, request.timeout_ms)

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, String.to_charlist(content_type), body},
           http_options,
           [body_format: :binary],
           @http_profile
         ) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok,
         %{status: status, headers: normalize_headers(response_headers), body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_request(%{method: other}), do: {:error, {:unsupported_http_method, other}}

  defp request_headers(request) do
    request
    |> Map.get(:headers, [])
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp request_body(%{body: body}) when is_binary(body), do: body
  defp request_body(%{body: body}) when is_map(body), do: Jason.encode!(body)
  defp request_body(_request), do: ""

  defp request_content_type(%{headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value("application/octet-stream", fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == "content-type", do: value, else: nil

      _ ->
        nil
    end)
  end

  defp request_content_type(_request), do: "application/octet-stream"

  defp normalize_headers(headers) do
    headers
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, key |> to_string() |> String.downcase(), to_string(value))
    end)
  end

  defp http_options(url, timeout_ms) do
    base = [timeout: timeout_ms, connect_timeout: timeout_ms]

    if String.starts_with?(url, "https://") do
      Keyword.put(base, :ssl, :httpc.ssl_verify_host_options(true))
    else
      base
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(other), do: other
end
