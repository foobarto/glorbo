defmodule Mix.Tasks.Glorbo.BuildLocal do
  @moduledoc """
  Build the linux_x86_64 burrito release and (re)link `glorbo` in the
  project root to it.

      mix glorbo.build_local

  Equivalent to:

      MIX_ENV=prod mix release glorbo --overwrite
      ln -sfn burrito_out/glorbo_linux_x86_64 glorbo

  This is the standard "I want to test my latest code via the shipped
  CLI shape" command. The symlink is gitignored (see `.gitignore`);
  every fresh clone starts with no symlink and runs this task to
  materialise one.

  Runs in `:prod` Mix env so the release is ERTS-bundled and
  production-compiled. Subsequent dev work does not need to
  rebuild — the symlink keeps pointing at the same path, and
  re-running this task overwrites in place.
  """
  use Mix.Task

  @shortdoc "Build burrito glorbo + symlink ./glorbo -> burrito_out/glorbo_linux_x86_64"
  @symlink_name "glorbo"
  @target_rel "burrito_out/glorbo_linux_x86_64"

  # Deps with `only: :dev` / `only: :test` in `mix.exs`. If any of these
  # leak into `_build/prod/lib/` (most often because a prior `mix test`
  # or `mix iex -S` run under `:dev` populated them and Mix's release
  # assembler then re-uses the cached artifacts), they end up in the
  # release `.rel` manifest as `permanent` and auto-start at every CLI
  # invocation. `phoenix_live_reload` is the most visible offender: its
  # Application start callback calls `FileSystem.start_link/1` which
  # emits three lines of `[error]`/`[warning]` on hosts without
  # `inotify-tools` — for every `glorbo` verb, including ones that
  # don't need a watcher (`glorbo validate`, `glorbo templates list`).
  # Wiping these dirs before `mix release` runs guarantees the prod
  # release reflects `mix.exs`'s `only:` filters, not `_build/prod/`'s
  # contamination history.
  @dev_only_deps ~w(phoenix_live_reload floki lazy_html credo)

  @impl Mix.Task
  def run(argv) do
    # `Mix.Project.config()` is evaluated once per Mix.Project module
    # load and cached. By the time this task runs, `mix.exs`'s
    # `listeners: listeners(Mix.env())` has already been resolved with
    # whatever `Mix.env()` was at startup — bumping `Mix.env(:prod)`
    # later in this function does NOT re-evaluate it. So if mix was
    # started without `MIX_ENV=prod`, `Phoenix.CodeReloader` (from
    # `phoenix_live_reload`, `only: :dev`) is locked in as a project
    # listener and mix release ends up embedding the dev-only dep into
    # the prod release manifest. Re-exec ourselves with `MIX_ENV=prod`.
    if Mix.env() != :prod do
      Mix.shell().info("re-executing under MIX_ENV=prod (was #{Mix.env()})")

      {_out, status} =
        System.cmd("mix", ["glorbo.build_local" | argv],
          env: [{"MIX_ENV", "prod"}],
          into: IO.stream(:stdio, :line),
          stderr_to_stdout: true
        )

      exit({:shutdown, status})
    end

    # Concurrent-build refusal is handled by `Mix.Tasks.Glorbo.ReleaseGuard`
    # which the `:release` alias in `mix.exs` routes through. We don't
    # duplicate the check here; the lockfile is acquired one frame
    # deeper when we call `Mix.Task.run("release", ...)`.

    # Burrito unpacks the bundled ERTS to `/tmp/unpacked_erts_<hex>/`
    # on every build (~128 MB each) and never cleans them up. Across
    # weeks of builds this fills `/tmp` and breaks unrelated tools
    # that share the tmpfs. Sweep entries older than one day before
    # the new build runs.
    purge_stale_unpacked_erts!()

    # Burrito 1.5.0's `clean_build` step cleans `zig-cache` (no dot)
    # but the actual directory is `.zig-cache` (with dot — modern
    # zig convention). The mismatch leaves the zig cache untouched
    # forever, which by itself is fine — incremental builds reuse
    # it cleanly. BUT when a prior build crashed mid-way (e.g. the
    # concurrent-build race we now refuse, or a transient zig OOM),
    # it leaves residual `payload.foilz.xz` / `musl-runtime.so` in
    # `deps/burrito/src/` AND a `.zig-cache` whose manifests still
    # reference those files. The next build deletes them as part of
    # its own setup, then zig fails with `FileNotFound` because the
    # cache thinks they should be there. Detect the dirty state and
    # wipe `.zig-cache` (cost: one full re-compile, ~5 min).
    purge_zig_cache_if_dirty!()

    # Burrito keeps the extracted release under
    # `~/.local/share/.burrito/glorbo_erts-<vsn>_<app-vsn>/`. It only
    # re-extracts when the embedded payload HASH changes; the extracted
    # sys.config / vm.args / beams stick around between rebuilds. So a
    # rebuild that changes `config/prod.exs` (compile-time values baked
    # into sys.config) won't propagate to the running binary until the
    # cache is cleared. Nuke it at the top of every build to keep local
    # testing honest.
    burrito_cache = Path.expand("~/.local/share/.burrito")

    if File.dir?(burrito_cache) do
      File.rm_rf!(burrito_cache)
      Mix.shell().info("cleared burrito cache at #{burrito_cache}")
    end

    purge_dev_only_artifacts!()
    purge_stale_release!()

    prev_env = Mix.env()

    try do
      Mix.env(:prod)
      # BURRITO_TARGET limits the build to the host arch so we don't
      # also cross-compile macos/aarch64 binaries just to test locally.
      System.put_env("BURRITO_TARGET", "linux_x86_64")
      Mix.Task.run("loadconfig")
      Mix.Task.run("release", ["glorbo", "--overwrite"])
    after
      System.delete_env("BURRITO_TARGET")
      Mix.env(prev_env)
    end

    root = File.cwd!()
    target = Path.join(root, @target_rel)

    assert_no_dev_only_in_manifest!(root)

    if File.exists?(target) do
      link_path = Path.join(root, @symlink_name)
      _ = File.rm(link_path)
      :ok = File.ln_s!(@target_rel, link_path)
      Mix.shell().info("✓ symlinked ./#{@symlink_name} -> #{@target_rel}")
    else
      Mix.shell().error("Expected #{@target_rel} after release build, but it's missing.")
      exit({:shutdown, 1})
    end
  end

  defp purge_zig_cache_if_dirty! do
    # Files that Burrito's `clean_build` step removes via `File.rm/1`
    # at the end of every successful build — their presence at the
    # start of a build means the previous one crashed mid-flight and
    # the `.zig-cache` manifests are still pointing at files that
    # this fresh build is about to overwrite or that no longer exist.
    #
    # Note: we deliberately do NOT check for `deps/burrito/zig-out`.
    # Burrito's `clean_build` calls `File.rmdir/1` on it, which only
    # removes EMPTY directories — so `zig-out` happily survives every
    # successful build. Treating its existence as "dirty" would wipe
    # `.zig-cache` on every single build and defeat the whole point
    # of incremental compilation (~5 min cost per rebuild).
    burrito = "deps/burrito"

    residuals = [
      Path.join([burrito, "src", "payload.foilz.xz"]),
      Path.join([burrito, "src", "musl-runtime.so"]),
      Path.join([burrito, "src", "_metadata.json"]),
      Path.join(burrito, "payload.foilz")
    ]

    dirty? = Enum.any?(residuals, &File.exists?/1)
    cache = Path.join(burrito, ".zig-cache")

    if dirty? and File.dir?(cache) do
      Mix.shell().info("burrito cache appears dirty (residual build artifacts); wiping #{cache}")

      File.rm_rf!(cache)
      Enum.each(residuals, fn p -> _ = File.rm_rf(p) end)
    end
  end

  defp purge_stale_unpacked_erts! do
    case System.cmd(
           "find",
           [
             "/tmp",
             "-maxdepth",
             "1",
             "-name",
             "unpacked_erts_*",
             "-type",
             "d",
             "-mtime",
             "+1",
             "-exec",
             "rm",
             "-rf",
             "{}",
             "+"
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      _ -> :ok
    end
  end

  # Wipe the rel dir so `mix release --overwrite` starts with a single
  # erts-* directory. Without this, successive releases accumulate erts
  # dirs; Burrito's clean_work_dir then races between them and can
  # delete the freshly-built one, leaving CopyERTS with nothing to find.
  defp purge_stale_release! do
    rel_dir = Path.expand("_build/prod/rel/glorbo")

    if File.dir?(rel_dir) do
      File.rm_rf!(rel_dir)
      Mix.shell().info("cleared stale release at #{rel_dir}")
    end
  end

  defp purge_dev_only_artifacts! do
    prod_lib = Path.expand("_build/prod/lib")

    Enum.each(@dev_only_deps, fn dep ->
      path = Path.join(prod_lib, dep)

      if File.dir?(path) do
        File.rm_rf!(path)
        Mix.shell().info("purged dev-only #{dep} from #{prod_lib}/")
      end
    end)
  end

  # Belt-and-braces: even after `purge_dev_only_artifacts!/0` runs, an
  # earlier release may have written a `.rel` manifest that still lists
  # a dev-only app as `permanent`. Read the manifest matching the
  # current `mix.exs` version and fail loudly if any forbidden name
  # appears, so we never re-ship a contaminated binary.
  defp assert_no_dev_only_in_manifest!(root) do
    version = Mix.Project.config()[:version]

    rel_path =
      Path.join([root, "_build", "prod", "rel", "glorbo", "releases", version, "glorbo.rel"])

    case File.read(rel_path) do
      {:ok, body} ->
        offenders = Enum.filter(@dev_only_deps, &String.contains?(body, "{#{&1},"))

        unless offenders == [] do
          Mix.shell().error(
            "release manifest at #{rel_path} contains dev-only apps: " <>
              Enum.join(offenders, ", ") <>
              ". Run `make clean-burrito` then rebuild."
          )

          exit({:shutdown, 1})
        end

      {:error, _} ->
        # Manifest missing — `release` will already have errored and
        # the next File.exists? check at @target_rel will surface a
        # clearer message.
        :ok
    end
  end
end
