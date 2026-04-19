import Config

# Do not print debug messages in production
config :logger, level: :info

# Phoenix LiveView 1.1 registers a `validate_compile_env` check on
# `:enable_expensive_runtime_checks`. dev.exs + test.exs set it to
# `true`, so deps recompiled under those envs bake "compile-time:
# true" into LV's beams. When a prod release loads WITHOUT the key
# set at runtime, BEAM's release-boot validator aborts with:
#
#   the application :phoenix_live_view has a different value set
#   for key :enable_expensive_runtime_checks during runtime
#   compared to compile time
#
# Pin the key to `false` in prod so sys.config carries it into the
# release and the validator passes. MUST come BEFORE runtime.exs
# (sys.config is frozen before runtime providers execute) — that's
# why this goes in prod.exs not runtime.exs.
config :phoenix_live_view, enable_expensive_runtime_checks: false

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
