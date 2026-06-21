import Config

# Do not print debug messages in production
config :logger, level: :info

# Force the exqlite SQLite NIF to compile from source for release
# builds. Our prod artifact is a Burrito single-file binary whose ERTS
# is musl (beam-machine-universal). Burrito recompiles :elixir_make NIFs
# with `zig cc` against that musl target — but ONLY when the NIF actually
# compiles. By default exqlite's cc_precompiler DOWNLOADS a precompiled
# glibc NIF (`libc.so.6`, needing the `__memmove_chk`/`__memcpy_chk`
# fortify symbols musl lacks); that prebuilt .so sails through Burrito's
# Zig step untouched and the musl runtime then can't relocate it
# ("Error relocating sqlite3_nif.so: __memmove_chk: symbol not found"),
# so Glorbo.Repo can't open the DB and the app dies at boot. Forcing the
# source build restores Burrito's zig-musl path → a musl NIF
# (`NEEDED libc.so`) that matches the bundled ERTS. Bonus: no opaque
# precompiled binary pulled from a third-party GitHub release (aligns
# with the repo's pin-everything supply-chain posture). Compile-time
# config — exqlite reads it via `Application.get_env(:exqlite,
# :force_build)` when the dep compiles. Dev/test stay on the fast
# precompiled NIF (they run on a glibc host, not the musl release).
config :exqlite, force_build: true

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
