import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/glorbo start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :glorbo, GlorboWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_path =
    System.get_env("GLORBO_DB_PATH") ||
      System.get_env("DATABASE_PATH") ||
      Path.expand("~/.glorbo/glorbo.db")

  config :glorbo, Glorbo.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    journal_mode: :wal

  # Phase 4 Wave 0: prefer `~/.glorbo/config.md` over env vars so a fresh
  # install is configured-by-file (matches D-06/D-07 "filesystem is source
  # of truth"). Env vars still override — useful for one-off overrides
  # in test harnesses and CI smoke tests.
  cfg =
    case Glorbo.Config.load() do
      {:ok, c} ->
        c

      {:error, _} ->
        # Fall back to a derived secret so the endpoint still boots when
        # config.md is unreadable. Log nothing (T-04-05: never leak config
        # state into logs).
        %{
          secret_key_base:
            :crypto.hash(:sha256, System.get_env("HOME", "/tmp")) |> Base.encode64(),
          host: "127.0.0.1",
          port: 4000,
          dashboard_token: nil
        }
    end

  secret_key_base = System.get_env("SECRET_KEY_BASE") || cfg.secret_key_base
  host = System.get_env("PHX_HOST") || cfg.host
  port = String.to_integer(System.get_env("PORT") || Integer.to_string(cfg.port))

  config :glorbo, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :glorbo, :dashboard_token, cfg.dashboard_token

  config :glorbo, GlorboWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret_key_base
end
