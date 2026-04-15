defmodule Glorbo.Container.WorkerClient do
  @moduledoc """
  HTTP client for the FastAPI worker over a Unix domain socket (D-34).

  Uses the shared `Glorbo.Finch` pool with Finch's `unix_socket:` option.
  Implements retry-connect backoff per D-39 so callers can fire `/run`
  immediately after `ContainerManager.start_container/2` without polling
  for uvicorn readiness.

  Tests inject `request_fun` (a 3-arity function `(request, sock, timeout)`
  returning `{:ok, map}` / `{:error, term}`) so the backoff and routing
  logic are exercised without real containers. The production default
  delegates to `Finch.request/3` and normalises the response body.
  """

  require Logger

  alias Glorbo.Container.Socket

  # ~50 + 100 + 200 + 500 + 1000 + 2000 ≈ 3.85 s retries + one immediate
  # attempt (the function is invoked once per element PLUS once for the
  # empty-list terminal call). Approximately the ~5 s readiness budget in
  # D-39.
  @backoff_ms [50, 100, 200, 500, 1000, 2000]

  @spec post_run(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def post_run(company, agent, body, opts \\ []) do
    post(company, agent, "/run", body, opts)
  end

  @spec post_cancel(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def post_cancel(company, agent, request_id, opts \\ []) do
    post(company, agent, "/cancel", %{request_id: request_id}, opts)
  end

  # ------ internals ------

  defp post(company, agent, path, body, opts) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    sock = Socket.path(base, company, agent)
    timeout = Keyword.get(opts, :receive_timeout, 300_000)
    request_fun = Keyword.get(opts, :request_fun, &default_request/3)

    req =
      Finch.build(
        :post,
        "http://localhost" <> path,
        [{"content-type", "application/json"}],
        Jason.encode!(body)
      )

    try_with_backoff(@backoff_ms, fn -> request_fun.(req, sock, timeout) end)
  end

  defp default_request(req, sock, timeout) do
    req
    |> Finch.request(Glorbo.Finch, unix_socket: sock, receive_timeout: timeout)
    |> normalize_response()
  end

  defp normalize_response({:ok, %Finch.Response{status: 200, body: body}}) do
    {:ok, Jason.decode!(body)}
  end

  defp normalize_response({:ok, %Finch.Response{status: status, body: body}}) do
    {:error, {:http_status, status, body}}
  end

  defp normalize_response({:error, _} = err), do: err

  defp try_with_backoff([], fun), do: fun.()

  defp try_with_backoff([wait | rest], fun) do
    case fun.() do
      {:error, %Mint.TransportError{reason: reason}} when reason in [:econnrefused, :enoent] ->
        Process.sleep(wait)
        try_with_backoff(rest, fun)

      result ->
        result
    end
  end
end
