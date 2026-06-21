defmodule Glorbo.MixProject do
  use Mix.Project

  def project do
    [
      app: :glorbo,
      version: "0.28.5",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      # Dialyzer (success-typing static analysis). PLTs live under
      # priv/plts/ (gitignored, cached in CI keyed on mix.lock + OTP/Elixir
      # version). `:mix`/`:ex_unit` are added to the PLT so analysis knows
      # those modules' types (CI runs dialyzer in :dev, so test/support is
      # not itself analyzed). CI is kept green NOT by `.dialyzer_ignore.exs`
      # (intentionally empty) but by the COUNT-regression gate in the CI
      # workflow — see docs/testing/dialyzer-baseline.md.
      dialyzer: [
        # Codex deep-dive follow-up: PLTs MUST NOT live under `priv/`.
        # Mix releases (and Burrito wrapping) copy `priv/` into the
        # release tarball as runtime data, so PLTs under `priv/plts`
        # were bundled into the shipped x86_64 binary — bloat + leaked
        # build/module/type metadata. Park them under `_build/` instead,
        # which is already release-excluded.
        plt_local_path: "_build/dialyzer_plts",
        plt_core_path: "_build/dialyzer_plts",
        # :credo is needed so the custom Credo check in lib_dev/ (which
        # calls Credo.Check.*, Credo.Code.prewalk/2, etc.) doesn't trip
        # `unknown_function` warnings — those modules live in the :credo
        # dep, not the app.
        plt_add_apps: [:mix, :ex_unit, :credo],
        # Per-warning ignores stay empty by design — adoption uses a
        # COUNT-regression gate in CI (docs/testing/dialyzer-baseline.md)
        # rather than per-warning tuples (dialyxir's .exs matcher keys on
        # dialyzer's absolute file path, which isn't portable CI-vs-local).
        ignore_warnings: ".dialyzer_ignore.exs",
        format: :short
      ],
      # `Phoenix.CodeReloader` ships in `phoenix_live_reload`, which is
      # `only: :dev`. Listing it as a listener in all envs causes mix
      # release to flag phoenix_live_reload as a runtime dep and embed
      # it in the OTP release manifest as `permanent`, contaminating
      # `_build/prod/rel/glorbo/lib/` even after `purge_dev_only_artifacts!`
      # wipes it. Gate the listener on `:dev` so prod releases stay clean.
      listeners: listeners(Mix.env())
    ]
  end

  defp listeners(:dev), do: [Phoenix.CodeReloader]
  defp listeners(_), do: []

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Glorbo.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  # `lib_dev/` holds custom Credo checks that depend on the Credo
  # library — only available in :dev/:test. Keeping those out of
  # `lib/` is what lets prod cross-builds (macOS / aarch64) succeed
  # without pulling Credo as a runtime dep.
  defp elixirc_paths(:test), do: ["lib", "lib_dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "lib_dev"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      # Force decimal past GHSA-rhv4-8758-jx7v (Decimal.new unbounded-exponent
      # DoS, fixed in 3.0). ecto pins `~> 2.0` and ecto_sqlite3 `~> 1.6 or
      # ~> 2.0` — neither admits `~> 3.0` yet, so override until they relax.
      # Glorbo doesn't use Decimal directly — verified safe.
      {:decimal, "~> 3.0", override: true},
      {:phoenix_ecto, "~> 4.6"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.22"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.1"},
      # GEP-0053 — director passphrase login. PBKDF2-HMAC-SHA512 hashing
      # for the browser passphrase. Pure-Elixir (preserves Burrito — no
      # NIF to cross-compile to the 4 release targets); chosen over
      # argon2_elixir for exactly that reason (GEP-0053 D13). Rounds are
      # pinned in config/config.exs (210k, OWASP) + config/test.exs (1).
      {:pbkdf2_elixir, "~> 2.2"},
      {:floki, ">= 0.37.0", only: :test},
      # Phoenix LiveView 1.1's `Phoenix.LiveViewTest` requires `lazy_html`
      # for DOM parsing in connected-mount tests (Plan 04-02 Wave 1).
      {:lazy_html, ">= 0.1.0", only: :test},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.6"},
      {:crontab, "~> 1.2"},
      {:dns_cluster, "~> 0.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:burrito, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # OpenSSF / supply-chain hardening — static security analysis (SAST)
      # and dependency-advisory auditing. Dev/test only, never in the
      # Burrito release (runtime: false keeps them out of the OTP manifest).
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      # Dialyzer (success-typing static analysis) via dialyxir. Dev-only,
      # never in the Burrito release.
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:file_system, "~> 1.0"},
      {:yaml_front_matter, "~> 1.0"},
      {:yaml_elixir, "~> 2.9"},
      # GEP-8 — provider registry TOML parser (priv/providers/*.toml +
      # ~/.glorbo/providers.toml). Pure-Elixir, dual-licensed MIT OR Apache-2.0.
      {:toml, "~> 0.7"},
      {:finch, "~> 0.21"},
      # Security floors for the transitive HTTP-client stack (burrito →
      # req → finch → mint); neither is called by Glorbo directly, both
      # are declared solely to bar the vulnerable versions OSV/OpenSSF
      # Scorecard flagged against mix.lock.
      #
      # mint < 1.9.0 — four EEF advisories: HTTP/1 request-line CRLF
      # injection (EEF-CVE-2026-48861), HTTP/1 response smuggling via
      # lenient Content-Length parsing (EEF-CVE-2026-49753), and two
      # HTTP/2 client-memory DoS vectors — unbounded PUSH_PROMISE growth
      # (EEF-CVE-2026-48862) and a CONTINUATION flood (EEF-CVE-2026-49754).
      # All fixed in 1.9.0; finch only requires `~> 1.8`, which still
      # admits 1.8.0, so pin the floor here.
      {:mint, "~> 1.9"},
      # req < 0.6.1 — decompression-bomb DoS via auto-decoded
      # compressed/archive bodies (EEF-CVE-2026-49755, fixed 0.6.1) and
      # multipart header injection via unescaped name/filename/content_type
      # (EEF-CVE-2026-49756, fixed 0.6.0). 0.6.0 fixes only the latter, so
      # the floor is 0.6.1. burrito requires only `>= 0.5.0`. req here is
      # build-time only (ERTS download); req 0.6's opt-in decompression
      # doesn't affect tarball fetches (no Content-Encoding negotiation).
      {:req, ">= 0.6.1 and < 1.0.0"},
      # Finch/Mint's TLS certificate verification relies on castore (marked
      # optional by mint). Declaring it here guarantees cert validation
      # works in prod (TODO.md audit Low #2).
      {:castore, ">= 0.0.0"},
      {:muontrap, "~> 1.6"},
      # Phase 4 Wave 0 — LiveView dashboard dependencies.
      # `esbuild` bundles `assets/js/app.js` + `assets/css/app.css` into
      # `priv/static/assets/`. `runtime: Mix.env() == :dev` keeps the
      # install-and-run code path out of the Burrito release (prod uses
      # pre-built `priv/static/assets/` from `mix assets.deploy`).
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      # Markdown renderer for channel message bodies (UI-SPEC chat profile).
      {:mdex, "~> 0.13.0"},
      {:mdex_gfm, "~> 0.2.0"},
      # Allowlist HTML sanitizer for markdown output — MDEx has no
      # built-in sanitization; caller must sanitize.
      {:html_sanitize_ex, "~> 1.5"},
      # GEP-37: terminal UI runtime for `glorbo shell`. Pure-Elixir
      # (preserves Burrito), MIT, widget set covering the views the
      # GEP enumerates (tables, trees, split panes, command palette,
      # supervision-tree viewer).
      #
      # Pinned to 1.0.0-rc — 0.2.0 fails to compile on Elixir 1.18
      # because `@level_patterns` carried Regex Reference values
      # that can't be injected into module attributes (upstream
      # commit landed in the rc). Stays an `rc` until upstream
      # tags a stable 1.0.0; revisit then.
      {:term_ui, "~> 1.0.0-rc"}
    ]
  end

  # Burrito release configuration — wraps the Elixir release into a
  # self-extracting single-file binary with bundled ERTS per target.
  # See `.planning/phases/01-compilable-skeleton-ci-release-pipeline/01-RESEARCH.md`
  # §Pattern 4 and §Pitfall 3 (missing `&Burrito.wrap/1` produces a tarball,
  # not a binary).
  defp releases do
    [
      glorbo: [
        # Skip the boot-time `validate_compile_env` checks entirely.
        # LV 1.1 + Endpoint compile-env keys (`code_reloader`,
        # `debug_errors`, `force_ssl`, `enable_expensive_runtime_checks`)
        # get baked into every dep module's compile-env table when any
        # Mix env sets them. Prod sys.config can't always mirror that
        # exactly (especially with Burrito-cached releases + cross-env
        # _build/), so the release boot validator aborts with confusing
        # "compile time vs runtime" errors. We don't rely on these keys
        # at runtime — Endpoint reloader flags, LV expensive checks —
        # so disabling the boot check is safe and keeps binaries usable
        # regardless of which envs compiled what into _build/.
        validate_compile_env: false,
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            # R30: macOS support. Degraded runtime on macOS —
            # bwrap has no macOS equivalent, so agents run
            # unsandboxed with a one-time warning audit. The
            # filesystem watcher uses FSEvents (push-based,
            # transparent via the file_system package).
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            macos_arm64: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # Phase 4 Wave 0 — asset pipeline reintroduction.
      # esbuild Hex wrapper (no npm, no package.json) — auto-downloads
      # per-platform binary into _build/ on first `assets.setup`.
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["esbuild glorbo"],
      "assets.deploy": ["esbuild glorbo --minify", "phx.digest"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "glorbo.privacy_check",
        "credo --strict",
        "glorbo.docs.file_formats --check",
        "test"
      ],
      # TODO D1: bare `mix release glorbo` pauses on
      # "Release glorbo-X.Y.Z already exists. Overwrite? [Yn]"
      # which blocks non-interactive CI/scripts. Route `mix release`
      # through `glorbo.release_guard` (string-aliased so Mix loads
      # the task lazily — function aliases need the module already
      # compiled, which fails on a clean prod build). The guard
      # appends --overwrite when missing and refuses concurrent
      # invocations. `mix glorbo.build_local` remains the canonical
      # local-build path because it also wipes the burrito cache,
      # dev-only deps, the poisoned `.zig-cache`, and symlinks
      # `./glorbo`.
      release: ["glorbo.release_guard"]
    ]
  end
end
