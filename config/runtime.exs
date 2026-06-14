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

  # Phase 4 Wave 0: prefer `~/.glorbo/config.md` over env vars so a fresh
  # install is configured-by-file (matches D-06/D-07 "filesystem is source
  # of truth"). Env vars still override — useful for one-off overrides
  # in test harnesses and CI smoke tests.
  #
  # WR-04: if Glorbo.Config.load/0 fails we generate an ephemeral 64-byte
  # random key rather than derive one from $HOME (deterministic,
  # low-entropy, trivially forgeable on a shared host). Sessions die on
  # restart but entropy is adequate; the error is logged at :error so ops
  # notice. The sha256($HOME) fallback is intentionally removed.
  cfg =
    case Glorbo.Config.load() do
      {:ok, c} ->
        c

      {:error, reason} ->
        require Logger

        Logger.error(
          "Glorbo.Config.load/0 failed (reason=#{inspect(reason)}); " <>
            "booting with an ephemeral secret_key_base. Sessions will not " <>
            "survive restart. Fix ~/.glorbo/config.md to persist configuration."
        )

        %{
          secret_key_base: :crypto.strong_rand_bytes(64) |> Base.url_encode64(),
          host: "127.0.0.1",
          port: 4000,
          dashboard_token: nil,
          # GEP-0053 D9/D10: a failed config load is a degraded posture, not
          # bootstrap. `:malformed` makes DirectorAuth fail CLOSED (browser
          # denied) rather than silently re-opening `/setup`. (dashboard_token:
          # nil already 500s the token gate, so MCP/CLI are denied too.)
          director_password_hash: :malformed
        }
    end

  secret_key_base = System.get_env("SECRET_KEY_BASE") || cfg.secret_key_base
  host = System.get_env("PHX_HOST") || cfg.host
  port = String.to_integer(System.get_env("PORT") || Integer.to_string(cfg.port))

  config :glorbo, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :glorbo, :dashboard_token, cfg.dashboard_token
  # GEP-0053 — director passphrase hash. `nil` ⇒ BOOTSTRAP, a
  # `$pbkdf2-sha512$…` string ⇒ CONFIGURED, `:malformed` ⇒ DEGRADED.
  # The in-daemon `/setup` handler `put_env`s this after writing the hash
  # so the gate engages without a restart (D3).
  config :glorbo, :director_password_hash, cfg.director_password_hash

  # Derive the LiveView signing_salt from the runtime secret_key_base
  # so we don't ship a hardcoded value. The compile-time config.exs
  # fallback remains a defensible placeholder (TODO.md audit Medium
  # #8); this runtime override is what production actually uses.
  signing_salt =
    :crypto.hash(:sha256, secret_key_base)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)

  # Accept WebSocket upgrades from both loopback aliases plus whatever
  # host the operator configured. Phoenix's default `check_origin: true`
  # validates the upgrade against `url[:host]` only, so a release whose
  # config says `127.0.0.1` rejects browsers navigating to
  # `http://localhost:4000` (and vice-versa). The dashboard binds to
  # 127.0.0.1 by design (loopback only — no remote access without a
  # reverse proxy), so allowing both aliases is safe.
  check_origin =
    Enum.uniq([
      "//#{host}",
      "//127.0.0.1",
      "//localhost"
    ])

  config :glorbo, GlorboWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    check_origin: check_origin,
    secret_key_base: secret_key_base,
    live_view: [signing_salt: signing_salt]
end

# GEP-48 dev parity: the `DashboardToken` plug reads
# `Application.get_env(:glorbo, :dashboard_token)` and rejects `nil` with
# a 500. The prod block above loads the token from `config.md`, but
# `mix phx.server` (dev) skips that block — so without this the dev
# dashboard 500s on every request (and the browser UAT path, which uses
# `mix phx.server`, is unusable). `:test` hardcodes its own token in
# `config/test.exs`, so this load is dev-only.
if config_env() == :dev do
  case Glorbo.Config.load() do
    {:ok, cfg} ->
      config :glorbo, :dashboard_token, cfg.dashboard_token
      # GEP-0053 dev parity — DirectorAuth reads this for the browser gate.
      config :glorbo, :director_password_hash, cfg.director_password_hash

      # web-ui-uat P0: `mix phx.server` boots into BOOTSTRAP but — unlike
      # `glorbo serve`/`up` — never prints the first-run URL, so the only
      # credential that unlocks /setup (the dashboard_token) is invisible and
      # the dev dashboard is a dead lockout. Surface the state-aware URL here,
      # gated on bootstrap/degraded so a CONFIGURED node never reprints the
      # token into scrollback (GEP-0053 D18). `Config.load` above self-heals a
      # 0-byte config.md first, so the printed token is the persisted one.
      unless match?(h when is_binary(h) and h != "", cfg.director_password_hash) do
        IO.puts(
          "\n  glorbo dashboard (first-run setup): " <>
            Glorbo.CLI.Lifecycle.Banner.dashboard_url(
              "http://127.0.0.1:4000",
              cfg.director_password_hash,
              cfg.dashboard_token
            ) <> "\n"
        )
      end

    {:error, _reason} ->
      :ok
  end
end
