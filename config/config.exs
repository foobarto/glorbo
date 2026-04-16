# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :glorbo,
  ecto_repos: [Glorbo.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :glorbo, GlorboWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GlorboWeb.ErrorHTML, json: GlorboWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Glorbo.PubSub,
  live_view: [signing_salt: "go0q2coP"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Phase 3 config — LLM rate table (D-30) + api-only network policy allowlist (D-16).
# These are loaded BEFORE the env-specific import so test/dev/prod can override.
import_config "llm_rates.exs"
import_config "network_policy.exs"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
