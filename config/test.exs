import Config

# Do not auto-start companies on app boot under ExUnit — each test
# manages its own per-test tmp root + fixtures; auto-boot would fight
# the isolation. Same reasoning applies to per-company agent boot —
# tests that spin up a CompanySupervisor via fixtures don't expect
# every on-disk agent to start as well.
config :glorbo, auto_start_companies: false
config :glorbo, auto_boot_agents: false

# GEP-33 Phase 2c: skip the production HomeHistory.Tx server under
# `mix test` so each test can pin its own Tx to a tmp base + claim
# the canonical registered name without a clash.
config :glorbo, start_home_history_tx: false

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
# you can enable the server option below. Also opt out of the
# `glorbo serve` / `up` Endpoint auto-enable so the integration
# `--exit-after` test starts the supervision tree without binding
# port 4000 (would collide with parallel ConnCase suites).
config :glorbo, GlorboWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "lNFLEuSRBYhtE7AmlKDWdk0wD7TwCsYxXVVfqohqQAyR0mKXfvbSfs7jljzmEmxX",
  server: false

config :glorbo, :serve_starts_endpoint, false

# DashboardToken plug always-enforces a token; tests use a fixed sentinel so
# ConnCase/LiveCase can inject it into every conn without reading config files.
config :glorbo, :dashboard_token, "test-token"

# GEP-0053 — director passphrase login. Drop PBKDF2 to 1 round under test
# so every /setup + /login assertion (and the DirectorAuth reference-hash
# timing path) is fast. Test fixtures that bake a stored hash MUST be
# generated at this same round count (GEP-0053 D13) so a 1-round dummy
# never mixes with a 210k-round fixture.
config :pbkdf2_elixir, rounds: 1

# GEP-0053: a 2s base window so the throttle-engaged integration assertion
# is deterministic (one reserve → the next request within ~2s is throttled,
# comfortably longer than a GET+POST round-trip). Tests reset
# GlorboWeb.LoginThrottle in setup; only the auth-flow suite exercises
# /login.
config :glorbo, GlorboWeb.LoginThrottle, base_ms: 2_000, max_ms: 5_000, free_attempts: 0

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Form recovery is a runtime reliability contract. Missing IDs must fail in
# CI instead of producing warnings that disappear in noisy negative-path logs.
config :phoenix_live_view, :test_warnings, missing_form_id: :raise
