import Config

# Configure your database
config :glorbo, Glorbo.Repo,
  database: Path.expand("../glorbo_dev.db", __DIR__),
  pool_size: 5,
  journal_mode: :wal,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# For development, we disable any cache and enable
# debugging and code reloading.
config :glorbo, GlorboWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "LM/PCkXewhGl950gpeEYlYSAVZCvrqcln498tI1BXfXxgUdT4Cw102BmUPOTF9LJ",
  # Phase 4 Wave 0 — esbuild watcher keeps `priv/static/assets/` in sync
  # with `assets/**` during development. `--sourcemap=inline --watch`
  # emits inline source maps and stays resident under Phoenix's watcher
  # supervision tree.
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:glorbo, ~w(--sourcemap=inline --watch)]}
  ]

# Reload browser tabs when matching files change.
config :glorbo, GlorboWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/glorbo_web/router\.ex$",
      ~r"lib/glorbo_web/(controllers|live|components)/.*\.(ex|heex)$",
      ~r"assets/(js|css)/.*\.(js|css)$"
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :glorbo, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true
