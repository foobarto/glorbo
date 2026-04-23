defmodule Glorbo.Providers.NativeConfig do
  @moduledoc false

  alias Glorbo.Filesystem.Hierarchy

  @type credentials :: map()
  @type load_opt ::
          {:env_fun, (String.t() -> String.t() | nil)}
          | {:read_fun, (Path.t() -> {:ok, binary()} | {:error, term()})}

  @spec parse_auth(nil | atom() | String.t()) ::
          {:ok, nil | :none | :bearer | :api_key} | {:error, {:invalid_auth, term()}}
  def parse_auth(nil), do: {:ok, nil}
  def parse_auth(:none), do: {:ok, :none}
  def parse_auth(:bearer), do: {:ok, :bearer}
  def parse_auth(:api_key), do: {:ok, :api_key}
  def parse_auth("none"), do: {:ok, :none}
  def parse_auth("bearer"), do: {:ok, :bearer}
  def parse_auth("api_key"), do: {:ok, :api_key}
  def parse_auth("api-key"), do: {:ok, :api_key}
  def parse_auth(other), do: {:error, {:invalid_auth, other}}

  @spec credentials_dir(keyword()) :: Path.t()
  def credentials_dir(opts \\ []) do
    env_fun = Keyword.get(opts, :env_fun, &System.get_env/1)

    case env_fun.("GLORBO_CREDENTIALS_DIR") do
      nil ->
        Hierarchy.native_credentials_dir()

      "" ->
        Hierarchy.native_credentials_dir()

      override when is_binary(override) ->
        # Refuse obviously-wrong overrides so setting
        # `GLORBO_CREDENTIALS_DIR=/etc` doesn't point credentials at
        # `/etc/<provider>.toml` and start bind-mounting host system
        # config. Opencode round-3 flagged.
        cond do
          not String.starts_with?(override, "/") ->
            raise ArgumentError,
                  "GLORBO_CREDENTIALS_DIR must be an absolute path; got #{inspect(override)}"

          String.contains?(override, "/../") or String.ends_with?(override, "/..") ->
            raise ArgumentError,
                  "GLORBO_CREDENTIALS_DIR must not contain `..`; got #{inspect(override)}"

          override in ["/etc", "/usr", "/bin", "/sbin", "/proc", "/sys", "/dev"] ->
            raise ArgumentError,
                  "GLORBO_CREDENTIALS_DIR refuses system path #{inspect(override)}"

          true ->
            override
        end
    end
  end

  @spec default_credentials_path(String.t(), keyword()) :: Path.t()
  def default_credentials_path(provider, opts \\ []) when is_binary(provider) do
    Path.join(credentials_dir(opts), "#{provider}.toml")
  end

  @spec load_credentials(String.t(), keyword()) ::
          {:ok, credentials()}
          | {:error, {:invalid_credentials_toml, term()} | {:credentials_read_failed, term()}}
  def load_credentials(provider, opts \\ []) when is_binary(provider) do
    load_credentials_from_path(default_credentials_path(provider, opts), opts)
  end

  @spec load_credentials_from_path(Path.t() | nil, keyword()) ::
          {:ok, credentials()}
          | {:error, {:invalid_credentials_toml, term()} | {:credentials_read_failed, term()}}
  def load_credentials_from_path(nil, _opts), do: {:ok, %{}}

  def load_credentials_from_path(path, opts) when is_binary(path) do
    read_fun = Keyword.get(opts, :read_fun, &File.read/1)

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

  @spec resolve_endpoint(String.t() | nil, credentials()) ::
          {:ok, String.t()} | {:error, :missing_endpoint}
  def resolve_endpoint(nil, _credentials), do: {:error, :missing_endpoint}
  def resolve_endpoint("", _credentials), do: {:error, :missing_endpoint}

  def resolve_endpoint(endpoint, credentials) when is_binary(endpoint) do
    {:ok, Map.get(credentials, "endpoint") || endpoint}
  end

  @spec validate_auth(nil | :none | :bearer | :api_key, String.t(), credentials()) ::
          :ok | {:error, {:missing_api_key, String.t()}}
  def validate_auth(nil, _provider, _credentials), do: :ok
  def validate_auth(:none, _provider, _credentials), do: :ok

  def validate_auth(_auth, provider, credentials) do
    case Map.get(credentials, "api_key") do
      key when is_binary(key) and key != "" -> :ok
      _ -> {:error, {:missing_api_key, provider}}
    end
  end

  @spec auth_headers(nil | :none | :bearer | :api_key, credentials()) :: [
          {String.t(), String.t()}
        ]
  def auth_headers(nil, _credentials), do: []
  def auth_headers(:none, _credentials), do: []

  def auth_headers(:bearer, credentials) do
    key = Map.get(credentials, "api_key")
    extras = Map.get(credentials, "extras", %{})

    [{"authorization", "Bearer " <> key}] ++
      maybe_extra_header("openai-organization", extras["organization"]) ++
      maybe_extra_header("openai-project", extras["project"])
  end

  def auth_headers(:api_key, credentials) do
    [{"api-key", Map.fetch!(credentials, "api_key")}]
  end

  defp maybe_extra_header(_header, nil), do: []
  defp maybe_extra_header(_header, ""), do: []
  defp maybe_extra_header(header, value), do: [{header, to_string(value)}]
end
