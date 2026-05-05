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
  def run(_argv) do
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

    prev_env = Mix.env()

    try do
      Mix.env(:prod)
      Mix.Task.run("loadconfig")
      Mix.Task.run("release", ["glorbo", "--overwrite"])
    after
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
