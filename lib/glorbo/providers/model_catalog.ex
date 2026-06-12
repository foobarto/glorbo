defmodule Glorbo.Providers.ModelCatalog do
  @moduledoc """
  Host-side native-provider model catalog cache (GEP-32 phase 3).

  This process never participates in agent dispatch. It refreshes native
  providers' model catalogs on explicit request, persists the raw response
  under `~/.glorbo/cache/providers/*.json`, and keeps SQLite's
  `provider_models` table as a derived projection of those cache files.
  """
  use GenServer

  import Ecto.Query

  alias Glorbo.CLI.Harness.HTTP
  alias Glorbo.CLI.Registry
  alias Glorbo.CLI.Registry.Loader
  alias Glorbo.CLI.Registry.Provider
  alias Glorbo.Filesystem.Hierarchy
  alias Glorbo.ProviderModel
  alias Glorbo.Providers.NativeConfig
  alias Glorbo.Repo

  @default_request_timeout_ms 5_000

  @type catalog_status :: :idle | :ready | :auth | :unreachable | :stale | :shape

  @type summary_entry :: %{
          required(:status) => catalog_status(),
          required(:model_count) => non_neg_integer(),
          required(:refreshed_at) => DateTime.t() | nil
        }

  @type refresh_result ::
          {:ok, summary_entry()}
          | {:error, summary_entry()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec summary(GenServer.server()) :: %{optional(String.t()) => summary_entry()}
  def summary(server \\ __MODULE__) do
    GenServer.call(server, :summary)
  end

  @spec refresh_all(GenServer.server()) :: %{optional(String.t()) => refresh_result()}
  def refresh_all(server \\ __MODULE__) do
    GenServer.call(server, :refresh_all, :infinity)
  end

  @spec refresh_provider(String.t(), GenServer.server()) ::
          {:ok, summary_entry()} | {:error, term()}
  def refresh_provider(alias_name, server \\ __MODULE__) when is_binary(alias_name) do
    GenServer.call(server, {:refresh_provider, alias_name}, :infinity)
  end

  @spec list_models(String.t(), GenServer.server()) :: [ProviderModel.t()]
  def list_models(alias_name, server \\ __MODULE__) when is_binary(alias_name) do
    GenServer.call(server, {:list_models, alias_name})
  end

  @spec model_known?(String.t(), String.t(), GenServer.server()) :: :known | :unknown | :no_cache
  def model_known?(alias_name, model_id, server \\ __MODULE__)
      when is_binary(alias_name) and is_binary(model_id) do
    GenServer.call(server, {:model_known?, alias_name, model_id})
  end

  @spec cache_dir(Path.t()) :: Path.t()
  def cache_dir(base), do: Hierarchy.providers_cache_dir(base)

  @spec cache_path(Path.t(), String.t()) :: Path.t()
  def cache_path(base, alias_name), do: Path.join(cache_dir(base), "#{alias_name}.json")

  @spec rebuild_projection_from_cache(Path.t(), keyword()) :: :ok
  def rebuild_projection_from_cache(base, opts \\ []) when is_binary(base) do
    repo = Keyword.get(opts, :repo, Repo)

    providers =
      Keyword.get_lazy(opts, :providers, fn ->
        Loader.load_all!()
      end)

    repo.delete_all(ProviderModel)

    providers
    |> catalog_providers()
    |> Enum.each(fn provider ->
      case read_cache_rows(base, provider) do
        {:ok, rows} when rows != [] ->
          :ok = replace_projection(repo, provider.name, rows, nil)

        _ ->
          :ok
      end
    end)

    :ok
  end

  @spec read_cache_rows(Path.t(), Provider.t()) :: {:ok, [map()]} | {:error, term()}
  def read_cache_rows(base, %Provider{name: alias_name, model_list: %{shape: shape}} = provider)
      when shape in [:openai, :ollama] do
    path = cache_path(base, alias_name)

    with {:ok, %File.Stat{type: :regular, mtime: mtime}} <- File.lstat(path),
         {:ok, body} <- File.read(path),
         {:ok, refreshed_at} <- file_mtime_to_datetime(mtime),
         {:ok, rows} <- rows_from_response(provider, body, refreshed_at) do
      {:ok, rows}
    else
      {:ok, %File.Stat{type: other}} -> {:error, {:not_regular_file, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `:static` providers (broker-style, e.g. stado) have no HTTP catalog
  # to fetch — the model alias list lives in the registry TOML's
  # `model_list.models` array. Project those directly without touching
  # the cache file. `refreshed_at` is nil because there's no cache
  # mtime; the projection is current-as-of-load.
  def read_cache_rows(_base, %Provider{
        name: alias_name,
        model_list: %{shape: :static, models: models}
      })
      when is_list(models) do
    rows =
      Enum.map(models, fn model_id ->
        %{
          alias: alias_name,
          model_id: model_id,
          context_window: nil,
          family: nil,
          raw_json: ~s({"id":#{Jason.encode!(model_id)}}),
          refreshed_at: nil
        }
      end)

    {:ok, rows}
  end

  def read_cache_rows(_base, _provider), do: {:ok, []}

  @spec rows_from_response(Provider.t(), binary(), DateTime.t()) ::
          {:ok, [map()]} | {:error, term()}
  def rows_from_response(
        %Provider{name: alias_name, model_list: %{shape: :openai}},
        body,
        refreshed_at
      )
      when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, list} <- expect_list(decoded, "data") do
      rows =
        list
        |> Enum.flat_map(fn
          %{"id" => id} = row when is_binary(id) and id != "" ->
            [
              %{
                alias: alias_name,
                model_id: id,
                context_window: integer_or_nil(row["context_window"] || row["context_length"]),
                family: string_or_nil(row["owned_by"] || row["family"]),
                raw_json: Jason.encode!(row),
                refreshed_at: refreshed_at
              }
            ]

          _ ->
            []
        end)

      if rows == [] and list != [] do
        {:error, :invalid_openai_models_shape}
      else
        {:ok, rows}
      end
    else
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err.data}}
      {:error, reason} -> {:error, reason}
    end
  end

  def rows_from_response(
        %Provider{name: alias_name, model_list: %{shape: :ollama}},
        body,
        refreshed_at
      )
      when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, list} <- expect_list(decoded, "models") do
      rows =
        list
        |> Enum.flat_map(fn
          %{"name" => id} = row when is_binary(id) and id != "" ->
            [
              %{
                alias: alias_name,
                model_id: id,
                context_window: integer_or_nil(row["context_window"]),
                family:
                  row
                  |> Map.get("details", %{})
                  |> case do
                    %{} = details -> string_or_nil(details["family"])
                    _ -> nil
                  end,
                raw_json: Jason.encode!(row),
                refreshed_at: refreshed_at
              }
            ]

          _ ->
            []
        end)

      if rows == [] and list != [] do
        {:error, :invalid_ollama_models_shape}
      else
        {:ok, rows}
      end
    else
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err.data}}
      {:error, reason} -> {:error, reason}
    end
  end

  def rows_from_response(_provider, _body, _refreshed_at), do: {:ok, []}

  @impl true
  def init(opts) do
    base = Keyword.get(opts, :base, Hierarchy.default_root())
    repo = Keyword.get(opts, :repo, Repo)

    {:ok,
     %{
       base: base,
       repo: repo,
       registry_name: Keyword.get(opts, :registry_name, Registry),
       request_fun: Keyword.get(opts, :request_fun, &HTTP.request/1),
       credentials_read_fun: Keyword.get(opts, :credentials_read_fun, &File.read/1),
       now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
       statuses: preload_statuses_from_cache(base)
     }}
  end

  @impl true
  def handle_call(:summary, {owner, _tag}, state) do
    {:reply, merge_projection_summary(state, owner), state}
  end

  def handle_call({:list_models, alias_name}, {owner, _tag}, state) do
    query =
      from pm in ProviderModel,
        where: pm.alias == ^alias_name,
        order_by: [asc: pm.model_id]

    {:reply, state.repo.all(query, caller: owner), state}
  end

  def handle_call({:model_known?, alias_name, model_id}, _from, state) do
    verdict = model_known_from_cache(state, alias_name, model_id)

    {:reply, verdict, state}
  end

  def handle_call(:refresh_all, {owner, _tag}, state) do
    providers = catalog_providers(load_registry(state.registry_name))
    {results, next_statuses} = refresh_many(providers, state, owner)
    {:reply, results, %{state | statuses: next_statuses}}
  end

  def handle_call({:refresh_provider, alias_name}, {owner, _tag}, state) do
    case Enum.find(
           catalog_providers(load_registry(state.registry_name)),
           &(&1.name == alias_name)
         ) do
      nil ->
        {:reply, {:error, :unknown_provider}, state}

      provider ->
        {result, next_status} = refresh_one(provider, state, owner)
        next_state = %{state | statuses: Map.put(state.statuses, alias_name, next_status)}

        case result do
          {:ok, entry} -> {:reply, {:ok, entry}, next_state}
          {:error, reason, entry} -> {:reply, {:error, {reason, entry}}, next_state}
        end
    end
  end

  defp load_registry(registry_name) do
    Registry.list(registry_name)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp catalog_providers(providers) do
    Enum.filter(providers, fn
      %Provider{kind: :native, model_list: %{shape: shape}} when shape in [:openai, :ollama] ->
        true

      # Broker-style providers (e.g. stado as ACP server) declare their
      # known model aliases inline via `model_list.shape = "static"`.
      # No HTTP fetch — the projection is rebuilt directly from the
      # registry's TOML-declared list.
      %Provider{model_list: %{shape: :static, models: models}}
      when is_list(models) and models != [] ->
        true

      _ ->
        false
    end)
  end

  defp refresh_many([], state, _owner), do: {%{}, state.statuses}

  defp refresh_many(providers, state, owner) do
    results =
      providers
      |> Task.async_stream(
        fn provider -> {provider.name, refresh_one(provider, state, owner)} end,
        max_concurrency: min(length(providers), 5),
        timeout: @default_request_timeout_ms + 1_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, pair} ->
          pair

        {:exit, reason} ->
          {"<task-exit>",
           {{:error, {:task_exit, reason}, %{status: :stale, model_count: 0, refreshed_at: nil}},
            %{status: :stale, detail: reason, refreshed_at: nil}}}
      end)
      |> Enum.reject(fn {alias_name, _} -> alias_name == "<task-exit>" end)

    result_map =
      Map.new(results, fn {alias_name, {result, _entry}} ->
        {alias_name, normalize_refresh_result(result)}
      end)

    next_statuses =
      Enum.reduce(results, state.statuses, fn {alias_name, {_result, status_entry}}, acc ->
        Map.put(acc, alias_name, status_entry)
      end)

    {result_map, next_statuses}
  end

  defp normalize_refresh_result({:ok, entry}), do: {:ok, entry}
  defp normalize_refresh_result({:error, reason, entry}), do: {:error, reason, entry}

  defp refresh_one(
         %Provider{model_list: %{shape: :static}} = provider,
         state,
         owner
       ) do
    # No HTTP fetch — broker-style providers ship their model list in
    # the registry TOML. Projection is rebuilt from `read_cache_rows/2`,
    # which short-circuits to the static list.
    alias_name = provider.name
    refreshed_at = normalize_now(state.now_fun.())

    case read_cache_rows(state.base, provider) do
      {:ok, rows} ->
        rows = Enum.map(rows, &Map.put(&1, :refreshed_at, refreshed_at))
        :ok = replace_projection(state.repo, alias_name, rows, owner)
        entry = %{status: :ready, model_count: length(rows), refreshed_at: refreshed_at}
        {{:ok, entry}, Map.put(entry, :detail, nil)}
    end
  end

  defp refresh_one(provider, state, owner) do
    alias_name = provider.name

    previous =
      Map.get(state.statuses, alias_name, %{refreshed_at: cache_mtime(state.base, alias_name)})

    case fetch_rows(provider, state) do
      {:ok, body, rows, refreshed_at} ->
        :ok = persist_cache(state.base, alias_name, body)
        :ok = replace_projection(state.repo, alias_name, rows, owner)

        entry = %{status: :ready, model_count: length(rows), refreshed_at: refreshed_at}
        {{:ok, entry}, Map.put(entry, :detail, nil)}

      {:error, reason, status} ->
        count = model_count(state.repo, alias_name, owner)
        entry = %{status: status, model_count: count, refreshed_at: previous[:refreshed_at]}
        {{:error, reason, entry}, Map.put(entry, :detail, reason)}
    end
  end

  defp fetch_rows(provider, state) do
    with {:ok, credentials} <-
           NativeConfig.load_credentials(
             provider.name,
             env_fun: fn key ->
               if key == "GLORBO_CREDENTIALS_DIR", do: System.get_env(key), else: nil
             end,
             read_fun: state.credentials_read_fun
           ),
         {:ok, auth} <- NativeConfig.parse_auth(provider.auth),
         {:ok, credentials} <- via_proxy_catalog_credentials(auth, provider, credentials),
         :ok <- NativeConfig.validate_auth(auth, provider.name, credentials),
         {:ok, endpoint} <- NativeConfig.resolve_endpoint(provider.endpoint, credentials),
         {:ok, url} <- model_list_url(endpoint, provider),
         {:ok, body} <- fetch_body(url, auth, credentials, state.request_fun),
         refreshed_at <- normalize_now(state.now_fun.()),
         {:ok, rows} <- rows_from_response(provider, body, refreshed_at) do
      {:ok, body, rows, refreshed_at}
    else
      {:error, {:missing_api_key, _} = reason} ->
        {:error, reason, :auth}

      {:error, {:invalid_credentials_toml, _} = reason} ->
        {:error, reason, :auth}

      {:error, {:credentials_read_failed, _} = reason} ->
        {:error, reason, :auth}

      {:error, :missing_endpoint} = err ->
        {:error, elem(err, 1), :shape}

      {:error, {:http_status, status, _} = reason} when status in [401, 403] ->
        {:error, reason, :auth}

      {:error, {:http_status, status, _} = reason} when status >= 500 ->
        {:error, reason, :stale}

      {:error, {:http_request_failed, :timeout} = reason} ->
        {:error, reason, :stale}

      {:error, {:http_request_failed, reason}} ->
        {:error, {:http_request_failed, reason}, classify_transport(reason)}

      {:error, {:invalid_json, _} = reason} ->
        {:error, reason, :shape}

      {:error, :invalid_openai_models_shape} = err ->
        {:error, elem(err, 1), :shape}

      {:error, :invalid_ollama_models_shape} = err ->
        {:error, elem(err, 1), :shape}

      {:error, {:invalid_auth, _} = reason} ->
        {:error, reason, :shape}

      {:error, reason} ->
        {:error, reason, :shape}
    end
  end

  # GEP-0055: a `via_proxy` provider has no GEP-32 credentials TOML;
  # its upstream key lives in the host env var named by
  # `api_key_env`. The catalog runs host-side (it IS the host), so
  # reading that env var here is the same access the proxy listener
  # performs at request time. A missing/empty env var surfaces as
  # the catalog's existing `:auth` status via `{:missing_api_key, _}`.
  defp via_proxy_catalog_credentials(:via_proxy, provider, _credentials) do
    case provider.api_key_env && System.get_env(provider.api_key_env) do
      key when is_binary(key) and key != "" -> {:ok, %{"api_key" => key}}
      _ -> {:error, {:missing_api_key, provider.name}}
    end
  end

  defp via_proxy_catalog_credentials(_auth, _provider, credentials), do: {:ok, credentials}

  defp fetch_body(url, auth, credentials, request_fun) do
    request = %{
      method: :get,
      url: url,
      headers: [{"accept", "application/json"}] ++ NativeConfig.auth_headers(auth, credentials),
      timeout_ms: @default_request_timeout_ms
    }

    case request_fun.(request) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}

      other ->
        {:error, {:http_request_failed, {:bad_request_fun_return, other}}}
    end
  end

  defp model_list_url(endpoint, %Provider{model_list: %{path: path}}) when is_binary(path) do
    uri = URI.parse(endpoint)

    if is_binary(uri.scheme) and is_binary(uri.host) do
      {:ok, URI.to_string(%{uri | path: path, query: nil, fragment: nil})}
    else
      {:error, :missing_endpoint}
    end
  end

  defp model_list_url(_endpoint, _provider), do: {:error, :missing_endpoint}

  defp replace_projection(repo, alias_name, rows, owner) do
    repo.transaction(
      fn ->
        repo.delete_all(from pm in ProviderModel, where: pm.alias == ^alias_name)

        if rows != [] do
          repo.insert_all(ProviderModel, rows)
        end
      end,
      caller: owner
    )

    :ok
  end

  defp persist_cache(base, alias_name, body) when is_binary(body) do
    path = cache_path(base, alias_name)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, body)
    File.rename!(tmp, path)
    :ok
  end

  # DB-free — the projection's model_count + refreshed_at are recomputed
  # live on every `:summary` call, so `init/1` only needs to seed
  # `status` and a cheap mtime-based `refreshed_at` fallback from the
  # on-disk cache files.
  defp preload_statuses_from_cache(base) do
    case File.ls(cache_dir(base)) do
      {:ok, entries} -> entries
      _ -> []
    end
    |> Enum.reduce(%{}, fn file, acc ->
      if String.ends_with?(file, ".json") do
        alias_name = Path.rootname(file)
        Map.put(acc, alias_name, %{status: :ready, refreshed_at: cache_mtime(base, alias_name)})
      else
        acc
      end
    end)
  end

  defp merge_projection_summary(state, owner) do
    counts = projection_summary(state.repo, owner)

    Enum.reduce(counts, state.statuses, fn {alias_name, summary}, acc ->
      Map.update(
        acc,
        alias_name,
        summary,
        fn current ->
          %{
            status: Map.get(current, :status, :ready),
            model_count: summary.model_count,
            refreshed_at: summary.refreshed_at || Map.get(current, :refreshed_at)
          }
        end
      )
    end)
    |> Enum.into(%{}, fn {alias_name, entry} ->
      {alias_name,
       %{
         status: Map.get(entry, :status, :idle),
         model_count: Map.get(entry, :model_count, 0),
         refreshed_at: Map.get(entry, :refreshed_at)
       }}
    end)
  end

  defp projection_summary(repo, owner) do
    query =
      from pm in ProviderModel,
        group_by: pm.alias,
        select: {pm.alias, count(pm.model_id), max(pm.refreshed_at)}

    repo.all(query, caller: owner)
    |> Enum.into(%{}, fn {alias_name, count, refreshed_at} ->
      {alias_name, %{model_count: count, refreshed_at: refreshed_at}}
    end)
  end

  defp model_count(repo, alias_name, owner) do
    query = from pm in ProviderModel, where: pm.alias == ^alias_name, select: count(pm.model_id)
    repo.one(query, caller: owner) || 0
  end

  defp model_known_from_cache(state, alias_name, model_id) do
    case Enum.find(
           catalog_providers(load_registry(state.registry_name)),
           &(&1.name == alias_name)
         ) do
      nil ->
        :no_cache

      provider ->
        case read_cache_rows(state.base, provider) do
          {:ok, []} ->
            :no_cache

          {:ok, rows} ->
            if Enum.any?(rows, &(&1.model_id == model_id)), do: :known, else: :unknown

          {:error, _} ->
            :no_cache
        end
    end
  end

  defp cache_mtime(base, alias_name) do
    case File.stat(cache_path(base, alias_name), time: :universal) do
      {:ok, %File.Stat{mtime: mtime}} ->
        case file_mtime_to_datetime(mtime) do
          {:ok, dt} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp file_mtime_to_datetime({{_, _, _}, {_, _, _}} = erl) do
    {:ok, erl |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")}
  end

  defp file_mtime_to_datetime(_other), do: {:error, :bad_mtime}

  defp normalize_now(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp normalize_now(%NaiveDateTime{} = dt),
    do: dt |> NaiveDateTime.truncate(:second) |> DateTime.from_naive!("Etc/UTC")

  defp normalize_now(_), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp expect_list(decoded, key) when is_map(decoded) and is_binary(key) do
    case Map.get(decoded, key) do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, :missing_models_list}
    end
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp integer_or_nil(_), do: nil

  defp classify_transport(:econnrefused), do: :unreachable
  defp classify_transport(:nxdomain), do: :unreachable
  defp classify_transport(:enetunreach), do: :unreachable
  defp classify_transport({:failed_connect, _, _}), do: :unreachable
  defp classify_transport({:failed_connect, _}), do: :unreachable
  defp classify_transport(_), do: :unreachable
end
