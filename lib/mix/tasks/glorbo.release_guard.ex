defmodule Mix.Tasks.Glorbo.ReleaseGuard do
  @moduledoc """
  Aliased target for `mix release` (see `mix.exs` `:aliases`).

  Wraps the underlying `mix release` task with two guard rails:

    * **Always pass `--overwrite`** so a re-build doesn't pause on
      `"Release glorbo-X.Y.Z already exists. Overwrite? [Yn]"`. There
      is no scenario in this project where the answer is no — the
      release artifact is single-use and disposable; the prompt only
      blocks non-interactive CI/scripts.

    * **Refuse if another `mix release` is already running** on the
      same checkout. Burrito 1.5.0 uses a shared `.zig-cache/` and
      writes `payload.foilz.xz` non-atomically; two concurrent runs
      race and the loser fails late with `FileNotFound: payload.foilz.xz`,
      potentially leaving `burrito_out/` half-overwritten.

  Both guards mirror what `mix glorbo.build_local` already does.
  Wrapping `mix release` itself catches direct callers (`mix release`,
  `mix release glorbo`, CI scripts) too.
  """
  use Mix.Task

  @shortdoc false

  @impl Mix.Task
  def run(argv) do
    refuse_if_concurrent_build!()

    argv =
      if "--overwrite" in argv do
        argv
      else
        argv ++ ["--overwrite"]
      end

    # Invoke the underlying release task module directly. Going through
    # `Mix.Task.run("release", argv)` would re-resolve the `release`
    # alias in `mix.exs` and infinite-loop straight back into this
    # module.
    Mix.Tasks.Release.run(argv)
  end

  # Per-checkout lockfile under `_build/`. Atomic create + PID liveness
  # check avoids both the false-positive of pgrep matching the shell
  # wrapper (whose eval string contains the literal "mix release" we
  # were searching for) and the stale-lock issue if a prior build
  # crashed without cleanup.
  @lockfile "_build/.release.lock"

  defp refuse_if_concurrent_build! do
    File.mkdir_p!("_build")

    case File.open(@lockfile, [:write, :exclusive]) do
      {:ok, fd} ->
        IO.binwrite(fd, "#{System.pid()}\n")
        File.close(fd)
        register_lock_cleanup()
        :ok

      {:error, :eexist} ->
        existing_pid = read_lock_pid()

        if pid_alive?(existing_pid) do
          Mix.shell().error(
            "refusing concurrent build — another mix release holds " <>
              "#{@lockfile} (pid #{existing_pid})\n" <>
              "(Burrito's payload.foilz.xz race; wait for it to finish or kill it)"
          )

          exit({:shutdown, 1})
        else
          # Stale lock from a crashed prior build — take it over.
          Mix.shell().info("removing stale #{@lockfile} (pid #{existing_pid} not alive)")
          File.rm!(@lockfile)
          refuse_if_concurrent_build!()
        end

      {:error, reason} ->
        Mix.shell().error("could not create #{@lockfile}: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp read_lock_pid do
    case File.read(@lockfile) do
      {:ok, body} -> body |> String.trim() |> String.to_integer()
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp pid_alive?(pid) when is_integer(pid) and pid > 0 do
    File.dir?("/proc/#{pid}")
  end

  defp pid_alive?(_), do: false

  defp register_lock_cleanup do
    System.at_exit(fn _ ->
      _ = File.rm(@lockfile)
    end)
  end
end
