import Config

# Do not auto-start companies on app boot under ExUnit — each test
# manages its own per-test tmp root + fixtures; auto-boot would fight
# the isolation. Same reasoning applies to per-company agent boot —
# tests that spin up a CompanySupervisor via fixtures don't expect
# every on-disk agent to start as well.
config :glorbo, auto_start_companies: false
config :glorbo, auto_boot_agents: false

# Keep `~/.glorbo/run/glorbo.pid` untouched by `mix test` runs; the pidfile
# is for real `phx.server` / `glorbo up` sessions.
config :glorbo, write_pidfile_on_boot: false

# CRITICAL (#144): set :glorbo_base to a per-run tmpdir so any test
# code path that calls Glorbo.Filesystem.Hierarchy.default_root/0
# lands inside an isolated dir, not the user's real ~/.glorbo.
# Without this, tests that didn't go through LiveCase/CLICase (which
# set their own per-test TmpGlorboHome) would scribble into the
# developer's actual install.
#
# Path baked into compiled config at `mix compile` time; fresh on
# every CI container build. The dir is eagerly created so startup
# code that expects it to exist doesn't crash.
test_base = Path.join(System.tmp_dir!(), "glorbo_test_base_#{System.os_time(:nanosecond)}")
File.mkdir_p!(test_base)
config :glorbo, :glorbo_base, test_base

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :glorbo, Glorbo.Repo,
  database: Path.expand("../glorbo_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  journal_mode: :wal

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :glorbo, GlorboWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "lNFLEuSRBYhtE7AmlKDWdk0wD7TwCsYxXVVfqohqQAyR0mKXfvbSfs7jljzmEmxX",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
