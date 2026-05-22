defmodule Glorbo.CLI.Harness.HTTP do
  @moduledoc false

  @http_profile :glorbo_harness
  @base_retry_delay_ms 200

  # Hard ceiling on a buffered response body. `:httpc` with
  # `body_format: :binary` fully buffers the body before returning,
  # so the downstream `capped_binary/2` in Tools only ran *after* an
  # arbitrarily large payload was already in the heap (C-034). We now
  # stream the response and abort once this many bytes have arrived,
  # so a malicious / injected `web_fetch` target serving a huge or
  # endless body can't exhaust the harness heap. Callers may override
  # via `:max_response_bytes`; this is the default + absolute cap.
  @default_max_response_bytes 1_048_576

  @type request :: %{
          required(:method) => :get | :post,
          required(:url) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:body) => map() | binary() | nil,
          optional(:timeout_ms) => pos_integer(),
          optional(:max_response_bytes) => pos_integer()
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
    req = {String.to_charlist(url), headers}

    stream_request(:get, req, http_options, max_response_bytes(request), request.timeout_ms)
  end

  defp do_request(%{method: :post, url: url} = request) do
    headers = request_headers(request)
    body = request_body(request)
    content_type = request_content_type(request)
    http_options = http_options(url, request.timeout_ms)
    req = {String.to_charlist(url), headers, String.to_charlist(content_type), body}

    stream_request(:post, req, http_options, max_response_bytes(request), request.timeout_ms)
  end

  defp do_request(%{method: other}), do: {:error, {:unsupported_http_method, other}}

  defp max_response_bytes(request) do
    case Map.get(request, :max_response_bytes) do
      n when is_integer(n) and n > 0 -> min(n, @default_max_response_bytes)
      _ -> @default_max_response_bytes
    end
  end

  # Stream the response into the calling process and abort the moment
  # the accumulated body exceeds `max_bytes`, so a large / endless
  # body can never be fully buffered (C-034). `sync: false` +
  # `stream: :self` makes :httpc deliver `{:http, {ref, ...}}`
  # messages we can stop reading at will.
  #
  # OTP only *streams* 200/206 responses (`?IS_STREAMED` in
  # httpc_handler) — for those, `:stream_start` carries the header
  # list but NOT the status line, so a streamed body is reported as
  # status 200. Every other status code is delivered as a single
  # inline result message `{:http, {ref, {{_v, status, _}, hdrs,
  # body}}}` carrying its real status, handled below. web_fetch
  # never sends a Range header, so a 206 (also reported as 200) does
  # not arise in practice; both are 2xx success regardless.
  defp stream_request(method, req, http_options, max_bytes, timeout_ms) do
    options = [sync: false, stream: :self, body_format: :binary, receiver: self()]

    case :httpc.request(method, req, http_options, options, @http_profile) do
      {:ok, ref} ->
        collect_stream(ref, max_bytes, receive_timeout(timeout_ms))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_stream(ref, max_bytes, timeout) do
    collect_stream(ref, max_bytes, timeout, :unstarted, [], 0)
  end

  # Each receive uses the request timeout as an upper bound so a
  # stalled connection can't hang the harness indefinitely.
  defp collect_stream(ref, max_bytes, timeout, state, acc, size) do
    receive do
      {:http, {^ref, :stream_start, headers}} ->
        collect_stream(ref, max_bytes, timeout, {:streaming, headers}, acc, size)

      {:http, {^ref, :stream_start, headers, _pid}} ->
        collect_stream(ref, max_bytes, timeout, {:streaming, headers}, acc, size)

      {:http, {^ref, :stream, chunk}} ->
        new_size = size + byte_size(chunk)

        if new_size > max_bytes do
          _ = :httpc.cancel_request(ref, @http_profile)
          finish_stream(state, [chunk | acc], max_bytes)
        else
          collect_stream(ref, max_bytes, timeout, state, [chunk | acc], new_size)
        end

      {:http, {^ref, :stream_end, _trailers}} ->
        finish_stream(state, acc, max_bytes)

      # Non-streamed status codes (anything but 200/206) arrive as a
      # single inline result that carries the real status. Cap the
      # body defensively — these are not streamed so they were already
      # fully received, but the cap keeps the surfaced body bounded.
      {:http, {^ref, {{_version, status, _reason}, headers, body}}} ->
        bin = if is_binary(body), do: body, else: IO.iodata_to_binary(body)
        capped = binary_part(bin, 0, min(byte_size(bin), max_bytes))
        {:ok, %{status: status, headers: normalize_headers(headers), body: capped}}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}
    after
      timeout ->
        _ = :httpc.cancel_request(ref, @http_profile)
        {:error, :timeout}
    end
  end

  defp finish_stream(:unstarted, _acc, _max_bytes), do: {:error, :no_response}

  defp finish_stream({:streaming, headers}, acc, max_bytes) do
    body =
      acc
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    capped = binary_part(body, 0, min(byte_size(body), max_bytes))
    # Streamed responses are only ever 200/206 (see stream_request).
    {:ok, %{status: 200, headers: normalize_headers(headers), body: capped}}
  end

  defp receive_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms

  defp receive_timeout(_), do: 30_000

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
