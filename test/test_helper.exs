excludes = [:integration, :pending, :live_model]

# Exclude inotify-gated tests on hosts that lack `inotify-tools` (the
# Linux host dep `file_system` wraps). Production and CI require it; dev
# boxes may not have it installed — skip rather than fail hard.
excludes =
  if System.find_executable("inotifywait"),
    do: excludes,
    else: [:inotify | excludes]

# Plan 05-01: `:pending` tags the Wave-0 stub test files that Plans 02/03
# toggle to live by removing `@moduletag :pending`. `mix test --include
# pending` runs them (expected-red until the feature lands).
#
# `:live_model` tags suites that talk to a real local LM (LM Studio,
# Ollama, etc.). They depend on a specific model being LOADED — not
# merely listed — and on per-provider client config (e.g. opencode's
# provider registration) that can't be preflight-checked from Elixir
# alone. Run with `--include integration --include live_model` per
# the test moduledoc.

ExUnit.start(exclude: excludes)
Ecto.Adapters.SQL.Sandbox.mode(Glorbo.Repo, :manual)

# GEP-0053: the dashboard is now behind the director-passphrase gate
# (GlorboWeb.DirectorAuth). Put the test instance in a CONFIGURED state with
# a known passphrase so ConnCase/LiveCase can mint a matching `director_auth`
# session and the existing dashboard suite passes the gate. Tests that need
# BOOTSTRAP or DEGRADED override :director_password_hash per-test (saving and
# restoring it). Rounds are pinned to 1 in config/test.exs, so this is fast.
Application.put_env(
  :glorbo,
  :director_password_hash,
  Pbkdf2.hash_pwd_salt("test-director-passphrase")
)
