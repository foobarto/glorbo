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
