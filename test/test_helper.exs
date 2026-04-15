excludes = [:integration]

# Exclude inotify-gated tests on hosts that lack `inotify-tools` (the
# Linux host dep `file_system` wraps). Production and CI require it; dev
# boxes may not have it installed — skip rather than fail hard.
excludes =
  if System.find_executable("inotifywait"),
    do: excludes,
    else: [:inotify | excludes]

ExUnit.start(exclude: excludes)
Ecto.Adapters.SQL.Sandbox.mode(Glorbo.Repo, :manual)
