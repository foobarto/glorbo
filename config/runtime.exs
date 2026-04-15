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

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # For single-user local deployments a deterministic-but-host-specific key is
  # acceptable; production operators may override via SECRET_KEY_BASE.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      :crypto.hash(:sha256, System.get_env("HOME", "/tmp")) |> Base.encode64()

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :glorbo, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :glorbo, GlorboWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret_key_base
end
